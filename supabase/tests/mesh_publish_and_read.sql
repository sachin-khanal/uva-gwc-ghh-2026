-- Owner: U3 / D. Managed-Supabase compatible mesh publication and RLS regression.
-- Fixtures and temporary grants are contained in BEGIN/ROLLBACK. Assertions scope to test map IDs.
-- File:   supabase/tests/mesh_publish_and_read.sql
-- Owner:  U3 / U1 (added 2026-10-18, branch feature/web-mesh-obj)
-- Purpose: proves migration 0008: publish_mesh_assets accepts only the segment owner's well-formed, append-only OBJ entries, and the
--          meshes read rule lets ANOTHER signed-in user download exactly the listed paths and nothing else.
-- Run:    needs migrations 0001..0005 and 0008 applied in a THROWAWAY Postgres (it inserts test rows and deletes them). Locally:
--           docker run -d --name wp-pg -e POSTGRES_PASSWORD=pw public.ecr.aws/supabase/postgres:17.6.1.136   (wait for pg_isready)
--           the bare image has no `storage` service tables: create stand-ins for storage.buckets/objects/foldername/filename first
--           then: docker exec wp-pg psql -U supabase_admin -d postgres -v ON_ERROR_STOP=1 -f /tmp/<file>.sql  for each migration, then this file
--         A plain Postgres lacks Supabase's default grants, so this file grants SELECT on the legacy public.buildings table
--         (referenced by the older 0001 storage read rule) to `authenticated`, as a real project does.
-- Expect: every line prints PASS; any failure raises an exception and stops.
begin;

create temp table t(a uuid default 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', b uuid default 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
                    m uuid default '11111111-1111-4111-8111-111111111111', asset uuid default '22222222-2222-4222-8222-222222222222');
