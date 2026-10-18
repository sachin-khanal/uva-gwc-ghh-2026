-- File:    supabase/migrations/0009_narration_limits.sql
-- Owner:   B (Guidance) with D (backend)
-- Purpose: Daily call budget for the `narrate` Edge Function (the server-side Gemini proxy, docs/DECISIONS.md D-047). The function holds the
--          Gemini key; this table makes sure one user - or a leaked anonymous session - cannot burn the free-tier quota for everybody.
-- Design:  * `narration_usage(day, user_id, calls)`: one row per user per UTC day. RLS on, NO policies: only the service role (the function)
--            can touch it; the app never reads or writes it.
--          * `narration_take(user, user_cap, global_cap)` atomically counts one call and returns false when either cap is reached.
--            The per-user cap is exact (single upsert). The global cap is a soft cap: two simultaneous calls can both pass the last slot.
--          * Anonymous sign-in makes new users cheap, so the GLOBAL cap is the real protection; the per-user cap stops casual abuse.
-- Not applied by hand: use the Supabase MCP / SQL editor. Rows are tiny (one per user per day); delete old days whenever convenient.
create table if not exists public.narration_usage (
  day     date not null,
  user_id uuid not null,
  calls   integer not null default 0 check (calls >= 0),
  primary key (day, user_id)
);

alter table public.narration_usage enable row level security;
revoke all on public.narration_usage from anon, authenticated;

create or replace function public.narration_take(p_user uuid, p_user_cap integer, p_global_cap integer)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  v_day    date := (now() at time zone 'utc')::date;
  v_global bigint;
  v_calls  integer;
begin
  if p_user is null or p_user_cap < 1 or p_global_cap < 1 then
    return false;
  end if;
  select coalesce(sum(calls), 0) into v_global from public.narration_usage where day = v_day;
  if v_global >= p_global_cap then
    return false;
  end if;
  insert into public.narration_usage as u (day, user_id, calls)
  values (v_day, p_user, 1)
  on conflict (day, user_id) do update set calls = u.calls + 1
  where u.calls < p_user_cap
  returning u.calls into v_calls;
  return v_calls is not null;   -- null = the conflict branch's WHERE failed = this user is at their cap
end;
$$;

revoke all on function public.narration_take(uuid, integer, integer) from public, anon, authenticated;
grant execute on function public.narration_take(uuid, integer, integer) to service_role;
