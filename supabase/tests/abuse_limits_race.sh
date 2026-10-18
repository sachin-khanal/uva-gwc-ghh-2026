#!/bin/sh
# File:   supabase/tests/abuse_limits_race.sh
# Purpose: proves the per-account caps of migration 0006 hold under CONCURRENT requests (two database sessions at once), and, with
#          `--without-locks`, that this test really detects the race (it must then report 2 inserts instead of 1).
# Needs:  Docker. Usage: sh supabase/tests/abuse_limits_race.sh [--without-locks]
set -u
cd "$(dirname "$0")/../.."
MIG=supabase/migrations/0006_abuse_limits.sql
TMP=$(mktemp -d)
sed 's/storage\.objects/stubstorage.objects/g' "$MIG" > "$TMP/0006.sql"
[ "${1:-}" = "--without-locks" ] && sed -i.bak '/pg_advisory_xact_lock/d' "$TMP/0006.sql"
docker rm -f wp-race >/dev/null 2>&1
docker run -d --name wp-race -e POSTGRES_PASSWORD=pw public.ecr.aws/supabase/postgres:17.6.1.136 >/dev/null
for i in $(seq 1 40); do docker exec wp-race pg_isready -U postgres >/dev/null 2>&1 && break; sleep 2; done
cat > "$TMP/setup.sql" <<'SQL'
create schema stubstorage;
create table stubstorage.objects (id uuid default gen_random_uuid(), bucket_id text, name text, owner uuid);
alter table stubstorage.objects enable row level security;
grant usage on schema stubstorage to authenticated; grant select, insert on stubstorage.objects to authenticated;
create policy readall on stubstorage.objects for select to authenticated using (true);
create table public.canonical_buildings (map_id uuid default gen_random_uuid(), owner uuid not null, name text default 'x');
grant select, insert on public.canonical_buildings to authenticated;
\i /tmp/0006.sql
-- account U already holds 299 files and 24 buildings: ONE more of each is allowed, not two
insert into stubstorage.objects(bucket_id, name)
  select 'worldmaps', '11111111-1111-4111-8111-111111111111/22222222-2222-4222-8222-222222222222/s' || g || '.arworldmap' from generate_series(1, 299) g;
insert into public.canonical_buildings(owner) select '11111111-1111-4111-8111-111111111111' from generate_series(1, 24);
SQL
for who in A B; do
cat > "$TMP/$who.sql" <<SQL
\set ON_ERROR_STOP off
set role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-4111-8111-111111111111', false);
begin;
insert into stubstorage.objects(bucket_id, name) values ('worldmaps', '11111111-1111-4111-8111-111111111111/22222222-2222-4222-8222-222222222222/race$who.arworldmap');
insert into public.canonical_buildings(owner) values ('11111111-1111-4111-8111-111111111111');
select pg_sleep(2);
commit;
SQL
done
docker cp "$TMP/0006.sql" wp-race:/tmp/0006.sql; docker cp "$TMP/setup.sql" wp-race:/tmp/setup.sql; docker cp "$TMP/A.sql" wp-race:/tmp/A.sql; docker cp "$TMP/B.sql" wp-race:/tmp/B.sql
docker exec wp-race psql -q -U supabase_admin -d postgres -f /tmp/setup.sql >/dev/null 2>&1
docker exec wp-race psql -q -U supabase_admin -d postgres -f /tmp/A.sql >/dev/null 2>&1 &
sleep 0.7
docker exec wp-race psql -q -U supabase_admin -d postgres -f /tmp/B.sql >/dev/null 2>&1 &
wait
files=$(docker exec wp-race psql -At -U supabase_admin -d postgres -c "select count(*) from stubstorage.objects")
blds=$(docker exec wp-race psql -At -U supabase_admin -d postgres -c "select count(*) from public.canonical_buildings")
echo "files after two simultaneous uploads from one account holding 299: $files  (cap 300 -> must be 300)"
echo "buildings after two simultaneous inserts from one account holding 24: $blds  (cap 25 -> must be 25)"
docker rm -f wp-race >/dev/null 2>&1
if [ "$files" = "300" ] && [ "$blds" = "25" ]; then echo "RACE TEST: caps held"; else echo "RACE TEST: CAPS EXCEEDED (race)"; exit 1; fi
