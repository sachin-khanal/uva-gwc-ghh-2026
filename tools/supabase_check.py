#!/usr/bin/env python3
"""Check that the Supabase project works for SHARED MAP DATA, the way the app uses it (stdlib only, Python 3.8+).

  python3 tools/supabase_check.py            read-only: keys, sign-in, list shared maps, and (if a ZZ CONNECTION TEST building
                                             exists) whether a brand-new third user can download its scan files
  python3 tools/supabase_check.py --write    ALSO runs the full round trip with two anonymous users: publish, see, download,
                                             extend, stale re-upload. Leaves ONE building named "ZZ CONNECTION TEST ..." that the app
                                             cannot delete; remove it in the Supabase SQL editor with:
                                                 delete from public.canonical_buildings where name like 'ZZ CONNECTION TEST%';

Reads SUPABASE_URL and SUPABASE_ANON_KEY from the environment, else from Config/Local.xcconfig (the odd "https:/$()/" is understood).
Never prints keys. Refuses to run with a service_role key. Exit status 0 only when every check passes.
Owner: U3 (backend) / D. Born from the live test of 2026-10-17 (scan files were not readable by a second user).
"""
import base64, json, os, re, sys, time, urllib.error, urllib.request, uuid
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
RESULTS = []


def report(name, ok, detail=""):
    RESULTS.append(ok)
    print(("PASS " if ok else "FAIL ") + name + (" - " + detail if detail else ""))
    return ok


def load_config():
    url, key = os.environ.get("SUPABASE_URL"), os.environ.get("SUPABASE_ANON_KEY")
    cfg = ROOT / "Config" / "Local.xcconfig"
    if (not url or not key) and cfg.exists():
        text = cfg.read_text(encoding="utf-8")
        u = re.search(r"^SUPABASE_URL\s*=\s*(.+)$", text, re.M)
        k = re.search(r"^SUPABASE_ANON_KEY\s*=\s*(.+)$", text, re.M)
        url = url or (u.group(1).strip() if u else None)
        key = key or (k.group(1).strip() if k else None)
    if url:
        url = url.replace("https:/$()/", "https://").rstrip("/")
    return url, key


def jwt_role(key):
    try:
        part = key.split(".")[1]
        return json.loads(base64.urlsafe_b64decode(part + "=" * (-len(part) % 4))).get("role")
    except Exception:
        return None


class Api:
    def __init__(self, url, key):
        self.url, self.key, self.token, self.uid = url, key, None, None

    def call(self, method, path, body=None, raw=None, headers=None):
        h = {"apikey": self.key}
        if body is not None:
            h["Content-Type"] = "application/json"
        if self.token:
            h["Authorization"] = "Bearer " + self.token
        h.update(headers or {})
        data = raw if raw is not None else (json.dumps(body).encode() if body is not None else None)
        req = urllib.request.Request(self.url + path, data=data, headers=h, method=method)
        try:
            with urllib.request.urlopen(req, timeout=40) as r:
                return r.status, r.read()
        except urllib.error.HTTPError as e:
            return e.code, e.read()

    def sign_in_anonymously(self):
        status, body = self.call("POST", "/auth/v1/signup", {})
        if status != 200:
            return False, f"HTTP {status}: {body[:160].decode(errors='ignore')}"
        j = json.loads(body)
        self.token, self.uid = j["access_token"], j["user"]["id"].lower()
        return True, self.uid[:6]

    def list_maps(self):
        status, body = self.call("GET", "/rest/v1/canonical_buildings?select=*&order=updated_at.desc")
        return status, (json.loads(body) if status == 200 else body.decode(errors="ignore")[:160])

    def extend(self, map_json):
        return self.call("POST", "/rest/v1/rpc/extend_building", {"incoming": map_json})

    def upload(self, bucket, path, data):
        return self.call("POST", f"/storage/v1/object/{bucket}/{path}", raw=data,
                         headers={"Content-Type": "application/octet-stream", "x-upsert": "true"})

    def download(self, bucket, path):
        return self.call("GET", f"/storage/v1/object/authenticated/{bucket}/{path}")


def check_scan_files_readable(row, who):
    """Can `who` (a user that is NOT the file's owner) download every scan file listed in the row?"""
    bad = []
    for seg, owner in (row.get("segment_owners") or {}).items():
        status, body = who.download("worldmaps", f"{owner}/{row['map_id']}/{seg}.arworldmap")
        if status != 200:
            bad.append(f"{seg}: HTTP {status}")
    return bad


