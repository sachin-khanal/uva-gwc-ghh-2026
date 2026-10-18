-- File:    supabase/migrations/0004_storage_read_policy.sql
-- Owner:   U3 (backend). Added 2026-10-17 by Claude after a LIVE two-user test.
-- Why:     The live test showed a second user could read the shared map but got "Object not found" for every scan file (ARWorldMap) of
--          the first user, and the first user could not read the second user's file. So the storage read rule from 0002
--          (`canonical_worldmaps_read`) was not taking effect on the live project. Possible causes: it was never created there, or it
--          depends on `storage.foldername()` / `storage.filename()` behaving as assumed (0002's SQL test ran only against STUBBED
--          storage functions). This migration re-creates the rule using plain string functions only. Safe to re-run.
--
-- ROOT CAUSE (found 2026-10-17, reproduced in a local Postgres, see supabase/tests/storage_read_policy.sql): inside the
-- `exists (select ... from public.canonical_buildings c ...)` subquery a BARE `name` means c.name, the BUILDING's name, not the
-- file's path. The original rule in 0002 (`storage.foldername(name)`) and the first version of this file both compared the wrong
-- thing, so no signed-in user could ever read someone else's scan file. The fix is to say `objects.name` (the storage object).
-- Re-run this file even if you ran an earlier version of it: it drops and re-creates the rule.
--
-- BEFORE running, optionally look at what is there (SQL editor):
--     select policyname, cmd, roles from pg_policies where schemaname = 'storage' and tablename = 'objects' order by policyname;
-- The list should contain: canonical_worldmaps_read (select), waypoint_files_insert/update/delete/select.
--
-- Path convention (unchanged):  <contributor uuid>/<building uuid>/<segment>.arworldmap   in bucket `worldmaps`
-- Rule: any signed-in user (anonymous sign-ins have role `authenticated`) may READ a scan file if the shared building's
--       `segment_owners` says that segment was contributed by the folder's user (exact full-path match, see below). Writing stays restricted to your own folder.
begin;

-- EXACT match (security review 2026-10-18): a file is readable only if its full path is exactly
--   <contributor>/<building>/<segment>.arworldmap   for a (segment, contributor) pair listed in the building's `segment_owners`.
-- Extra suffixes (`seg1.evil`), extra path parts (`seg1.arworldmap/x`) and unlisted segments are NOT readable, so a contributor cannot use
-- their own folder to host arbitrary files for everyone.
drop policy if exists canonical_worldmaps_read on storage.objects;
create policy canonical_worldmaps_read on storage.objects for select to authenticated using (
  bucket_id = 'worldmaps'
  and exists (
    select 1
    from public.canonical_buildings c, jsonb_each_text(c.segment_owners) as s(seg, owner_id)
    where objects.name = s.owner_id || '/' || c.map_id::text || '/' || s.seg || '.arworldmap'
  )
);

commit;

-- AFTER running, from any terminal on the repo:   python3 tools/supabase_check.py
-- It must print "PASS storage.otherUserCanDownloadScanFiles".
