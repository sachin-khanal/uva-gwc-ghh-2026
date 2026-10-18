-- File:   supabase/tests/abuse_limits.sql
-- Purpose: tests supabase/migrations/0006 (upload name shape, per-account file cap, building caps) against STAND-IN tables in a local Postgres.
-- Run:    docker run -d --name wp-pg -e POSTGRES_PASSWORD=pw public.ecr.aws/supabase/postgres:17.6.1.136 ; wait for pg_isready
--         sed 's/storage\.objects/stubstorage.objects/g' supabase/migrations/0006_abuse_limits.sql > /tmp/0006.sql   (the stand-in schema name)
--         docker cp /tmp/0006.sql wp-pg:/tmp/0006.sql ; docker cp supabase/tests/abuse_limits.sql wp-pg:/tmp/t.sql
--         docker exec wp-pg psql -U supabase_admin -d postgres -f /tmp/t.sql          then docker rm -f wp-pg
-- Expect: every line says ok.
\set ON_ERROR_STOP off
create schema if not exists stubstorage;
create table stubstorage.objects (id uuid default gen_random_uuid(), bucket_id text, name text, owner uuid);
alter table stubstorage.objects enable row level security;
grant usage on schema stubstorage to authenticated; grant select, insert, update on stubstorage.objects to authenticated;
create policy readall on stubstorage.objects for select to authenticated using (true);
create table public.canonical_buildings (map_id uuid default gen_random_uuid(), owner uuid not null, name text default 'x');
grant select, insert on public.canonical_buildings to authenticated;
\i /tmp/0006.sql
\set U '11111111-1111-4111-8111-111111111111'
\set B '22222222-2222-4222-8222-222222222222'

create or replace function pg_temp.try_insert(bucket text, nm text) returns text language plpgsql as $$
begin
  insert into stubstorage.objects(bucket_id, name) values (bucket, nm);
  return 'allowed';
exception when others then return 'refused';
end $$;

set role authenticated;
select set_config('request.jwt.claim.sub', :'U', false);
select 'good scan file name'              as test, pg_temp.try_insert('worldmaps', :'U' || '/' || :'B' || '/seg_ab12.arworldmap') as got, 'allowed' as expect;
select 'someone else''s folder'           as test, pg_temp.try_insert('worldmaps', '99999999-9999-4999-8999-999999999999/' || :'B' || '/seg1.arworldmap') as got, 'refused' as expect;
select 'wrong extension'                  as test, pg_temp.try_insert('worldmaps', :'U' || '/' || :'B' || '/seg1.exe') as got, 'refused' as expect;
select 'extra path part'                  as test, pg_temp.try_insert('worldmaps', :'U' || '/' || :'B' || '/seg1.arworldmap/x') as got, 'refused' as expect;
select 'not a uuid building'              as test, pg_temp.try_insert('worldmaps', :'U' || '/notauuid/seg1.arworldmap') as got, 'refused' as expect;
select 'segment with a dot'               as test, pg_temp.try_insert('worldmaps', :'U' || '/' || :'B' || '/a.b.arworldmap') as got, 'refused' as expect;
select 'meshes bucket (unchanged shape)'  as test, pg_temp.try_insert('meshes', :'U' || '/' || :'B' || '/model.obj') as got, 'allowed' as expect;
-- file cap: 300 per account (3 already inserted above: 2 allowed + ... count them via the cap itself)
do $$ declare i int; r text; ok int := 0; begin
  for i in 1..320 loop
    r := pg_temp.try_insert('worldmaps', current_setting('request.jwt.claim.sub') || '/22222222-2222-4222-8222-222222222222/s' || i || '.arworldmap');
    if r = 'allowed' then ok := ok + 1; end if;
  end loop;
  raise notice 'extra uploads allowed before the cap: % (cap total 300, 2 already stored => expect 298)', ok;
end $$;
select 'files stored by this account (must be exactly 300)' as test, count(*)::text as got, '300' as expect from stubstorage.objects;
reset role;

-- buildings: 25 per account, and NO global cap (security review: a global cap would let a few throw-away accounts lock everyone out)
set role authenticated;
do $$ declare i int; ok int := 0; begin
  for i in 1..30 loop
    begin insert into public.canonical_buildings(owner) values ('11111111-1111-4111-8111-111111111111'); ok := ok + 1;
    exception when others then null; end;
  end loop;
  raise notice 'buildings one account could create: % (expect 25)', ok;
end $$;
reset role;
-- 40 other accounts x 25 buildings = 1000 more: all must be accepted (no global cap)
insert into public.canonical_buildings(owner) select ('00000000-0000-4000-8000-' || lpad(g::text, 12, '0'))::uuid from generate_series(1, 40) g, generate_series(1, 25);
select 'total buildings with no global cap (must be 1025)' as test, count(*)::text as got, '1025' as expect from public.canonical_buildings;