def main():
    write = "--write" in sys.argv
    url, key = load_config()
    if not report("config.present", bool(url and key), "SUPABASE_URL / SUPABASE_ANON_KEY"):
        return 1
    role = jwt_role(key)
    if role == "service_role":
        print("STOP: that is a service_role key. Never put it in the app or the repo; use the anon public key.")
        return 2
    report("config.urlLooksRight", url.startswith("https://") and ".supabase." in url, "https://<ref>.supabase.co")
    report("config.keyIsAnon", role in ("anon", None), f"role={role or 'not a JWT (publishable key?)'}")

    a, b = Api(url, key), Api(url, key)
    ok, detail = a.sign_in_anonymously()
    if not report("auth.anonymousSignIn", ok, detail if not ok else "user " + detail + " (Anonymous Sign-Ins is enabled)"):
        return 1
    status, rows = a.list_maps()
    if not report("db.canonicalBuildingsReadable", status == 200, f"{len(rows) if status == 200 else rows} shared map(s)"):
        print("      -> run supabase/migrations 0001, 0002, 0003 (in that order) in the SQL editor")
        return 1
    status, _ = a.call("POST", "/rest/v1/rpc/extend_building", {"incoming": {}})
    report("db.extendBuildingFunctionExists", status != 404, f"HTTP {status} (an 'Invalid map' error is the expected, healthy answer)")

    # Read-only: can a brand-new user download the scan files of the existing test building(s)?
    tests = [r for r in (rows if isinstance(rows, list) else []) if str(r.get("name", "")).startswith("ZZ CONNECTION TEST")]
    if tests:
        c = Api(url, key)
        c.sign_in_anonymously()
        for r in tests[:2]:
            bad = check_scan_files_readable(r, c)
            report("storage.otherUserCanDownloadScanFiles", not bad,
                   f"{r['name'][:40]}: " + ("all scan files readable" if not bad else "; ".join(bad)))
        if any(not x for x in RESULTS[-len(tests[:2]):]):
            print("      -> the storage read policy is not working. In the SQL editor, run  select policyname, cmd from pg_policies\n"
                  "         where schemaname='storage' and tablename='objects';  and re-run the end of supabase/migrations/0002_canonical_maps.sql\n"
                  "         (the 'canonical_worldmaps_read' policy). See supabase/CANONICAL_MAPS.md.")
    else:
        print("INFO storage.otherUserCanDownloadScanFiles - no ZZ CONNECTION TEST building yet; run with --write once to create one")

    if write:
        round_trip(a, b, url, key)
    ok_all = all(RESULTS)
    print("\nRESULT:", "ALL PASS" if ok_all else f"{RESULTS.count(False)} FAILED")
    return 0 if ok_all else 1


def round_trip(a, b, url, key):
    ok, detail = b.sign_in_anonymously()
    report("write.secondUserSignedIn", ok and b.uid != a.uid, detail)
    stamp = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    mid = str(uuid.uuid4()).upper()

    def node(z, seg, label=None, by="check-A"):
        n = {"id": str(uuid.uuid4()).upper(), "kind": "room" if label else "corridor", "position": [0, 0, z], "segmentId": seg, "createdBy": by}
        if label:
            n["label"] = label
        return n

    n1, n2, n3 = node(0, "seg1"), node(-1.5, "seg1", "Test Room 1"), node(-3, "seg1")
    m = {"id": mid, "name": f"ZZ CONNECTION TEST {stamp} (safe to delete)", "version": 1, "schemaVersion": 4,
         "nodes": [n1, n2, n3],
         "edges": [{"from": n1["id"], "to": n2["id"], "distance": 1.5}, {"from": n2["id"], "to": n3["id"], "distance": 1.5}]}
    scan_a = os.urandom(4096)
    t = time.time()
    s1, _ = a.upload("worldmaps", f"{a.uid}/{mid.lower()}/seg1.arworldmap", scan_a)
    s2, body = a.extend(m)
    report("write.publish", s1 == 200 and s2 in (200, 204), f"upload HTTP {s1}, extend HTTP {s2} {'' if s2 in (200,204) else body[:120]} ({int((time.time()-t)*1000)} ms)")
    status, rows = b.list_maps()
    mine = next((r for r in rows if r["map_id"].lower() == mid.lower()), None) if status == 200 else None
    report("write.visibleToOtherUser", mine is not None and len(mine["map_json"]["nodes"]) == 3, "second user lists it")
    st, got = b.download("worldmaps", f"{a.uid}/{mid.lower()}/seg1.arworldmap")
    report("write.otherUserDownloadsScanFile", st == 200 and got == scan_a, f"HTTP {st}, {len(got) if st == 200 else 0} of {len(scan_a)} bytes identical={got == scan_a}")
    # B extends
    n4 = node(-4.5, "seg2", "Test Room 2", "check-B")
    ext = dict(m, nodes=m["nodes"] + [n4], edges=m["edges"] + [{"from": n3["id"], "to": n4["id"], "distance": 1.5}])
    scan_b = os.urandom(2048)
    s1, _ = b.upload("worldmaps", f"{b.uid}/{mid.lower()}/seg2.arworldmap", scan_b)
    s2, body = b.extend(ext)
    report("write.extendByOtherUser", s1 == 200 and s2 in (200, 204), f"upload HTTP {s1}, extend HTTP {s2} {'' if s2 in (200,204) else body[:120]}")
    status, rows = a.list_maps()
    row = next((r for r in rows if r["map_id"].lower() == mid.lower()), None) if status == 200 else None
    report("write.extensionVisibleToOwner", row is not None and len(row["map_json"]["nodes"]) == 4, f"{len(row['map_json']['nodes']) if row else '?'} nodes, version {row['version'] if row else '?'}")
    st, got = a.download("worldmaps", f"{b.uid}/{mid.lower()}/seg2.arworldmap")
    report("write.ownerDownloadsContributorScan", st == 200 and got == scan_b, f"HTTP {st}")
    a.extend(m)  # A re-uploads its stale 3-node copy
    status, rows = b.list_maps()
    row = next((r for r in rows if r["map_id"].lower() == mid.lower()), None) if status == 200 else None
    report("write.staleUploadKeepsExtension", row is not None and len(row["map_json"]["nodes"]) == 4, "4 nodes after the stale re-upload")
    print(f"NOTE left behind: building '{m['name']}' (cannot be deleted by the app).")


if __name__ == "__main__":
    sys.exit(main())
