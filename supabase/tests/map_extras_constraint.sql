-- File:   supabase/tests/map_extras_constraint.sql
-- Purpose: tests supabase/migrations/0005 (map_extras_valid + CHECK constraint) against a stand-in canonical_buildings table.
-- Run:    like storage_read_policy.sql: local Postgres in Docker (psql -U supabase_admin), NOT the dashboard (it creates a throwaway table).
--           docker exec wp-pg psql -U supabase_admin -d postgres -f /tmp/0005.sql -f /tmp/t.sql   (0005 first, then this file)
-- Expect: every line says ok = true.
\set ON_ERROR_STOP on
create table if not exists public.canonical_buildings (map_id uuid, map_json jsonb);
\i /tmp/0005.sql
create temp table cases(name text, expect boolean, m jsonb);
insert into cases values
 ('no extras', true, '{"nodes":[{"kind":"room","segmentId":"seg1","position":[3,0,0]}]}'),
 ('good extent', true, '{"nodes":[{"kind":"room","segmentId":"seg1","position":[3,0,0],"extent":{"center":[4,0,0],"halfExtents":[2,1.5],"yaw":0.3,"areaSquareMeters":10,"heightMeters":2.6}}]}'),
 ('extent on a door', false, '{"nodes":[{"kind":"door","segmentId":"seg1","position":[3,0,0],"extent":{"center":[4,0,0],"halfExtents":[2,1.5],"yaw":0,"areaSquareMeters":10}}]}'),
 ('huge room', false, '{"nodes":[{"kind":"room","segmentId":"seg1","position":[3,0,0],"extent":{"center":[4,0,0],"halfExtents":[500,500],"yaw":0,"areaSquareMeters":100}}]}'),
 ('zero area', false, '{"nodes":[{"kind":"room","segmentId":"seg1","position":[3,0,0],"extent":{"center":[4,0,0],"halfExtents":[2,2],"yaw":0,"areaSquareMeters":0}}]}'),
 ('area > rectangle', false, '{"nodes":[{"kind":"room","segmentId":"seg1","position":[3,0,0],"extent":{"center":[4,0,0],"halfExtents":[1,1],"yaw":0,"areaSquareMeters":50}}]}'),
 ('far from node', false, '{"nodes":[{"kind":"room","segmentId":"seg1","position":[3,0,0],"extent":{"center":[400,0,0],"halfExtents":[2,2],"yaw":0,"areaSquareMeters":8}}]}'),
 ('string number', false, '{"nodes":[{"kind":"room","segmentId":"seg1","position":[3,0,0],"extent":{"center":["4",0,0],"halfExtents":[2,2],"yaw":0,"areaSquareMeters":8}}]}'),
 ('bad height', false, '{"nodes":[{"kind":"room","segmentId":"seg1","position":[3,0,0],"extent":{"center":[4,0,0],"halfExtents":[2,2],"yaw":0,"areaSquareMeters":8,"heightMeters":-1}}]}'),
 ('good asset', true, '{"nodes":[{"kind":"room","segmentId":"seg1","position":[0,0,0]}],"meshAssets":[{"id":"aaaaaaaa-0000-4000-8000-000000000001","segmentId":"seg1","format":"obj","coordinateFrame":"map","byteCount":1000,"sha256":"abababababababababababababababababababababababababababababababab","boundsMin":[0,0,0],"boundsMax":[1,1,1]}]}'),
 ('asset unknown segment', false, '{"nodes":[{"kind":"room","segmentId":"seg1","position":[0,0,0]}],"meshAssets":[{"id":"aaaaaaaa-0000-4000-8000-000000000001","segmentId":"zzz","format":"obj","coordinateFrame":"map","byteCount":1000,"sha256":"abababababababababababababababababababababababababababababababab","boundsMin":[0,0,0],"boundsMax":[1,1,1]}]}'),
 ('asset bad hash', false, '{"nodes":[{"kind":"room","segmentId":"seg1","position":[0,0,0]}],"meshAssets":[{"id":"aaaaaaaa-0000-4000-8000-000000000001","segmentId":"seg1","format":"obj","coordinateFrame":"map","byteCount":1000,"sha256":"XYZ","boundsMin":[0,0,0],"boundsMax":[1,1,1]}]}'),
 ('asset inverted bounds', false, '{"nodes":[{"kind":"room","segmentId":"seg1","position":[0,0,0]}],"meshAssets":[{"id":"aaaaaaaa-0000-4000-8000-000000000001","segmentId":"seg1","format":"obj","coordinateFrame":"map","byteCount":1000,"sha256":"abababababababababababababababababababababababababababababababab","boundsMin":[5,0,0],"boundsMax":[1,1,1]}]}'),
 ('asset too big', false, '{"nodes":[{"kind":"room","segmentId":"seg1","position":[0,0,0]}],"meshAssets":[{"id":"aaaaaaaa-0000-4000-8000-000000000001","segmentId":"seg1","format":"obj","coordinateFrame":"map","byteCount":40000001,"sha256":"abababababababababababababababababababababababababababababababab","boundsMin":[0,0,0],"boundsMax":[1,1,1]}]}'),
 ('asset not an array', false, '{"nodes":[{"kind":"room","segmentId":"seg1","position":[0,0,0]}],"meshAssets":{"a":1}}'),
 ('MISSING: empty extent {}', false, '{"nodes":[{"kind":"room","segmentId":"seg1","position":[3,0,0],"extent":{}}]}'),
 ('MISSING extent key center', false, '{"nodes":[{"kind":"room","segmentId":"seg1","position":[3,0,0],"extent":{"halfExtents":[2,1.5],"yaw":0.3,"areaSquareMeters":10}}]}'),
 ('MISSING extent key halfExtents', false, '{"nodes":[{"kind":"room","segmentId":"seg1","position":[3,0,0],"extent":{"center":[4,0,0],"yaw":0.3,"areaSquareMeters":10}}]}'),
 ('MISSING extent key yaw', false, '{"nodes":[{"kind":"room","segmentId":"seg1","position":[3,0,0],"extent":{"center":[4,0,0],"halfExtents":[2,1.5],"areaSquareMeters":10}}]}'),
 ('MISSING extent key areaSquareMeters', false, '{"nodes":[{"kind":"room","segmentId":"seg1","position":[3,0,0],"extent":{"center":[4,0,0],"halfExtents":[2,1.5],"yaw":0.3}}]}'),
 ('MISSING node position', false, '{"nodes":[{"kind":"room","segmentId":"seg1","extent":{"center":[4,0,0],"halfExtents":[2,1.5],"yaw":0.3,"areaSquareMeters":10}}]}'),
 ('MISSING node kind', false, '{"nodes":[{"segmentId":"seg1","position":[3,0,0],"extent":{"center":[4,0,0],"halfExtents":[2,1.5],"yaw":0.3,"areaSquareMeters":10}}]}'),
 ('MISSING asset key id', false, '{"nodes":[{"kind":"room","segmentId":"seg1","position":[0,0,0]}],"meshAssets":[{"segmentId":"seg1","format":"obj","coordinateFrame":"map","byteCount":1000,"sha256":"abababababababababababababababababababababababababababababababab","boundsMin":[0,0,0],"boundsMax":[1,1,1]}]}'),
 ('MISSING asset key segmentId', false, '{"nodes":[{"kind":"room","segmentId":"seg1","position":[0,0,0]}],"meshAssets":[{"id":"aaaaaaaa-0000-4000-8000-000000000001","format":"obj","coordinateFrame":"map","byteCount":1000,"sha256":"abababababababababababababababababababababababababababababababab","boundsMin":[0,0,0],"boundsMax":[1,1,1]}]}'),
 ('MISSING asset key format', false, '{"nodes":[{"kind":"room","segmentId":"seg1","position":[0,0,0]}],"meshAssets":[{"id":"aaaaaaaa-0000-4000-8000-000000000001","segmentId":"seg1","coordinateFrame":"map","byteCount":1000,"sha256":"abababababababababababababababababababababababababababababababab","boundsMin":[0,0,0],"boundsMax":[1,1,1]}]}'),
 ('MISSING asset key coordinateFrame', false, '{"nodes":[{"kind":"room","segmentId":"seg1","position":[0,0,0]}],"meshAssets":[{"id":"aaaaaaaa-0000-4000-8000-000000000001","segmentId":"seg1","format":"obj","byteCount":1000,"sha256":"abababababababababababababababababababababababababababababababab","boundsMin":[0,0,0],"boundsMax":[1,1,1]}]}'),
 ('MISSING asset key byteCount', false, '{"nodes":[{"kind":"room","segmentId":"seg1","position":[0,0,0]}],"meshAssets":[{"id":"aaaaaaaa-0000-4000-8000-000000000001","segmentId":"seg1","format":"obj","coordinateFrame":"map","sha256":"abababababababababababababababababababababababababababababababab","boundsMin":[0,0,0],"boundsMax":[1,1,1]}]}'),
 ('MISSING asset key sha256', false, '{"nodes":[{"kind":"room","segmentId":"seg1","position":[0,0,0]}],"meshAssets":[{"id":"aaaaaaaa-0000-4000-8000-000000000001","segmentId":"seg1","format":"obj","coordinateFrame":"map","byteCount":1000,"boundsMin":[0,0,0],"boundsMax":[1,1,1]}]}'),
 ('MISSING asset key boundsMin', false, '{"nodes":[{"kind":"room","segmentId":"seg1","position":[0,0,0]}],"meshAssets":[{"id":"aaaaaaaa-0000-4000-8000-000000000001","segmentId":"seg1","format":"obj","coordinateFrame":"map","byteCount":1000,"sha256":"abababababababababababababababababababababababababababababababab","boundsMax":[1,1,1]}]}'),
 ('MISSING asset key boundsMax', false, '{"nodes":[{"kind":"room","segmentId":"seg1","position":[0,0,0]}],"meshAssets":[{"id":"aaaaaaaa-0000-4000-8000-000000000001","segmentId":"seg1","format":"obj","coordinateFrame":"map","byteCount":1000,"sha256":"abababababababababababababababababababababababababababababababab","boundsMin":[0,0,0]}]}'),
 ('asset is not an object', false, '{"nodes":[{"kind":"room","segmentId":"seg1","position":[0,0,0]}],"meshAssets":[5]}'),
 ('asset array of nulls', false, '{"nodes":[{"kind":"room","segmentId":"seg1","position":[0,0,0]}],"meshAssets":[null]}');
select name, expect, public.map_extras_valid(m) as got, (public.map_extras_valid(m) = expect) as ok from cases order by ok, name;
-- the constraint itself must reject a bad row and accept a good one
insert into public.canonical_buildings values (gen_random_uuid(), '{"nodes":[]}');
do $$ begin
  begin insert into public.canonical_buildings values (gen_random_uuid(), '{"nodes":[{"kind":"door","segmentId":"s","position":[0,0,0],"extent":{"center":[0,0,0],"halfExtents":[1,1],"yaw":0,"areaSquareMeters":1}}]}'); raise notice 'FAIL: bad row accepted';
  exception when check_violation then raise notice 'ok: bad row refused by the constraint'; end;
end $$;
