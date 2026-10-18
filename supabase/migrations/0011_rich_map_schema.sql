-- File: supabase/migrations/0009_rich_map_schema.sql
-- Owner: D / U3. Apply AFTER 0008. Do not re-run older migrations afterwards.
-- Schema 3 room extents + immutable mesh manifests. Existing rows upgrade on publication.
begin;
create or replace function public.waypoint_vector(v jsonb, n integer)
returns boolean language plpgsql immutable set search_path = '' as $$
declare x jsonb;
begin
  if jsonb_typeof(v) is distinct from 'array' then return false; end if;
  if jsonb_array_length(v) <> n then return false; end if;
  for x in select value from jsonb_array_elements(v) loop
    if jsonb_typeof(x) <> 'number' then return false; end if;
    if abs(x::text::double precision) > 3.4028234663852886e38 then return false; end if;
  end loop;
  return true;
end $$;

create or replace function public.waypoint_validate_geometry(m jsonb)
returns void language plpgsql set search_path = '' as $$
declare n jsonb; e jsonb; a jsonb; assets jsonb; total bigint := 0; ids uuid[] := '{}'; asset_id uuid;
begin
  if coalesce(m->>'schemaVersion', '1') not in ('1','2','3','4') then raise exception 'Unsupported schemaVersion'; end if;
  for n in select value from jsonb_array_elements(m->'nodes') loop
    if n->'stairs' is not null and n->'stairs' <> 'null'::jsonb then
      if n->>'kind' not in ('stairs','elevator') or jsonb_typeof(n->'stairs') is distinct from 'object'
         or (n->'stairs'->>'direction' is not null and n->'stairs'->>'direction' not in ('up','down','both'))
         or (n->'stairs'->>'railings' is not null and n->'stairs'->>'railings' not in ('left','right','both','neither')) then raise exception 'Invalid stairs'; end if;
      if n->'stairs'->>'stepCount' is not null then
        if jsonb_typeof(n->'stairs'->'stepCount') is distinct from 'number' or n->'stairs'->>'stepCount' !~ '^[0-9]{1,5}$' then raise exception 'Invalid step count'; end if;
        if (n->'stairs'->>'stepCount')::integer not between 1 and 10000 then raise exception 'Invalid step count'; end if;
      end if;
    end if;
    e := n->'extent';
    if e is not null and e <> 'null'::jsonb then
      if n->>'kind' <> 'room' or not public.waypoint_vector(e->'center',3)
         or not public.waypoint_vector(e->'halfExtents',2)
         or jsonb_typeof(e->'yaw') is distinct from 'number'
         or jsonb_typeof(e->'areaSquareMeters') is distinct from 'number' then
        raise exception 'Invalid room extent';
      end if;
      if (e->'halfExtents'->>0)::double precision <= 0 or (e->'halfExtents'->>1)::double precision <= 0
         or abs((e->>'yaw')::double precision) > 3.4028234663852886e38
         or (e->>'areaSquareMeters')::double precision <= 0
         or (e->>'areaSquareMeters')::double precision > 3.4028234663852886e38
         or (e->>'areaSquareMeters')::double precision >
           4 * (e->'halfExtents'->>0)::double precision * (e->'halfExtents'->>1)::double precision + 0.01 then
        raise exception 'Invalid room dimensions';
      end if;
      if e->>'heightMeters' is not null then
        if jsonb_typeof(e->'heightMeters') <> 'number' then raise exception 'Invalid height'; end if;
        if (e->>'heightMeters')::double precision <= 0 or (e->>'heightMeters')::double precision > 3.4028234663852886e38 then
          raise exception 'Invalid height';
        end if;
      end if;
    end if;
  end loop;
  assets := coalesce(nullif(m->'meshAssets','null'::jsonb),'[]'::jsonb);
  if jsonb_typeof(assets) <> 'array' then raise exception 'Invalid meshAssets'; end if;
  if jsonb_array_length(assets) > 100 then raise exception 'Too many mesh assets'; end if;
  for a in select value from jsonb_array_elements(assets) loop
    asset_id := (a->>'id')::uuid;
    if asset_id is null or asset_id = any(ids)
       or a->>'format' is distinct from 'obj' or a->>'coordinateFrame' is distinct from 'map'
       or coalesce(a->>'sha256','') !~ '^[a-f0-9]{64}$'
       or jsonb_typeof(a->'byteCount') is distinct from 'number'
       or coalesce(a->>'byteCount','') !~ '^[0-9]{1,8}$'
       or not public.waypoint_vector(a->'boundsMin',3) or not public.waypoint_vector(a->'boundsMax',3)
       or not exists (select 1 from jsonb_array_elements(m->'nodes') as node_entry(value) where node_entry.value->>'segmentId' = a->>'segmentId') then
      raise exception 'Invalid mesh manifest';
    end if;
    if (a->>'byteCount')::bigint not between 1 and 40000000 then raise exception 'Mesh exceeds 40 MB'; end if;
    if (a->'boundsMin'->>0)::double precision > (a->'boundsMax'->>0)::double precision
       or (a->'boundsMin'->>1)::double precision > (a->'boundsMax'->>1)::double precision
       or (a->'boundsMin'->>2)::double precision > (a->'boundsMax'->>2)::double precision then
      raise exception 'Inverted mesh bounds';
    end if;
    if a->>'storageOwner' is null or (a->>'storageOwner')::uuid is null then raise exception 'Mesh needs storage owner'; end if;
    total := total + (a->>'byteCount')::bigint;
    ids := array_append(ids,asset_id);
  end loop;
  if total > 80000000 then raise exception 'Mesh assets exceed 80 MB total'; end if;
