-- File:   supabase/tests/storage_read_policy.sql
-- Owner:  U3 / Claude (2026-10-17)
-- Purpose: proves the storage READ rule for shared scan files (supabase/migrations/0004) against a stand-in table, as an ordinary
--          signed-in user. Needed because 0002's tests never touched storage, and the original rule was silently wrong (bare `name`
--          inside the subquery resolved to the BUILDING's name).
-- Run:    NOT in the Supabase dashboard (it creates a throwaway schema). Locally:
--           docker run -d --name wp-pg -e POSTGRES_PASSWORD=pw public.ecr.aws/supabase/postgres:17.6.1.136
--           docker cp supabase/tests/storage_read_policy.sql wp-pg:/tmp/p.sql
--           docker exec wp-pg psql -U supabase_admin -d postgres -f /tmp/p.sql     (wait until pg_isready first)
--           docker rm -f wp-pg
-- Expect: BROKEN -> 0 readable objects, FIXED -> 1 (only the contributor's listed segment).
\set ON_ERROR_STOP on
create schema if not exists stubstorage;
create table stubstorage.objects (id uuid default gen_random_uuid(), bucket_id text, name text, owner uuid);
alter table stubstorage.objects enable row level security;
grant usage on schema stubstorage to authenticated; grant select on stubstorage.objects to authenticated;
create table public.canonical_buildings (map_id uuid unique, name text not null, segment_owners jsonb not null default '{}');
grant select on public.canonical_buildings to authenticated;
alter table public.canonical_buildings enable row level security;
create policy canonical_read on public.canonical_buildings for select to authenticated using (true);

insert into public.canonical_buildings values ('11111111-1111-4111-8111-111111111111', 'ZZ TEST', '{"seg1":"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"}');
insert into stubstorage.objects(bucket_id, name) values
  ('worldmaps', 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa/11111111-1111-4111-8111-111111111111/seg1.arworldmap'),
  ('worldmaps', 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa/11111111-1111-4111-8111-111111111111/seg9.arworldmap'),   -- segment not listed
  ('worldmaps', 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb/11111111-1111-4111-8111-111111111111/seg1.arworldmap'); -- wrong contributor

\echo === BROKEN (bare "name" inside the subquery)
create policy t on stubstorage.objects for select to authenticated using (
  bucket_id = 'worldmaps' and exists (select 1 from public.canonical_buildings c
    where c.map_id::text = split_part(name, '/', 2)
      and c.segment_owners ->> split_part(split_part(name, '/', 3), '.', 1) = split_part(name, '/', 1)));
set role authenticated;
select 'readable objects (BROKEN rule; shows 0)' as what, count(*) from stubstorage.objects;
reset role;
drop policy t on stubstorage.objects;

\echo === FIXED = migration 0004 (exact full-path match)
create policy t on stubstorage.objects for select to authenticated using (
  bucket_id = 'worldmaps'
  and exists (
    select 1
    from public.canonical_buildings c, jsonb_each_text(c.segment_owners) as s(seg, owner_id)
    where objects.name = s.owner_id || '/' || c.map_id::text || '/' || s.seg || '.arworldmap'
  ));
-- hostile / sloppy names that the first (split_part) version would have let through:
insert into stubstorage.objects(bucket_id, name) values
  ('worldmaps', 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa/11111111-1111-4111-8111-111111111111/seg1.evil'),
  ('worldmaps', 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa/11111111-1111-4111-8111-111111111111/seg1.arworldmap/extra'),
  ('worldmaps', 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa//11111111-1111-4111-8111-111111111111/seg1.arworldmap'),
  ('worldmaps', 'AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA/11111111-1111-4111-8111-111111111111/seg1.arworldmap'),
  ('meshes',    'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa/11111111-1111-4111-8111-111111111111/seg1.arworldmap');
set role authenticated;
select 'readable objects (FIXED rule; must be exactly 1)' as what, count(*) from stubstorage.objects;
select name as the_one_readable_file from stubstorage.objects;
reset role;