insert into t default values;
grant select on t to authenticated;
grant select on public.buildings to authenticated;
insert into auth.users(id) values ('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'), ('bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'); -- rolled back at the end
insert into storage.objects(bucket_id, name, metadata) values
  ('meshes', 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa/11111111-1111-4111-8111-111111111111/22222222-2222-4222-8222-222222222222.obj', '{"size": 1000}'),
  ('meshes', 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa/11111111-1111-4111-8111-111111111111/44444444-4444-4444-8444-444444444444.obj', '{"size": 1000}');

-- user A publishes a one-room building (segment seg1 becomes A's)
select set_config('request.jwt.claim.sub', 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', true), set_config('request.jwt.claims', '{"sub":"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa","role":"authenticated"}', true);
set local role authenticated;
select public.extend_building('{"schemaVersion":3,"id":"11111111-1111-4111-8111-111111111111","name":"ZZ MESH TEST","version":1,
  "nodes":[{"id":"33333333-3333-4333-8333-333333333333","segmentId":"seg1","kind":"corridor","createdBy":"x","position":[0,0,0]}],"edges":[]}'::jsonb);

create or replace function pg_temp.asset(owner text, seg text, bytes int default 1000) returns jsonb language sql as $$
  select jsonb_build_object('id','22222222-2222-4222-8222-222222222222','segmentId',seg,'format','obj','coordinateFrame','map',
    'byteCount',bytes,'sha256',repeat('a',64),'boundsMin','[0,0,0]'::jsonb,'boundsMax','[1,1,1]'::jsonb,'storageOwner',owner) $$;

do $$ begin
  perform public.publish_mesh_assets('11111111-1111-4111-8111-111111111111', jsonb_build_array(pg_temp.asset('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa','seg1')));
  assert (select jsonb_array_length(map_json->'meshAssets') from public.canonical_buildings where map_id = '11111111-1111-4111-8111-111111111111') = 1, 'asset listed';
  raise notice 'PASS owner can list a mesh';
  -- same id again: skipped, not duplicated or replaced
  perform public.publish_mesh_assets('11111111-1111-4111-8111-111111111111', jsonb_build_array(jsonb_set(pg_temp.asset('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa','seg1'), '{sha256}', to_jsonb(repeat('b',64)))));
  assert (select jsonb_array_length(map_json->'meshAssets') from public.canonical_buildings where map_id = '11111111-1111-4111-8111-111111111111') = 1, 'append-only';
  assert (select map_json->'meshAssets'->0->>'sha256' from public.canonical_buildings where map_id = '11111111-1111-4111-8111-111111111111') = repeat('a',64), 'never replaced';
  raise notice 'PASS append-only';
end $$;

-- bad inputs, each must raise
do $$ declare ok boolean; begin
  ok := false; begin perform public.publish_mesh_assets('11111111-1111-4111-8111-111111111111', jsonb_build_array(jsonb_set(pg_temp.asset('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa','seg9'), '{id}', '"44444444-4444-4444-8444-444444444444"'))); exception when others then ok := true; end;
  assert ok, 'unknown segment must be refused'; raise notice 'PASS unknown segment refused';
  ok := false; begin perform public.publish_mesh_assets('11111111-1111-4111-8111-111111111111', jsonb_build_array(jsonb_set(pg_temp.asset('bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb','seg1'), '{id}', '"44444444-4444-4444-8444-444444444444"'))); exception when others then ok := true; end;
  assert ok, 'foreign storageOwner must be refused'; raise notice 'PASS storageOwner must be the caller';
  ok := false; begin perform public.publish_mesh_assets('11111111-1111-4111-8111-111111111111', jsonb_build_array(jsonb_set(pg_temp.asset('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa','seg1', 40000001), '{id}', '"44444444-4444-4444-8444-444444444444"'))); exception when others then ok := true; end;
  assert ok, 'oversize must be refused'; raise notice 'PASS oversize refused';
  ok := false; begin perform public.publish_mesh_assets('11111111-1111-4111-8111-111111111111', jsonb_build_array(jsonb_set(jsonb_set(pg_temp.asset('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa','seg1'), '{id}', '"44444444-4444-4444-8444-444444444444"'), '{sha256}', '"XYZ"'))); exception when others then ok := true; end;
  assert ok, 'bad hash must be refused'; raise notice 'PASS bad checksum refused';
  ok := false; begin perform public.publish_mesh_assets('99999999-9999-4999-8999-999999999999', jsonb_build_array(pg_temp.asset('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa','seg1'))); exception when others then ok := true; end;
  assert ok, 'unknown building must be refused'; raise notice 'PASS unknown building refused';
end $$;

-- user B cannot list a mesh on A's segment
select set_config('request.jwt.claim.sub', 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb', true), set_config('request.jwt.claims', '{"sub":"bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb","role":"authenticated"}', true);
do $$ declare ok boolean; begin
  ok := false; begin perform public.publish_mesh_assets('11111111-1111-4111-8111-111111111111', jsonb_build_array(jsonb_set(pg_temp.asset('bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb','seg1'), '{id}', '"55555555-5555-4555-8555-555555555555"'))); exception when others then ok := true; end;
  assert ok, 'another user must not list a mesh on a segment they did not contribute'; raise notice 'PASS other user refused';
end $$;

-- B EXTENDS A's building with a new segment: A's listed mesh must survive (regression: a first-publication strip trigger that also
-- fired on the upsert's UPDATE path wiped the list on every extension)
do $$ begin
  perform public.extend_building('{"schemaVersion":3,"id":"11111111-1111-4111-8111-111111111111","name":"ZZ MESH TEST","version":1,
    "nodes":[{"id":"33333333-3333-4333-8333-333333333333","segmentId":"seg1","kind":"corridor","createdBy":"x","position":[0,0,0]},
             {"id":"33333333-3333-4333-8333-333333333334","segmentId":"segB","kind":"corridor","createdBy":"y","position":[1,0,0]}],
    "edges":[{"from":"33333333-3333-4333-8333-333333333333","to":"33333333-3333-4333-8333-333333333334","distance":1}]}'::jsonb);
  assert (select jsonb_array_length(map_json->'meshAssets') from public.canonical_buildings where map_id = '11111111-1111-4111-8111-111111111111') = 1,
    'extending a building must not drop its listed meshes';
  assert (select jsonb_array_length(map_json->'nodes') from public.canonical_buildings where map_id = '11111111-1111-4111-8111-111111111111') = 2, 'extension applied';
  raise notice 'PASS extending a building keeps its listed meshes';
end $$;

-- file not uploaded / wrong size must be refused (as A again)
select set_config('request.jwt.claim.sub', 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', true), set_config('request.jwt.claims', '{"sub":"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa","role":"authenticated"}', true);
do $$ declare ok boolean; begin
  ok := false; begin perform public.publish_mesh_assets('11111111-1111-4111-8111-111111111111', jsonb_build_array(jsonb_set(pg_temp.asset('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa','seg1'), '{id}', '"77777777-7777-4777-8777-777777777777"'))); exception when others then ok := true; end;
  assert ok, 'a mesh that was never uploaded must be refused'; raise notice 'PASS not-uploaded mesh refused';
  ok := false; begin perform public.publish_mesh_assets('11111111-1111-4111-8111-111111111111', jsonb_build_array(jsonb_set(pg_temp.asset('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa','seg1', 999), '{id}', '"44444444-4444-4444-8444-444444444444"'))); exception when others then ok := true; end;
  assert ok, 'wrong size must be refused'; raise notice 'PASS wrong-size mesh refused';
  -- delist and relist (uploaded file 4444... exists)
  perform public.publish_mesh_assets('11111111-1111-4111-8111-111111111111', jsonb_build_array(jsonb_set(pg_temp.asset('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa','seg1'), '{id}', '"44444444-4444-4444-8444-444444444444"')));
  assert (select jsonb_array_length(map_json->'meshAssets') from public.canonical_buildings where map_id = '11111111-1111-4111-8111-111111111111') = 2, 'two listed';
  perform public.remove_mesh_asset('11111111-1111-4111-8111-111111111111', '44444444-4444-4444-8444-444444444444');
  assert (select jsonb_array_length(map_json->'meshAssets') from public.canonical_buildings where map_id = '11111111-1111-4111-8111-111111111111') = 1, 'owner can delist';
  raise notice 'PASS owner can delist';
end $$;
select set_config('request.jwt.claim.sub', 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb', true), set_config('request.jwt.claims', '{"sub":"bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb","role":"authenticated"}', true);
do $$ begin
  perform public.remove_mesh_asset('11111111-1111-4111-8111-111111111111', '22222222-2222-4222-8222-222222222222');
  assert (select jsonb_array_length(map_json->'meshAssets') from public.canonical_buildings where map_id = '11111111-1111-4111-8111-111111111111') = 1, 'another user cannot delist';
  raise notice 'PASS other user cannot delist';
end $$;

-- storage read rule: B can read exactly the listed path
reset role;
insert into storage.objects(bucket_id, name, metadata) values
  ('meshes', 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa/11111111-1111-4111-8111-111111111111/66666666-6666-4666-8666-666666666666.obj', '{"size": 1000}'),
  ('meshes', 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa/11111111-1111-4111-8111-111111111111/22222222-2222-4222-8222-222222222222.obj.evil', '{"size": 1000}'),
  ('worldmaps', 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa/11111111-1111-4111-8111-111111111111/22222222-2222-4222-8222-222222222222.obj', '{"size": 1000}');
-- A first publication carrying meshAssets has them stripped by the trigger.
insert into public.canonical_buildings(map_id, owner, name, version, map_json, segment_owners) values
  ('77777777-0000-4000-8000-000000000008', 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb', 'ZZ STRIP', 1,
   '{"schemaVersion":3,"id":"77777777-0000-4000-8000-000000000008","name":"ZZ STRIP","version":1,"nodes":[],"edges":[],"meshAssets":[]}', '{}');
do $$ begin
  assert not (select map_json ? 'meshAssets' from public.canonical_buildings where map_id = '77777777-0000-4000-8000-000000000008'), 'meshAssets stripped on first publication';
  raise notice 'PASS meshAssets stripped on first publication';
end $$;

-- FORGED entry (legacy row that predates the trigger): building 2 is B's, but its first publication named A as the storageOwner of B's segment. B must not be able to
-- read A's file through it.
insert into public.canonical_buildings(map_id, owner, name, version, map_json, segment_owners) values
  ('99999999-9999-4999-8999-999999999999', 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb', 'ZZ FORGED', 1,
   '{"schemaVersion":3,"id":"99999999-9999-4999-8999-999999999999","name":"ZZ FORGED","version":1,
     "nodes":[{"id":"88888888-8888-4888-8888-888888888888","segmentId":"segX","kind":"corridor","createdBy":"x","position":[0,0,0]}],"edges":[]}',
   '{"segX":"bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"}');
update public.canonical_buildings set map_json = map_json || '{"meshAssets":[{"id":"aaaaaaaa-0000-4000-8000-000000000001","segmentId":"segX","format":"obj","coordinateFrame":"map","byteCount":10,
       "sha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","boundsMin":[0,0,0],"boundsMax":[1,1,1],
       "storageOwner":"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"}]}'::jsonb
 where map_id = '99999999-9999-4999-8999-999999999999';
insert into storage.objects(bucket_id, name, metadata) values
  ('meshes', 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa/99999999-9999-4999-8999-999999999999/aaaaaaaa-0000-4000-8000-000000000001.obj', '{"size": 10}');
set local role authenticated;
do $$ declare n int; begin
  select count(*) into n from storage.objects where bucket_id = 'meshes' and name like '%/11111111-1111-4111-8111-111111111111/%';
  assert n = 1, 'B should read exactly the listed mesh, got ' || n;
  raise notice 'PASS other user reads only the listed mesh path, forged owner entry unreadable (% readable)', n;
end $$;

-- a listed file whose stored size no longer matches the listing is not served (swapped after listing)
reset role;
update storage.objects set metadata = '{"size": 999}' where name like '%/22222222-2222-4222-8222-222222222222.obj' and bucket_id = 'meshes';
set local role authenticated;
do $$ declare n int; begin
  select count(*) into n from storage.objects where bucket_id = 'meshes' and name like '%/11111111-1111-4111-8111-111111111111/%';
  assert n = 0, 'a swapped (different size) file must not be readable, got ' || n;
  raise notice 'PASS swapped file not served';
end $$;

rollback;
