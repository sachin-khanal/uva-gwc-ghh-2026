-- File:    supabase/migrations/0006_abuse_limits.sql
-- Owner:   U3 (backend) / U1. Added 2026-10-18 by Claude from the security audit (docs/SECURITY.md, finding S-1).
-- Why:     The app's anon key is PUBLIC by design (it ships inside the app) and Anonymous Sign-Ins is on, so anyone on the internet can create
--          throw-away accounts. Before this migration each such account could (a) upload files with ANY name and ANY number of them into its
--          own storage folder (50 MB each: fill the 1 GB free tier, or host arbitrary files that 0004 might then expose), and (b) create an
--          unlimited number of shared buildings. This migration adds hard per-account and global caps. It does not stop a determined attacker
--          (that needs captcha / rate limits in the Supabase dashboard, see docs/SECURITY.md) but it makes casual abuse and accidents cheap to bound.
-- Rules:   1. `worldmaps` uploads must be named exactly <your user id>/<building uuid>/<segment>.arworldmap (what the app sends).
--          2. At most 300 files per account across both buckets.
--          3. At most 25 buildings per account (insert-time trigger; extending an existing building is not limited here).
--          Both counts are taken under a per-account advisory lock, so two simultaneous requests cannot both slip under the cap (security review).
-- NO global cap, on purpose (security review): a hard total (e.g. 500 buildings) would let ~20 throw-away anonymous accounts fill it and lock EVERY
--          real user out. Total growth is bounded only by how fast accounts can be created, so captcha / rate limits on anonymous sign-ins and a
--          size alert (query in docs/SECURITY.md) are REQUIRED companions of this migration.
-- Safe to re-run. Test: supabase/tests/abuse_limits.sql (local Postgres, stand-in tables).
begin;

-- Serialized per account: the lock is held until the end of the uploading transaction, so a second concurrent upload waits, then counts
-- the first one. SECURITY DEFINER so the count is not hidden by row level security.
create or replace function public.storage_quota_ok() returns boolean
language plpgsql security definer set search_path = '' as $$
declare n int;
begin
  perform pg_advisory_xact_lock(hashtextextended('wp-storage-' || coalesce(auth.uid()::text, ''), 0));
  select count(*) into n from storage.objects o
   where o.bucket_id in ('worldmaps', 'meshes') and split_part(o.name, '/', 1) = auth.uid()::text;
  return n < 300;
end $$;
revoke all on function public.storage_quota_ok() from public, anon;
grant execute on function public.storage_quota_ok() to authenticated;

drop policy if exists "waypoint_files_insert" on storage.objects;
create policy "waypoint_files_insert" on storage.objects
  for insert to authenticated
  with check (
    split_part(objects.name, '/', 1) = auth.uid()::text
    and (
      (bucket_id = 'worldmaps'
        and objects.name ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/[A-Za-z0-9_-]{1,64}\.arworldmap$')
      or bucket_id = 'meshes'
    )
    and public.storage_quota_ok()
  );

-- updates (the app uploads with x-upsert) must keep the same shape, so a file cannot be renamed into something else
drop policy if exists "waypoint_files_update" on storage.objects;
create policy "waypoint_files_update" on storage.objects
  for update to authenticated
  using (bucket_id in ('worldmaps', 'meshes') and split_part(objects.name, '/', 1) = auth.uid()::text)
  with check (
    split_part(objects.name, '/', 1) = auth.uid()::text
    and (
      (bucket_id = 'worldmaps'
        and objects.name ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/[A-Za-z0-9_-]{1,64}\.arworldmap$')
      or bucket_id = 'meshes'
    )
  );

create or replace function public.limit_buildings() returns trigger
language plpgsql set search_path = '' as $$
begin
  perform pg_advisory_xact_lock(hashtextextended('wp-buildings-' || new.owner::text, 0));
  if (select count(*) from public.canonical_buildings where owner = new.owner) >= 25 then
    raise exception 'Too many buildings for this account (limit 25)' using errcode = '53400';
  end if;
  return new;
end $$;

drop trigger if exists canonical_limit_buildings on public.canonical_buildings;
create trigger canonical_limit_buildings before insert on public.canonical_buildings
  for each row execute function public.limit_buildings();

commit;
