"""U3 local preview: serve only web assets and two sample JSON files on loopback."""
import argparse
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import unquote, urlsplit

PREVIEW_MAP = None

ROOT = Path(__file__).resolve().parents[1]


class ViewerHandler(SimpleHTTPRequestHandler):
    extensions_map = {**SimpleHTTPRequestHandler.extensions_map, ".js": "text/javascript", ".mjs": "text/javascript"}

    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=str(ROOT), **kwargs)

    def send_head(self):
        path = unquote(urlsplit(self.path).path)
        if path == "/preview-map.json" and PREVIEW_MAP is not None:
            from io import BytesIO
            data = PREVIEW_MAP.read_bytes()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Cache-Control", "no-store")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            return BytesIO(data)

        if path == "/":
            self.send_response(302)
            self.send_header("Location", "/web/")
            self.end_headers()
            return None
        resolved = (ROOT / path.lstrip("/")).resolve()
        allowed = (resolved.is_relative_to(ROOT / "web")
                   and (resolved.suffix in {".html", ".css", ".js", ".json"} or path == "/web/")) or resolved in {
                       ROOT / "Samples/rice-hall-sample.json", ROOT / "Samples/route-vectors.json"}
        if not allowed:
            self.send_error(404)
            return None
        return super().send_head()

    def list_directory(self, path):
        self.send_error(404)
        return None


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", type=int, default=8000)
    parser.add_argument("--preview-map", type=Path, help="Explicit local map snapshot, served only on loopback")
    args = parser.parse_args()
    PREVIEW_MAP = args.preview_map
    print(f"Waypoint viewer: http://127.0.0.1:{args.port}/web/", flush=True)
    with ThreadingHTTPServer(("127.0.0.1", args.port), ViewerHandler) as server:
        try:
            server.serve_forever()
        except KeyboardInterrupt:
            pass
