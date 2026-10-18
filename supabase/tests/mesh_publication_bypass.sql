-- Owner: U3 / D. Regression found by live viewer QA, 2026-10-18.
-- KNOWN FAILURE on the deployed database: extend_building can add a mesh manifest on update
-- without publish_mesh_assets checking that the file exists. All fixture changes roll back.
begin;
insert into auth.users(id) values ('10000000-0000-4000-8000-000000000005');
do $$
declare
  m jsonb := '{"schemaVersion":3,"id":"20000000-0000-4000-8000-000000000005","name":"Viewer unpublished mesh regression","version":1,"nodes":[{"id":"30000000-0000-4000-8000-000000000005","kind":"room","position":[0,0,0],"segmentId":"test","createdBy":"qa"}],"edges":[]}';
  actual jsonb;
begin
  perform set_config('request.jwt.claim.sub','10000000-0000-4000-8000-000000000005',true);
  perform public.extend_building(m);
  m := m || jsonb_build_object('meshAssets',jsonb_build_array(jsonb_build_object(
    'id','aaaaaaaa-0000-4000-8000-000000000005','segmentId','test','format','obj','coordinateFrame','map',
    'byteCount',32,'sha256',repeat('a',64),'boundsMin','[0,0,0]'::jsonb,'boundsMax','[1,1,1]'::jsonb,
    'storageOwner','10000000-0000-4000-8000-000000000005')));
  perform public.extend_building(m);
  select map_json into strict actual from public.canonical_buildings where map_id=(m->>'id')::uuid;
  if jsonb_array_length(coalesce(actual->'meshAssets','[]'::jsonb)) <> 0 then
    raise exception 'FAIL: extend_building accepted a mesh with no uploaded file; publish_mesh_assets was bypassed';
  end if;
end $$;
rollback;
