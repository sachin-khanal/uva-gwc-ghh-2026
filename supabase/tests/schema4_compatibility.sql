-- Owner: U3 / D. Read-only compatibility probe for maps produced by U3's schema-4 app.
-- KNOWN FAILURE on the current deployment (2026-10-18): Unsupported schemaVersion.
-- The viewer accepts schema 4; native schema 4 must not be released until this passes.
begin;
do $$
begin
  perform public.waypoint_validate_geometry('{"schemaVersion":4,"id":"20000000-0000-4000-8000-000000000006","name":"Schema 4 compatibility probe","version":1,"nodes":[{"id":"30000000-0000-4000-8000-000000000006","kind":"stairs","position":[0,0,0],"segmentId":"test","createdBy":"qa","stairs":{"direction":"both","railings":"both","stepCount":12}}],"edges":[]}'::jsonb);
end $$;
rollback;