end $$;

-- The merge implementation is replaced below; the 0003 shortcut-checking wrapper stays active.

create or replace function public.merge_building_internal(incoming jsonb)
returns void language plpgsql security definer set search_path = '' as $$
declare
  actor uuid := auth.uid();
  building uuid := (incoming->>'id')::uuid;
  previous public.canonical_buildings%rowtype;
  combined jsonb;
  nodes jsonb;
  edges jsonb;
  owners jsonb;
  item jsonb;
  existing jsonb;
  seg text;
  revision integer;
  a jsonb;
  b jsonb;
  straight double precision;
  assets jsonb;
  asset jsonb;
  old_asset jsonb;
begin
  if actor is null then raise exception 'Sign in first'; end if;
  if building is null or jsonb_typeof(incoming->'name') is distinct from 'string'
     or length(incoming->>'name') not between 1 and 200
     or jsonb_typeof(incoming->'nodes') is distinct from 'array'
     or jsonb_typeof(incoming->'edges') is distinct from 'array' then
    raise exception 'Invalid map';
  end if;
  perform public.waypoint_validate_geometry(incoming);
  -- Serialize both first publication and later extensions for this UUID.
  perform pg_advisory_xact_lock(hashtextextended(building::text, 0));
  select * into previous from public.canonical_buildings where map_id = building for update;
  nodes := coalesce(previous.map_json->'nodes', '[]'::jsonb);
  edges := coalesce(previous.map_json->'edges', '[]'::jsonb);
  owners := coalesce(previous.segment_owners, '{}'::jsonb);
  for item in select value from jsonb_array_elements(incoming->'nodes') loop
    if (item->>'id')::uuid is null
       or coalesce(item->>'segmentId', '') !~ '^[A-Za-z0-9_-]{1,64}$'
       or coalesce(item->>'kind', '') not in ('corridor','door','stairs','elevator','room','junction')
       or jsonb_typeof(item->'createdBy') is distinct from 'string'
       or jsonb_typeof(item->'position') is distinct from 'array'
       or jsonb_array_length(item->'position') <> 3 then
      raise exception 'Invalid node';
    end if;
    for a in select value from jsonb_array_elements(item->'position') loop
      if jsonb_typeof(a) <> 'number' or abs(a::text::double precision) > 3.4028234663852886e38 then
        raise exception 'Invalid position';
      end if;
    end loop;
    select value into existing from jsonb_array_elements(nodes)
      where (value->>'id')::uuid = (item->>'id')::uuid;
    if found then
      if (existing - 'extent' - 'stairs') <> (item - 'extent' - 'stairs') then raise exception 'An existing node cannot be changed'; end if;
      if existing->>'extent' is not null and item->>'extent' is not null and existing->'extent' <> item->'extent' then raise exception 'Existing room extent cannot be replaced'; end if;
      if existing->>'stairs' is not null and item->>'stairs' is not null and existing->'stairs' <> item->'stairs' then raise exception 'Existing stair metadata cannot be replaced'; end if;
      item := existing || jsonb_strip_nulls(item);
      select jsonb_agg(case when (value->>'id')::uuid = (item->>'id')::uuid then item else value end)
        into nodes from jsonb_array_elements(nodes);
      continue;
    end if;
    seg := item->>'segmentId';
    -- New scans need unique segment IDs; another contributor cannot replace a scan frame.
    if owners ? seg and owners->>seg <> actor::text then
      raise exception 'Use a new segment ID for your extension';
    end if;
    owners := owners || jsonb_build_object(seg, actor::text);
    nodes := nodes || jsonb_build_array(item);
  end loop;
  for item in select value from jsonb_array_elements(incoming->'edges') loop
    select value into a from jsonb_array_elements(nodes) where (value->>'id')::uuid = (item->>'from')::uuid;
    select value into b from jsonb_array_elements(nodes) where (value->>'id')::uuid = (item->>'to')::uuid;
    if a is null or b is null or (item->>'from')::uuid = (item->>'to')::uuid
       or jsonb_typeof(item->'distance') is distinct from 'number' then
      raise exception 'Invalid edge';
    end if;
    straight := sqrt(power((a->'position'->>0)::double precision - (b->'position'->>0)::double precision, 2)
                   + power((a->'position'->>1)::double precision - (b->'position'->>1)::double precision, 2)
                   + power((a->'position'->>2)::double precision - (b->'position'->>2)::double precision, 2));
    if abs((item->>'distance')::double precision - straight) > greatest(0.5, straight * 0.25) then
      raise exception 'Edge distance does not match positions';
    end if;
    select value into existing from jsonb_array_elements(edges)
      where ((value->>'from')::uuid = (item->>'from')::uuid and (value->>'to')::uuid = (item->>'to')::uuid)
         or ((value->>'from')::uuid = (item->>'to')::uuid and (value->>'to')::uuid = (item->>'from')::uuid);
    if found then
      if existing->'distance' <> item->'distance'
         or coalesce(existing->'hazard', 'null'::jsonb) <> coalesce(item->'hazard', 'null'::jsonb) then
        raise exception 'An existing edge cannot be changed';
      end if;
    else
      edges := edges || jsonb_build_array(item);
    end if;
  end loop;
  assets := coalesce(nullif(previous.map_json->'meshAssets','null'::jsonb),'[]'::jsonb);
  -- Mesh lists are changed ONLY by publish_mesh_assets/remove_mesh_asset (0008).
  -- Keep stored, approved assets on extension; never accept them through extend_building.
  revision := coalesce(previous.version, 0) + 1;
  combined := coalesce(previous.map_json, incoming) || jsonb_build_object('nodes', nodes, 'edges', edges, 'version', revision, 'schemaVersion', 4, 'meshAssets', assets);
  -- Preserve visual relocalization fingerprints contributed by either scan.
  if jsonb_typeof(incoming->'keyframes') = 'array' or jsonb_typeof(previous.map_json->'keyframes') = 'array' then
    combined := combined || jsonb_build_object('keyframes', (
      select coalesce(jsonb_agg(frame), '[]'::jsonb) from (
        select distinct on (frame->>'id') frame
        from (
          select value as frame, 0 as priority from jsonb_array_elements(coalesce(nullif(previous.map_json->'keyframes','null'::jsonb),'[]'::jsonb))
          union all
          select value as frame, 1 as priority from jsonb_array_elements(coalesce(nullif(incoming->'keyframes','null'::jsonb),'[]'::jsonb))
        ) frames order by frame->>'id', priority
      ) unique_frames
    ));
  end if;
  perform public.waypoint_validate_geometry(combined);
  if jsonb_array_length(nodes) > 5000 or jsonb_array_length(edges) > 20000
     or pg_column_size(combined) >= 2000000 then raise exception 'Map too large'; end if;
  insert into public.canonical_buildings(map_id, owner, name, version, map_json, segment_owners)
    values(building, actor, combined->>'name', revision, combined, owners)
    on conflict (map_id) do update set version = excluded.version, map_json = excluded.map_json,
      segment_owners = excluded.segment_owners, updated_at = now();
end $$;

revoke all on function public.merge_building_internal(jsonb) from public, anon, authenticated;
revoke all on function public.waypoint_vector(jsonb,integer) from public, anon, authenticated;
revoke all on function public.waypoint_validate_geometry(jsonb) from public, anon, authenticated;
-- Retain 0008's exact-path, segment-owner and size-checked canonical_meshes_read.
-- Do not recreate the obsolete permissive canonical_mesh_read policy.
commit;
