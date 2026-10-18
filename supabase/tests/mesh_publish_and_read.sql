-- File:   supabase/tests/mesh_publish_and_read.sql
-- Owner:  U3 / U1 (added 2026-10-18, branch feature/web-mesh-obj)
-- Purpose: proves migration 0007: publish_mesh_assets accepts only the segment owner's well-formed, append-only OBJ entries, and the
--          meshes read rule lets ANOTHER signed-in user download exactly the listed paths and nothing else.
-- Run:    needs migrations 0001..0005 and 0007 applied in a THROWAWAY Postgres (it inserts test rows and deletes them). Locally:
--           docker run -d --name wp-pg -e POSTGRES_PASSWORD=pw public.ecr.aws/supabase/postgres:17.6.1.136   (wait for pg_isready)
--           the bare image has no `storage` service tables: create stand-ins for storage.buckets/objects/foldername/filename first
--           then: docker exec wp-pg psql -U supabase_admin -d postgres -v ON_ERROR_STOP=1 -f /tmp/<file>.sql  for each migration, then this file
--         A plain Postgres lacks Supabase's default grants, so this file grants SELECT on the legacy public.buildings table
--         (referenced by the older 0001 storage read rule) to `authenticated`, as a real project does.
-- Expect: every line prints PASS; any failure raises an exception and stops.
\set ON_ERROR_STOP on
begin;

create temp table t(a uuid default 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', b uuid default 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
                    m uuid default '11111111-1111-4111-8111-111111111111', asset uuid default '22222222-2222-4222-8222-222222222222');
insert into t default values;
grant select on t to authenticated;
grant select on public.buildings to authenticated;
insert into auth.users(id) values ('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'), ('bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'); -- rolled back at the end

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
  assert (select jsonb_array_length(map_json->'meshAssets') from public.canonical_buildings) = 1, 'asset listed';
  raise notice 'PASS owner can list a mesh';
  -- same id again: skipped, not duplicated or replaced
  perform public.publish_mesh_assets('11111111-1111-4111-8111-111111111111', jsonb_build_array(pg_temp.asset('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa','seg1', 2000)));
  assert (select jsonb_array_length(map_json->'meshAssets') from public.canonical_buildings) = 1, 'append-only';
  assert (select (map_json->'meshAssets'->0->>'byteCount')::int from public.canonical_buildings) = 1000, 'never replaced';
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

-- storage read rule: B can read exactly the listed path
reset role;
insert into storage.objects(bucket_id, name) values
  ('meshes', 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa/11111111-1111-4111-8111-111111111111/22222222-2222-4222-8222-222222222222.obj'),
  ('meshes', 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa/11111111-1111-4111-8111-111111111111/66666666-6666-4666-8666-666666666666.obj'),
  ('meshes', 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa/11111111-1111-4111-8111-111111111111/22222222-2222-4222-8222-222222222222.obj.evil'),
  ('worldmaps', 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa/11111111-1111-4111-8111-111111111111/22222222-2222-4222-8222-222222222222.obj');
set local role authenticated;
do $$ declare n int; begin
  select count(*) into n from storage.objects where bucket_id = 'meshes';
  assert n = 1, 'B should read exactly the listed mesh, got ' || n;
  raise notice 'PASS other user reads only the listed mesh path (% readable)', n;
end $$;

rollback;
