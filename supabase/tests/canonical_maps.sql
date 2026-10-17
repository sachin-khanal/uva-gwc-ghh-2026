-- Owner: U3. Run in SQL Editor AFTER 0002. All fixtures roll back.
-- Focused functional regression: two contributors extend one shared building.
begin;
insert into auth.users(id) values
 ('10000000-0000-4000-8000-000000000001'),
 ('10000000-0000-4000-8000-000000000002');
do $$
declare
  first_map jsonb := '{"id":"20000000-0000-4000-8000-000000000001","name":"Canonical test","version":1,"nodes":[{"id":"30000000-0000-4000-8000-000000000001","kind":"corridor","position":[0,0,0],"segmentId":"testA","createdBy":"test"}],"edges":[]}';
  extension jsonb;
  result jsonb;
begin
  perform set_config('request.jwt.claim.sub', '10000000-0000-4000-8000-000000000001', true);
  perform public.extend_building(first_map);
  perform set_config('request.jwt.claim.sub', '10000000-0000-4000-8000-000000000002', true);
  extension := first_map || jsonb_build_object('nodes', (first_map->'nodes') ||
    '[{"id":"30000000-0000-4000-8000-000000000002","kind":"room","label":"Room 2","position":[0,0,-3],"segmentId":"testB","createdBy":"test"}]'::jsonb,
    'edges', '[{"from":"30000000-0000-4000-8000-000000000001","to":"30000000-0000-4000-8000-000000000002","distance":3}]'::jsonb);
  perform public.extend_building(extension);
  -- A stale upload must not erase the other contributor's additions.
  perform set_config('request.jwt.claim.sub', '10000000-0000-4000-8000-000000000001', true);
  perform public.extend_building(first_map);
  select map_json into result from public.canonical_buildings where map_id = (first_map->>'id')::uuid;
  if jsonb_array_length(result->'nodes') <> 2 or jsonb_array_length(result->'edges') <> 1 then
    raise exception 'FAIL: extension lost';
  end if;
  if (select count(*) from public.canonical_buildings where map_id = (first_map->>'id')::uuid) <> 1 then
    raise exception 'FAIL: duplicate main maps';
  end if;
  if (select segment_owners->>'testB' from public.canonical_buildings where map_id = (first_map->>'id')::uuid)
     <> '10000000-0000-4000-8000-000000000002' then
    raise exception 'FAIL: scan contributor lost';
  end if;
  raise notice 'PASS: one map, additive extension, stale upload preserves additions, scan ownership';
end $$;
rollback;
