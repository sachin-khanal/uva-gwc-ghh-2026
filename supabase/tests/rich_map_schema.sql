-- File: supabase/tests/rich_map_schema.sql
-- Owner: U3. Run against the deployed schema-3 mesh publication API. Transactional metadata tests, no real mesh files.
begin;
insert into auth.users(id) values ('10000000-0000-4000-8000-000000000004');
do $$
declare
  legacy jsonb := '{"id":"20000000-0000-4000-8000-000000000004","name":"Schema test","version":1,"nodes":[{"id":"30000000-0000-4000-8000-000000000041","kind":"room","position":[0,0,0],"segmentId":"a","createdBy":"test"}],"edges":[]}';
  rich jsonb; actual jsonb; rejected boolean := false;
begin
  perform set_config('request.jwt.claim.sub','10000000-0000-4000-8000-000000000004',true);
  perform public.extend_building(legacy);
  rich := jsonb_set(legacy,'{nodes,0,extent}',
    '{"center":[0,-1.4,0],"halfExtents":[2,3],"yaw":0,"areaSquareMeters":24}'::jsonb);
  rich := rich || jsonb_build_object('schemaVersion',3,'meshAssets',jsonb_build_array(jsonb_build_object(
    'id','aaaaaaaa-0000-4000-8000-000000000004','segmentId','a','format','obj','coordinateFrame','map',
    'byteCount',32,'sha256',repeat('a',64),'boundsMin',jsonb_build_array(0,0,0),'boundsMax',jsonb_build_array(1,1,1),
    'storageOwner','10000000-0000-4000-8000-000000000004')));
  perform public.extend_building(rich);
  insert into storage.objects(bucket_id,name,metadata) values ('meshes',
    '10000000-0000-4000-8000-000000000004/20000000-0000-4000-8000-000000000004/aaaaaaaa-0000-4000-8000-000000000004.obj', '{"size":32}');
  perform public.publish_mesh_assets((legacy->>'id')::uuid, rich->'meshAssets');
  perform public.extend_building(legacy || '{"schemaVersion":2}'::jsonb);
  select map_json into actual from public.canonical_buildings where map_id = (legacy->>'id')::uuid;
  if actual->>'schemaVersion' is distinct from '3' or actual->'nodes'->0->'extent' is distinct from rich->'nodes'->0->'extent'
     or jsonb_array_length(actual->'meshAssets') is distinct from 1 then
    raise exception 'FAIL: stale upload erased rich data or downgraded format';
  end if;
  begin
    perform public.extend_building(jsonb_set(rich,'{nodes,0,extent,halfExtents}','[-1,3]'::jsonb));
  exception when raise_exception then rejected := true;
  end;
  if not rejected then raise exception 'FAIL: invalid extent accepted'; end if;
  rejected := false;
  begin
    perform public.extend_building(rich || '{"schemaVersion":4}'::jsonb);
  exception when raise_exception then rejected := true;
  end;
  if not rejected then raise exception 'FAIL: future schema accepted'; end if;
  perform public.publish_mesh_assets((legacy->>'id')::uuid,
    jsonb_set(rich,'{meshAssets,0,sha256}',to_jsonb(repeat('b',64)))->'meshAssets');
  select map_json into actual from public.canonical_buildings where map_id = (legacy->>'id')::uuid;
  if actual->'meshAssets'->0->>'sha256' is distinct from repeat('a',64) then
    raise exception 'FAIL: immutable mesh replaced';
  end if;
  raise notice 'PASS: schema upgrade, room enrichment, immutable mesh manifest, no stale downgrade';
end $$;
rollback;
