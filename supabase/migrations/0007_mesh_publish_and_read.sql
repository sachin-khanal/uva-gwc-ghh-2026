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
-- Read:    any signed-in user may read a file only if its EXACT path is listed in a building's `meshAssets` AND the listed storageOwner
--          is the user who contributed that asset's segment (segment_owners, set by extend_building from the real caller). The second
--          condition matters because the FIRST publication of a building stores the incoming JSON as is, so a forged meshAssets entry
--          could otherwise point the rule at someone else's folder (automated security review 2026-10-18).
-- First publication: a trigger strips `meshAssets` from a building's first-publication JSON, (only when no row exists yet) so entries exist only if
--          publish_mesh_assets validated them (the review of 2026-10-18 found they could otherwise be forged and fill the quota).
-- Quota:   limits are PER CONTRIBUTOR (25 files / 40 MB each) as well as per building (100 files / 80 MB), so one user cannot fill the
--          building's list. A listed file must already exist in storage with exactly the claimed size (upload first, then list).
--          `remove_mesh_asset(building, id)` lets the contributor delist their own entry.
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
  mine integer;
  mine_bytes numeric;
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
    -- The file must already be uploaded, at the claimed size (the app uploads first). Size comes from storage metadata.
    if not exists (select 1 from storage.objects o
                   where o.bucket_id = 'meshes'
                     and o.name = actor::text || '/' || building::text || '/' || lower(item->>'id') || '.obj'
                     and (o.metadata->>'size')::numeric = (item->>'byteCount')::numeric) then
      raise exception 'Upload the mesh file first (missing or wrong size)';
    end if;
    -- Append-only: an id that is already listed is skipped, never replaced.
    if exists (select 1 from jsonb_array_elements(merged) m where lower(m->>'id') = lower(item->>'id')) then continue; end if;
    merged := merged || jsonb_build_array(jsonb_set(item, '{id}', to_jsonb(lower(item->>'id'))));
  end loop;

  select coalesce(sum((m->>'byteCount')::numeric), 0) into total from jsonb_array_elements(merged) m;
  if jsonb_array_length(merged) > 100 or total > 80000000 then raise exception 'Too many or too large mesh files'; end if;
  -- Per contributor, so one user cannot use up the building's whole list.
  select count(*), coalesce(sum((m->>'byteCount')::numeric), 0) into mine, mine_bytes
    from jsonb_array_elements(merged) m where lower(m->>'storageOwner') = actor::text;
  if mine > 25 or mine_bytes > 40000000 then raise exception 'You have listed too many or too large mesh files for this building'; end if;

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
      and lower(coalesce(c.segment_owners->>(a->>'segmentId'), '')) = lower(a->>'storageOwner')
      -- the file must STILL have the size that was listed: a file swapped for a different size after listing is not served
      -- (same-size swaps are caught by the viewer, which checks the listed SHA-256 before drawing anything)
      and (objects.metadata->>'size')::numeric = (a->>'byteCount')::numeric
  )
);

-- Only publish_mesh_assets may ADD mesh entries. `extend_building` stores the incoming JSON as is on a building's FIRST publication, so
-- strip any meshAssets there (they would be unvalidated, would count toward the shared quota, and could name another user's folder).
-- IMPORTANT: extend_building upserts (`insert ... on conflict do update set map_json = excluded.map_json`), and a BEFORE INSERT trigger
-- fires on that path too. The strip therefore applies ONLY when no row exists yet; otherwise it would wipe the stored mesh list every
-- time anyone extends a building (found by the 2026-10-18 review; regression test in supabase/tests/mesh_publish_and_read.sql). For an
-- existing building the list is already the stored, validated one (extend_building builds its result from the stored JSON).
create or replace function public.strip_incoming_mesh_assets() returns trigger
language plpgsql set search_path = '' as $$
begin
  if not exists (select 1 from public.canonical_buildings b where b.map_id = new.map_id) then
    new.map_json := new.map_json - 'meshAssets';
  end if;
  return new;
end $$;
drop trigger if exists strip_incoming_mesh_assets on public.canonical_buildings;
create trigger strip_incoming_mesh_assets before insert on public.canonical_buildings
  for each row execute function public.strip_incoming_mesh_assets();

-- One-time cleanup of mesh lists that predate this migration: keep an entry only if it passes the checks publish_mesh_assets applies
-- (storageOwner is the segment's contributor; the file exists in storage with exactly the listed size), then apply the limits, oldest
-- entries first: 25 files / 40 MB per contributor and 100 files / 80 MB per building. Dropped entries can be listed again with
-- publish_mesh_assets; their files are not deleted.
update public.canonical_buildings c
   set map_json = c.map_json || jsonb_build_object('meshAssets', coalesce((
         select jsonb_agg(v.m order by v.ord)
           from (
             select t.m, t.ord,
                    count(*) over (partition by lower(t.m->>'storageOwner') order by t.ord) as owner_files,
                    sum((t.m->>'byteCount')::numeric) over (partition by lower(t.m->>'storageOwner') order by t.ord) as owner_bytes,
                    count(*) over (order by t.ord) as all_files,
                    sum((t.m->>'byteCount')::numeric) over (order by t.ord) as all_bytes
               from jsonb_array_elements(c.map_json->'meshAssets') with ordinality as t(m, ord)
              where lower(coalesce(c.segment_owners->>(t.m->>'segmentId'), '')) = lower(t.m->>'storageOwner')
                and exists (select 1 from storage.objects o
                             where o.bucket_id = 'meshes'
                               and o.name = lower(t.m->>'storageOwner') || '/' || c.map_id::text || '/' || lower(t.m->>'id') || '.obj'
                               and (o.metadata->>'size')::numeric = (t.m->>'byteCount')::numeric)
           ) v
          where v.owner_files <= 25 and v.owner_bytes <= 40000000 and v.all_files <= 100 and v.all_bytes <= 80000000
       ), '[]'::jsonb))
 where jsonb_typeof(c.map_json->'meshAssets') = 'array';

-- Delist your own mesh (the file stays in your folder; delete it with the Storage API if wanted).
create or replace function public.remove_mesh_asset(building uuid, asset_id uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare actor uuid := auth.uid();
begin
  if actor is null then raise exception 'Sign in first'; end if;
  perform pg_advisory_xact_lock(hashtextextended(building::text, 0));
  update public.canonical_buildings c
     set map_json = c.map_json || jsonb_build_object('meshAssets',
           (select coalesce(jsonb_agg(m), '[]'::jsonb) from jsonb_array_elements(c.map_json->'meshAssets') m
             where not (lower(m->>'id') = lower(asset_id::text) and lower(m->>'storageOwner') = actor::text))),
         updated_at = now()
   where c.map_id = building and jsonb_typeof(c.map_json->'meshAssets') = 'array';
end $$;
revoke all on function public.remove_mesh_asset(uuid, uuid) from public, anon;
grant execute on function public.remove_mesh_asset(uuid, uuid) to authenticated;

commit;
