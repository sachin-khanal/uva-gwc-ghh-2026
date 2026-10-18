-- File:    supabase/migrations/0007_mesh_publish_and_read.sql
-- Owner:   U3 (backend) / U1 (contract). Added 2026-10-18 on branch feature/web-mesh-obj. NOT APPLIED to any project yet.
-- Why:     The phone now exports a 3D surface file (OBJ) per scan for the web viewer and uploads it to the `meshes` bucket
--          (`<contributor>/<building>/<asset id>.obj`). Two things were missing on the server:
--          1. `extend_building` (0002/0003) keeps the stored map and only replaces nodes/edges/version when a building already exists, so
--             a mesh list sent with a later extension would be silently dropped. `publish_mesh_assets` adds assets explicitly.
--          2. Storage reads on `meshes` are limited to the uploader's own folder (0001), so the web viewer (another anonymous user)
--             could never download a shared scan. This adds a read rule like 0004 does for scan files.
-- Rules:   publish_mesh_assets(building, assets): signed in; building exists; every asset has a fresh uuid `id`, `segmentId` that THIS
--          user contributed (segment_owners), format "obj", coordinateFrame "map", storageOwner = this user, 1..40 MB, lowercase hex
--          SHA-256, finite bounds with min <= max. Append-only (existing ids are skipped, never changed). At most 100 files / 80 MB in
--          total. The CHECK constraint from 0005 then re-validates the whole map.
-- Read:    any signed-in user may read a file only if its EXACT path is listed in a building's `meshAssets`.
-- Tests:   supabase/tests/mesh_publish_and_read.sql (run in a scratch Postgres or the SQL editor). Safe to re-run.
begin;

create or replace function public.publish_mesh_assets(building uuid, assets jsonb)
returns void language plpgsql security definer set search_path = '' as $$
declare
  actor uuid := auth.uid();
  previous public.canonical_buildings%rowtype;
  merged jsonb;
  item jsonb;
  b jsonb;
  total bigint := 0;
  i integer;
begin
  if actor is null then raise exception 'Sign in first'; end if;
  if building is null or jsonb_typeof(assets) is distinct from 'array' or jsonb_array_length(assets) not between 1 and 100 then
    raise exception 'Invalid mesh list';
  end if;
  perform pg_advisory_xact_lock(hashtextextended(building::text, 0));
  select * into previous from public.canonical_buildings where map_id = building for update;
  if not found then raise exception 'Unknown building'; end if;

  merged := case when jsonb_typeof(previous.map_json->'meshAssets') = 'array' then previous.map_json->'meshAssets' else '[]'::jsonb end;

  for item in select value from jsonb_array_elements(assets) loop
    if jsonb_typeof(item) is distinct from 'object'
       or coalesce(item->>'id', '') !~ '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
       or coalesce(item->>'segmentId', '') !~ '^[A-Za-z0-9_-]{1,64}$'
       or coalesce(previous.segment_owners->>(item->>'segmentId'), '') <> actor::text
       or item->>'format' is distinct from 'obj'
       or item->>'coordinateFrame' is distinct from 'map'
       or lower(coalesce(item->>'storageOwner', '')) <> actor::text
       or jsonb_typeof(item->'byteCount') is distinct from 'number'
       or coalesce(item->>'sha256', '') !~ '^[0-9a-f]{64}$'
       or jsonb_typeof(item->'boundsMin') is distinct from 'array' or jsonb_array_length(item->'boundsMin') <> 3
       or jsonb_typeof(item->'boundsMax') is distinct from 'array' or jsonb_array_length(item->'boundsMax') <> 3 then
      raise exception 'Invalid mesh asset';
    end if;
    if (item->>'byteCount')::numeric <> floor((item->>'byteCount')::numeric)
       or (item->>'byteCount')::numeric not between 1 and 40000000 then
      raise exception 'Invalid mesh size';
    end if;
    for i in 0..2 loop
      if jsonb_typeof(item->'boundsMin'->i) is distinct from 'number' or jsonb_typeof(item->'boundsMax'->i) is distinct from 'number'
         or (item->'boundsMin'->>i)::double precision > (item->'boundsMax'->>i)::double precision then
        raise exception 'Invalid mesh bounds';
      end if;
    end loop;
    -- Append-only: an id that is already listed is skipped, never replaced.
    if exists (select 1 from jsonb_array_elements(merged) m where lower(m->>'id') = lower(item->>'id')) then continue; end if;
    merged := merged || jsonb_build_array(jsonb_set(item, '{id}', to_jsonb(lower(item->>'id'))));
  end loop;

  select coalesce(sum((m->>'byteCount')::numeric), 0) into total from jsonb_array_elements(merged) m;
  if jsonb_array_length(merged) > 100 or total > 80000000 then raise exception 'Too many or too large mesh files'; end if;

  update public.canonical_buildings
     set map_json = map_json || jsonb_build_object('meshAssets', merged), updated_at = now()
   where map_id = building;
end $$;
revoke all on function public.publish_mesh_assets(uuid, jsonb) from public, anon;
grant execute on function public.publish_mesh_assets(uuid, jsonb) to authenticated;

-- Read rule: exact path listed in some building's meshAssets (same idea as canonical_worldmaps_read in 0004; note `objects.name`).
drop policy if exists canonical_meshes_read on storage.objects;
create policy canonical_meshes_read on storage.objects for select to authenticated using (
  bucket_id = 'meshes'
  and exists (
    select 1
    from public.canonical_buildings c,
         jsonb_array_elements(case when jsonb_typeof(c.map_json->'meshAssets') = 'array' then c.map_json->'meshAssets' else '[]'::jsonb end) a
    where objects.name = lower(a->>'storageOwner') || '/' || c.map_id::text || '/' || lower(a->>'id') || '.obj'
  )
);

commit;
