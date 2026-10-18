-- File: supabase/migrations/0010_geometry_validator_alias.sql
-- Owner: D / U3. Compatibility helper refresh after 0009; supports schema 1 through 4.
begin;
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
revoke all on function public.waypoint_validate_geometry(jsonb) from public, anon, authenticated;
commit;
