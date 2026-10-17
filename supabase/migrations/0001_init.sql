-- File:    supabase/migrations/0001_init.sql
-- Purpose: Database + storage schema for Waypoint, with Row Level Security (RLS).
-- Run:     Supabase dashboard -> SQL Editor -> paste this whole file -> Run.  (Safe to re-run.)
-- BEFORE:  Authentication -> Providers -> enable "Anonymous Sign-Ins". The app signs in anonymously;
--          there is no signup screen.
-- Security model (decisions D-014 / D-015): the app ships with the PUBLIC anon key, so RLS is the ONLY
--          authorization. Every table has RLS enabled; there is no policy that lets anonymous
--          (not-signed-in) callers do anything. NEVER put the service_role key in the app or repo.
-- Mirrors: Package/WaypointCore/Sources/WaypointCore/Cloud/CloudModels.swift (BuildingRow).
--          If you change columns here, change BuildingRow's CodingKeys and note it in docs/WORKLOG.md.
-- Free-tier notes (verify in dashboard): ~500 MB database, 1 GB storage, 50 MB per file, project pauses
--          after ~1 week of inactivity - open the dashboard and "Restore" before the demo.

-- ---------------------------------------------------------------------------------------------
-- buildings: one row per (owner, map). Every contributor keeps their OWN row for the same logical map
-- (map_id); clients merge rows locally. Nobody can edit someone else's row.
-- ---------------------------------------------------------------------------------------------
create table if not exists public.buildings (
  id          uuid primary key default gen_random_uuid(),
  map_id      uuid not null,
  owner       uuid not null default auth.uid() references auth.users(id) on delete cascade,
  name        text not null check (char_length(name) between 1 and 200),
  version     integer not null default 1 check (version >= 1),
  map_json    jsonb not null,
  is_shared   boolean not null default false,
  updated_at  timestamptz not null default now(),
  unique (owner, map_id),
  -- Cheap server-side size guard against abuse of the free tier (the client validates too).
  check (pg_column_size(map_json) < 2000000)
);

create index if not exists buildings_shared_idx on public.buildings (is_shared) where is_shared;
create index if not exists buildings_map_idx on public.buildings (map_id);

-- Keep updated_at honest on every update.
create or replace function public.touch_updated_at() returns trigger
language plpgsql as $$
begin
  new.updated_at = now();
  return new;
end $$;

drop trigger if exists buildings_touch on public.buildings;
create trigger buildings_touch before update on public.buildings
  for each row execute function public.touch_updated_at();

alter table public.buildings enable row level security;

drop policy if exists "buildings_select" on public.buildings;
create policy "buildings_select" on public.buildings
  for select to authenticated
  using (owner = auth.uid() or is_shared);

drop policy if exists "buildings_insert" on public.buildings;
create policy "buildings_insert" on public.buildings
  for insert to authenticated
  with check (owner = auth.uid());

drop policy if exists "buildings_update" on public.buildings;
create policy "buildings_update" on public.buildings
  for update to authenticated
  using (owner = auth.uid()) with check (owner = auth.uid());

drop policy if exists "buildings_delete" on public.buildings;
create policy "buildings_delete" on public.buildings
  for delete to authenticated
  using (owner = auth.uid());

-- ---------------------------------------------------------------------------------------------
-- scans: metadata for exported 3D models (USDZ) stored in the `meshes` bucket. (Used by the upcoming
-- mesh export feature; created now so the schema is stable.)
-- ---------------------------------------------------------------------------------------------
create table if not exists public.scans (
  id              uuid primary key default gen_random_uuid(),
  map_id          uuid not null,
  owner           uuid not null default auth.uid() references auth.users(id) on delete cascade,
  storage_path    text not null,
  bytes           bigint not null check (bytes between 1 and 50000000),
  triangle_count  integer,
  bbox            jsonb,
  created_at      timestamptz not null default now()
);

create index if not exists scans_map_idx on public.scans (map_id);

alter table public.scans enable row level security;

-- A scan is visible to its owner, and to everyone if the owner shared that map.
drop policy if exists "scans_select" on public.scans;
create policy "scans_select" on public.scans
  for select to authenticated
  using (
    owner = auth.uid()
    or exists (select 1 from public.buildings b
               where b.owner = scans.owner and b.map_id = scans.map_id and b.is_shared)
  );

drop policy if exists "scans_insert" on public.scans;
create policy "scans_insert" on public.scans
  for insert to authenticated with check (owner = auth.uid());

drop policy if exists "scans_delete" on public.scans;
create policy "scans_delete" on public.scans
  for delete to authenticated using (owner = auth.uid());

-- ---------------------------------------------------------------------------------------------
-- Storage buckets (private) and policies.
-- Path convention:  <owner uuid>/<map uuid>/<file>     e.g. 1111.../5a3e.../seg1.arworldmap
--   worldmaps : ARWorldMap binaries         meshes : exported USDZ models
-- ---------------------------------------------------------------------------------------------
insert into storage.buckets (id, name, public, file_size_limit)
values ('worldmaps', 'worldmaps', false, 50000000),
       ('meshes',    'meshes',    false, 50000000)
on conflict (id) do update set public = false, file_size_limit = excluded.file_size_limit;

-- Owners may write only inside their own top-level folder.
drop policy if exists "waypoint_files_insert" on storage.objects;
create policy "waypoint_files_insert" on storage.objects
  for insert to authenticated
  with check (bucket_id in ('worldmaps', 'meshes') and (storage.foldername(name))[1] = auth.uid()::text);

drop policy if exists "waypoint_files_update" on storage.objects;
create policy "waypoint_files_update" on storage.objects
  for update to authenticated
  using (bucket_id in ('worldmaps', 'meshes') and (storage.foldername(name))[1] = auth.uid()::text)
  with check (bucket_id in ('worldmaps', 'meshes') and (storage.foldername(name))[1] = auth.uid()::text);

drop policy if exists "waypoint_files_delete" on storage.objects;
create policy "waypoint_files_delete" on storage.objects
  for delete to authenticated
  using (bucket_id in ('worldmaps', 'meshes') and (storage.foldername(name))[1] = auth.uid()::text);

-- Read: your own files, or files of a map whose owner marked it shared.
drop policy if exists "waypoint_files_select" on storage.objects;
create policy "waypoint_files_select" on storage.objects
  for select to authenticated
  using (
    bucket_id in ('worldmaps', 'meshes')
    and (
      (storage.foldername(name))[1] = auth.uid()::text
      or exists (
        select 1 from public.buildings b
        where b.owner::text = (storage.foldername(name))[1]
          and b.map_id::text = (storage.foldername(name))[2]
          and b.is_shared
      )
    )
  );
