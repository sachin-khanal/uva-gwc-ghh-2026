-- File: supabase/tests/extension_connections.sql
-- Owner: U3. Run after migration 0003. No test data persists.
-- Test both the shortcut rejection and a legitimate new-node extension.
begin;
insert into auth.users(id) values ('10000000-0000-4000-8000-000000000003');
do $$
declare
  original jsonb := '{"id":"20000000-0000-4000-8000-000000000003","name":"Connection test","version":1,"nodes":[{"id":"30000000-0000-4000-8000-000000000031","kind":"corridor","position":[0,0,0],"segmentId":"a","createdBy":"test"},{"id":"30000000-0000-4000-8000-000000000032","kind":"corridor","position":[0,0,-3],"segmentId":"a","createdBy":"test"}],"edges":[]}';
  candidate jsonb;
  rejected boolean := false;
  row_count integer;
begin
  perform set_config('request.jwt.claim.sub', '10000000-0000-4000-8000-000000000003', true);
  perform public.extend_building(original);
  candidate := original || '{"edges":[{"from":"30000000-0000-4000-8000-000000000031","to":"30000000-0000-4000-8000-000000000032","distance":3}]}'::jsonb;
  begin
    perform public.extend_building(candidate);
  exception when raise_exception then
    if sqlerrm not like 'Incoming map adds a new connection%' then raise; end if;
    rejected := true;
  end;
  if not rejected then raise exception 'FAIL: old-node shortcut accepted'; end if;
  candidate := original || jsonb_build_object('nodes', (original->'nodes') ||
    '[{"id":"30000000-0000-4000-8000-000000000033","kind":"corridor","position":[0,0,-1.5],"segmentId":"b","createdBy":"test"}]'::jsonb,
    'edges', '[{"from":"30000000-0000-4000-8000-000000000031","to":"30000000-0000-4000-8000-000000000033","distance":1.5},{"from":"30000000-0000-4000-8000-000000000033","to":"30000000-0000-4000-8000-000000000032","distance":1.5}]'::jsonb);
  perform public.extend_building(candidate);
  -- Replaying existing connections in either direction remains legal.
  perform public.extend_building(candidate);
  candidate := candidate || '{"edges":[{"from":"30000000-0000-4000-8000-000000000033","to":"30000000-0000-4000-8000-000000000031","distance":1.5}]}'::jsonb;
  perform public.extend_building(candidate);
  select jsonb_array_length(map_json->'edges') into row_count from public.canonical_buildings
    where map_id = (original->>'id')::uuid;
  if row_count <> 2 then raise exception 'FAIL: extension missing or duplicated edges'; end if;
  raise notice 'PASS: shortcuts rejected; new-node extensions and repeat uploads accepted';
end $$;
rollback;
