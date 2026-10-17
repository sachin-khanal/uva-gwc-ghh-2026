-- File: supabase/migrations/0003_extension_connections.sql
-- Owner: D / U3
-- Purpose: Match MapStore import rules: no new shortcuts joining two existing nodes.
-- Run AFTER 0002. Keep already-applied migrations unchanged.
begin;
do $$
begin
  if to_regprocedure('public.merge_building_internal(jsonb)') is null then
    alter function public.extend_building(jsonb) rename to merge_building_internal;
  end if;
end $$;
-- Only the checked wrapper may call the implementation (including through REST).
revoke all on function public.merge_building_internal(jsonb) from public, anon, authenticated;

create or replace function public.extend_building(incoming jsonb)
returns void language plpgsql security definer set search_path = '' as $$
declare
  building uuid := (incoming->>'id')::uuid;
  previous jsonb;
  item jsonb;
begin
  if auth.uid() is null then raise exception 'Sign in first'; end if;
  if building is null then raise exception 'Missing building id'; end if;
  perform pg_advisory_xact_lock(hashtextextended(building::text, 0));
  select map_json into previous from public.canonical_buildings where map_id = building for update;
  if previous is not null then
    -- Compare against the graph BEFORE this extension, not its newly added nodes.
    for item in select value from jsonb_array_elements(incoming->'edges') loop
      if exists (select 1 from jsonb_array_elements(previous->'nodes') n
                 where (n->>'id')::uuid = (item->>'from')::uuid)
         and exists (select 1 from jsonb_array_elements(previous->'nodes') n
                     where (n->>'id')::uuid = (item->>'to')::uuid)
         and not exists (
           select 1 from jsonb_array_elements(previous->'edges') e
           where ((e->>'from')::uuid = (item->>'from')::uuid and (e->>'to')::uuid = (item->>'to')::uuid)
              or ((e->>'from')::uuid = (item->>'to')::uuid and (e->>'to')::uuid = (item->>'from')::uuid)
         ) then
        raise exception 'Incoming map adds a new connection between existing places; refusing to merge.';
      end if;
    end loop;
  end if;
  perform public.merge_building_internal(incoming);
end $$;
revoke all on function public.extend_building(jsonb) from public, anon;
grant execute on function public.extend_building(jsonb) to authenticated;
commit;
