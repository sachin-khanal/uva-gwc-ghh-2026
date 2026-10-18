-- File:    supabase/migrations/0005_map_extras_constraint.sql
-- Owner:   U3 (backend) / U1 (contract). Added 2026-10-18 by Claude after an automated security review.
-- Why:     Format-3 maps may carry optional room floor areas (`nodes[].extent`) and 3D surface lists (`meshAssets`). The app's
--          `RouteFollower` says "You have arrived" inside a room's floor area, so a hostile or corrupt extent in a SHARED map could make
--          every downloader hear it in the wrong place; meshAssets name files other tools download. The app validates these on import
--          (`MapBundle.validate()`); this migration makes the DATABASE refuse bad ones too, whatever client sent them (including the
--          first publication, which stores the incoming JSON as is).
-- Rules:   the same as Swift `Model/MapExtrasValidation.swift`, `tools/validate_map.py` and `web/router.js`. Keep all in step.
-- How:     a CHECK constraint on canonical_buildings.map_json; `extend_building` is not touched (it fails with check_violation, SQLSTATE 23514,
--          when a map breaks a rule). Safe to re-run. Existing rows without extras always pass.
begin;

create or replace function public.map_extras_valid(m jsonb) returns boolean
language plpgsql immutable set search_path = '' as $$
-- NULL-SAFE by construction: every rule is written as a POSITIVE condition wrapped in coalesce(..., false), so a missing key (NULL)
-- REJECTS instead of slipping through (in plpgsql `if NULL then` does not fire; found by security review 2026-10-18).
declare
  n jsonb; e jsonb; a jsonb;
  hx double precision; hz double precision; area double precision; h double precision;
  cx double precision; cz double precision; px double precision; pz double precision;
  total bigint := 0; bytes bigint; seen text[] := '{}'; segs text[];
  lo jsonb; hi jsonb; i int;
begin
  if jsonb_typeof(m->'nodes') is distinct from 'array' then return true; end if; -- the base rules (extend_building) cover the rest
  for n in select value from jsonb_array_elements(m->'nodes') loop
    e := n->'extent';
    if e is null or jsonb_typeof(e) = 'null' then continue; end if;
    if not coalesce(n->>'kind' = 'room' and jsonb_typeof(e) = 'object', false) then return false; end if;
    if not coalesce(jsonb_typeof(e->'center') = 'array' and jsonb_array_length(e->'center') = 3
                    and jsonb_typeof(e->'halfExtents') = 'array' and jsonb_array_length(e->'halfExtents') = 2
                    and jsonb_typeof(e->'yaw') = 'number' and jsonb_typeof(e->'areaSquareMeters') = 'number'
                    and jsonb_typeof(n->'position') = 'array' and jsonb_array_length(n->'position') = 3, false) then
      return false;
    end if;
    for a in select value from jsonb_array_elements(e->'center') union all select value from jsonb_array_elements(e->'halfExtents')
             union all select value from jsonb_array_elements(n->'position') loop
      if not coalesce(jsonb_typeof(a) = 'number', false) then return false; end if;
    end loop;
    hx := (e->'halfExtents'->>0)::double precision; hz := (e->'halfExtents'->>1)::double precision;
    area := (e->>'areaSquareMeters')::double precision;
    if not coalesce(hx > 0.05 and hz > 0.05 and hx <= 30 and hz <= 30, false) then return false; end if;
    if not coalesce(area > 0 and area <= 4 * hx * hz + 0.01, false) then return false; end if;
    if e ? 'heightMeters' and jsonb_typeof(e->'heightMeters') <> 'null' then
      if not coalesce(jsonb_typeof(e->'heightMeters') = 'number', false) then return false; end if;
      h := (e->>'heightMeters')::double precision;
      if not coalesce(h > 0 and h <= 20, false) then return false; end if;
    end if;
    cx := (e->'center'->>0)::double precision; cz := (e->'center'->>2)::double precision;
    px := (n->'position'->>0)::double precision; pz := (n->'position'->>2)::double precision;
    if not coalesce(sqrt(power(cx - px, 2) + power(cz - pz, 2)) <= sqrt(hx * hx + hz * hz) + 1, false) then return false; end if;
  end loop;

  if m ? 'meshAssets' and jsonb_typeof(m->'meshAssets') <> 'null' then
    if not coalesce(jsonb_typeof(m->'meshAssets') = 'array' and jsonb_array_length(m->'meshAssets') <= 100, false) then return false; end if;
    select coalesce(array_agg(distinct value->>'segmentId'), '{}') into segs from jsonb_array_elements(m->'nodes');
    for a in select value from jsonb_array_elements(m->'meshAssets') loop
      if not coalesce(
           jsonb_typeof(a) = 'object'
           and a->>'id' ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
           and not (lower(a->>'id') = any(seen))
           and a->>'segmentId' ~ '^[A-Za-z0-9_-]{1,64}$' and (a->>'segmentId') = any(segs)
           and a->>'format' = 'obj' and a->>'coordinateFrame' = 'map'
           and jsonb_typeof(a->'byteCount') = 'number' and a->>'byteCount' ~ '^[0-9]{1,9}$'
           and a->>'sha256' ~ '^[a-f0-9]{64}$'
           and jsonb_typeof(a->'boundsMin') = 'array' and jsonb_array_length(a->'boundsMin') = 3
           and jsonb_typeof(a->'boundsMax') = 'array' and jsonb_array_length(a->'boundsMax') = 3
           and (not (a ? 'storageOwner') or jsonb_typeof(a->'storageOwner') = 'null'
                or a->>'storageOwner' ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'), false) then
        return false;
      end if;
      bytes := (a->>'byteCount')::bigint;
      if not coalesce(bytes >= 1 and bytes <= 40000000, false) then return false; end if;
      lo := a->'boundsMin'; hi := a->'boundsMax';
      for i in 0..2 loop
        if not coalesce(jsonb_typeof(lo->i) = 'number' and jsonb_typeof(hi->i) = 'number'
                        and (lo->>i)::double precision <= (hi->>i)::double precision, false) then return false; end if;
      end loop;
      seen := seen || lower(a->>'id');
      total := total + bytes;
    end loop;
    if total > 80000000 then return false; end if;
  end if;
  return true;
exception when others then
  return false; -- any cast/shape surprise means "not valid"
end $$;

alter table public.canonical_buildings drop constraint if exists canonical_map_extras_valid;
alter table public.canonical_buildings
  add constraint canonical_map_extras_valid check (public.map_extras_valid(map_json));

commit;
