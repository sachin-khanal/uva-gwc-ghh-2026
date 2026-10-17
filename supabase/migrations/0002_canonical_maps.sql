-- File: supabase/migrations/0002_canonical_maps.sql
-- Owner: D / U3
-- Purpose: One shared canonical map per building UUID; atomic additive extensions.
-- Apply AFTER 0001 in the SQL editor. Existing contributor rows remain untouched.
-- Existing maps must be published again by an updated client to enter this library.
begin;

create table if not exists public.canonical_buildings (
  id uuid primary key default gen_random_uuid(),
  map_id uuid not null unique,
  owner uuid not null references auth.users(id),
  name text not null,
  version integer not null,
  map_json jsonb not null,
  is_shared boolean not null default true check (is_shared),
  segment_owners jsonb not null default '{}',
  updated_at timestamptz not null default now()
);
alter table public.canonical_buildings enable row level security;
revoke all on public.canonical_buildings from anon, authenticated;
grant select on public.canonical_buildings to authenticated;
drop policy if exists canonical_read on public.canonical_buildings;
create policy canonical_read on public.canonical_buildings
  for select to authenticated using (true);

create or replace function public.extend_building(incoming jsonb)
returns void language plpgsql security definer set search_path = '' as $$
declare
  actor uuid := auth.uid();
  building uuid := (incoming->>'id')::uuid;
  previous public.canonical_buildings%rowtype;
  combined jsonb;
  nodes jsonb;
  edges jsonb;
  owners jsonb;
  item jsonb;
  existing jsonb;
  seg text;
  revision integer;
  a jsonb;
  b jsonb;
  straight double precision;
begin
  if actor is null then raise exception 'Sign in first'; end if;
  if building is null or jsonb_typeof(incoming->'name') is distinct from 'string'
     or length(incoming->>'name') not between 1 and 200
     or jsonb_typeof(incoming->'nodes') is distinct from 'array'
     or jsonb_typeof(incoming->'edges') is distinct from 'array' then
    raise exception 'Invalid map';
  end if;
  -- Serialize both first publication and later extensions for this UUID.
  perform pg_advisory_xact_lock(hashtextextended(building::text, 0));
  select * into previous from public.canonical_buildings where map_id = building for update;
  nodes := coalesce(previous.map_json->'nodes', '[]'::jsonb);
  edges := coalesce(previous.map_json->'edges', '[]'::jsonb);
  owners := coalesce(previous.segment_owners, '{}'::jsonb);
  for item in select value from jsonb_array_elements(incoming->'nodes') loop
    if (item->>'id')::uuid is null
       or coalesce(item->>'segmentId', '') !~ '^[A-Za-z0-9_-]{1,64}$'
       or coalesce(item->>'kind', '') not in ('corridor','door','stairs','elevator','room','junction')
       or jsonb_typeof(item->'createdBy') is distinct from 'string'
       or jsonb_typeof(item->'position') is distinct from 'array'
       or jsonb_array_length(item->'position') <> 3 then
      raise exception 'Invalid node';
    end if;
    for a in select value from jsonb_array_elements(item->'position') loop
      if jsonb_typeof(a) <> 'number' or abs(a::text::double precision) > 3.4028234663852886e38 then
        raise exception 'Invalid position';
      end if;
    end loop;
    select value into existing from jsonb_array_elements(nodes)
      where (value->>'id')::uuid = (item->>'id')::uuid;
    if found then
      if existing <> item then raise exception 'An existing node cannot be changed'; end if;
      continue;
    end if;
    seg := item->>'segmentId';
    -- New scans need unique segment IDs; another contributor cannot replace a scan frame.
    if owners ? seg and owners->>seg <> actor::text then
      raise exception 'Use a new segment ID for your extension';
    end if;
    owners := owners || jsonb_build_object(seg, actor::text);
    nodes := nodes || jsonb_build_array(item);
  end loop;
  for item in select value from jsonb_array_elements(incoming->'edges') loop
    select value into a from jsonb_array_elements(nodes) where (value->>'id')::uuid = (item->>'from')::uuid;
    select value into b from jsonb_array_elements(nodes) where (value->>'id')::uuid = (item->>'to')::uuid;
    if a is null or b is null or (item->>'from')::uuid = (item->>'to')::uuid
       or jsonb_typeof(item->'distance') is distinct from 'number' then
      raise exception 'Invalid edge';
    end if;
    straight := sqrt(power((a->'position'->>0)::double precision - (b->'position'->>0)::double precision, 2)
                   + power((a->'position'->>1)::double precision - (b->'position'->>1)::double precision, 2)
                   + power((a->'position'->>2)::double precision - (b->'position'->>2)::double precision, 2));
    if abs((item->>'distance')::double precision - straight) > greatest(0.5, straight * 0.25) then
      raise exception 'Edge distance does not match positions';
    end if;
    select value into existing from jsonb_array_elements(edges)
      where ((value->>'from')::uuid = (item->>'from')::uuid and (value->>'to')::uuid = (item->>'to')::uuid)
         or ((value->>'from')::uuid = (item->>'to')::uuid and (value->>'to')::uuid = (item->>'from')::uuid);
    if found then
      if existing->'distance' <> item->'distance'
         or coalesce(existing->'hazard', 'null'::jsonb) <> coalesce(item->'hazard', 'null'::jsonb) then
        raise exception 'An existing edge cannot be changed';
      end if;
    else
      edges := edges || jsonb_build_array(item);
    end if;
  end loop;
  revision := coalesce(previous.version, 0) + 1;
  combined := coalesce(previous.map_json, incoming) || jsonb_build_object('nodes', nodes, 'edges', edges, 'version', revision);
  if jsonb_array_length(nodes) > 5000 or jsonb_array_length(edges) > 20000
     or pg_column_size(combined) >= 2000000 then raise exception 'Map too large'; end if;
  insert into public.canonical_buildings(map_id, owner, name, version, map_json, segment_owners)
    values(building, actor, combined->>'name', revision, combined, owners)
    on conflict (map_id) do update set version = excluded.version, map_json = excluded.map_json,
      segment_owners = excluded.segment_owners, updated_at = now();
end $$;
revoke all on function public.extend_building(jsonb) from public, anon;
grant execute on function public.extend_building(jsonb) to authenticated;

-- The canonical record tracks the original contributor for each scan segment.
drop policy if exists canonical_worldmaps_read on storage.objects;
create policy canonical_worldmaps_read on storage.objects for select to authenticated using (
  bucket_id = 'worldmaps' and exists (
    select 1 from public.canonical_buildings c
    where c.map_id::text = (storage.foldername(name))[2]
      and c.segment_owners->>split_part(storage.filename(name), '.', 1) = (storage.foldername(name))[1]
  )
);
commit;
