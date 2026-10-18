-- File:    supabase/migrations/0006_abuse_limits.sql
-- Owner:   U3 (backend) / U1. Added 2026-10-18 by Claude from the security audit (docs/SECURITY.md, finding S-1).
-- Why:     The app's anon key is PUBLIC by design (it ships inside the app) and Anonymous Sign-Ins is on, so anyone on the internet can create
--          throw-away accounts. Before this migration each such account could (a) upload files with ANY name and ANY number of them into its
--          own storage folder (50 MB each: fill the 1 GB free tier, or host arbitrary files that 0004 might then expose), and (b) create an
--          unlimited number of shared buildings. This migration adds hard per-account and global caps. It does not stop a determined attacker
--          (that needs captcha / rate limits in the Supabase dashboard, see docs/SECURITY.md) but it makes casual abuse and accidents cheap to bound.
-- Rules:   1. `worldmaps` uploads must be named exactly <your user id>/<building uuid>/<segment>.arworldmap (what the app sends).
--          2. At most 300 files per account across both buckets.
--          3. At most 25 buildings per account and 500 in total (insert-time trigger; extending an existing building is not limited here).
-- Safe to re-run. Test: supabase/tests/abuse_limits.sql (local Postgres, stand-in tables).
begin;

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
    and (select count(*) from storage.objects o
         where o.bucket_id in ('worldmaps', 'meshes') and split_part(o.name, '/', 1) = auth.uid()::text) < 300
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
  if (select count(*) from public.canonical_buildings where owner = new.owner) >= 25 then
    raise exception 'Too many buildings for this account (limit 25)' using errcode = '53400';
  end if;
  if (select count(*) from public.canonical_buildings) >= 500 then
    raise exception 'The shared library is full (limit 500 buildings)' using errcode = '53400';
  end if;
  return new;
end $$;

drop trigger if exists canonical_limit_buildings on public.canonical_buildings;
create trigger canonical_limit_buildings before insert on public.canonical_buildings
  for each row execute function public.limit_buildings();

commit;
