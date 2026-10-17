-- File:    supabase/migrations/0004_storage_read_policy.sql
-- Owner:   U3 (backend). Added 2026-10-17 by Claude after a LIVE two-user test.
-- Why:     The live test showed a second user could read the shared map but got "Object not found" for every scan file (ARWorldMap) of
--          the first user, and the first user could not read the second user's file. So the storage read rule from 0002
--          (`canonical_worldmaps_read`) was not taking effect on the live project. Possible causes: it was never created there, or it
--          depends on `storage.foldername()` / `storage.filename()` behaving as assumed (0002's SQL test ran only against STUBBED
--          storage functions). This migration re-creates the rule using plain string functions only. Safe to re-run.
--
-- BEFORE running, optionally look at what is there (SQL editor):
--     select policyname, cmd, roles from pg_policies where schemaname = 'storage' and tablename = 'objects' order by policyname;
-- The list should contain: canonical_worldmaps_read (select), waypoint_files_insert/update/delete/select.
--
-- Path convention (unchanged):  <contributor uuid>/<building uuid>/<segment>.arworldmap   in bucket `worldmaps`
-- Rule: any signed-in user (anonymous sign-ins have role `authenticated`) may READ a scan file if the shared building's
--       `segment_owners` says that segment was contributed by the folder's user. Writing stays restricted to your own folder.
begin;

drop policy if exists canonical_worldmaps_read on storage.objects;
create policy canonical_worldmaps_read on storage.objects for select to authenticated using (
  bucket_id = 'worldmaps'
  and exists (
    select 1 from public.canonical_buildings c
    where c.map_id::text = split_part(name, '/', 2)
      and c.segment_owners ->> split_part(split_part(name, '/', 3), '.', 1) = split_part(name, '/', 1)
  )
);

commit;

-- AFTER running, from any terminal on the repo:   python3 tools/supabase_check.py
-- It must print "PASS storage.otherUserCanDownloadScanFiles".
