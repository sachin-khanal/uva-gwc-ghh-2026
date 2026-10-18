-- Owner: B. Run in the SQL Editor AFTER 0009. All fixtures roll back.
begin;
do $$
declare
  u1 uuid := '90000000-0000-4000-8000-000000000001';
  u2 uuid := '90000000-0000-4000-8000-000000000002';
  ok boolean;
begin
  -- per-user cap: 3 calls allowed, the 4th refused, another user unaffected
  for i in 1..3 loop
    if not public.narration_take(u1, 3, 1000) then raise exception 'FAIL: call % should pass', i; end if;
  end loop;
  if public.narration_take(u1, 3, 1000) then raise exception 'FAIL: 4th call should hit the user cap'; end if;
  if (select calls from public.narration_usage where user_id = u1) <> 3 then raise exception 'FAIL: a refused call must not be counted'; end if;
  if not public.narration_take(u2, 3, 1000) then raise exception 'FAIL: another user must not be affected'; end if;
  -- global cap: u1 has 3 + u2 has 1 = 4 today; a global cap of 4 refuses everyone
  if public.narration_take(u2, 3, 4) then raise exception 'FAIL: global cap should refuse'; end if;
  -- bad input is refused, not an error
  if public.narration_take(null, 3, 4) or public.narration_take(u2, 0, 4) then raise exception 'FAIL: bad input must be refused'; end if;
  -- the app roles cannot call it
  begin
    set local role authenticated;
    ok := public.narration_take(u2, 3, 1000);
    reset role;
    raise exception 'FAIL: authenticated must not be able to call narration_take';
  exception when insufficient_privilege then
    reset role;
  end;
  begin
    set local role authenticated;
    perform 1 from public.narration_usage;
    reset role;
    raise exception 'FAIL: authenticated must not read narration_usage';
  exception when insufficient_privilege then
    reset role;
  end;
  raise notice 'PASS narration_limits';
end $$;
rollback;
