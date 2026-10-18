-- File: supabase/migrations/0005_mesh_read_policy.sql
-- Owner: D / U3. Apply after 0004_rich_map_schema.sql.
-- Qualify the object path: bare name inside the subquery binds to c.name.
begin;
drop policy if exists canonical_mesh_read on storage.objects;
create policy canonical_mesh_read on storage.objects for select to authenticated using (
  bucket_id = 'meshes' and exists (
    select 1 from public.canonical_buildings c,
      lateral jsonb_array_elements(case when jsonb_typeof(c.map_json->'meshAssets') = 'array'
        then c.map_json->'meshAssets' else '[]'::jsonb end) a
    where c.map_id::text = (storage.foldername(objects.name))[2]
      and a->>'storageOwner' = (storage.foldername(objects.name))[1]
      and lower(a->>'id') || '.obj' = storage.filename(objects.name)
  )
);
commit;
