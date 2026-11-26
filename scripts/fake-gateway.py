#!/usr/bin/env python3
"""A stand-in for Nexus's image gateway, for working on Diffuse away from
atlas. It speaks the /img/v1 contract in Proton's docs/DIFFUSE.md: the v1
catalogue and model lists from the fixtures, and runs that play out over the
graph actually sent (each node runs in turn, samplers count their steps and
send previews, output nodes send an image) without a GPU.

    python3 scripts/fake-gateway.py [--port 7421] [--image build/fake/output.png --preview build/fake/preview.jpg]
    PHOTON_GATEWAY=http://127.0.0.1:7421/img/v1 NEXUS_KEY=dev build/.../Photon.app/Contents/MacOS/Photon
"""

import argparse
import base64
import json
import os
import struct
import threading
import time
import zlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FIXTURES = os.path.join(ROOT, "Packages/PhotonKit/Tests/DiffuseCoreTests/Fixtures")
PREFIX = "/img/v1"

runs = {}
uploads = {}
cancelled = set()
lock = threading.Lock()


def png_chunk(kind, data):
    return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)


def with_flow(png, graph):
    """The PNG with the graph that made it as a `proton-flow` tEXt chunk
    after its IHDR, as forge writes it, so the gallery can say what made it."""
    if not graph or png[:8] != b"\x89PNG\r\n\x1a\n":
        return png
    ihdr_end = 8 + 8 + struct.unpack(">I", png[8:12])[0] + 4
    text = json.dumps({"graph": graph}, ensure_ascii=True).encode("latin-1")
    return png[:ihdr_end] + png_chunk(b"tEXt", b"proton-flow\x00" + text) + png[ihdr_end:]


def gradient_png(width=512, height=512):
    """A dusk gradient, as a PNG, when no picture is given."""
    rows = []
    for y in range(height):
        t = y / height
        r, g, b = int(26 + 40 * t), int(34 + 20 * t), int(54 + 10 * t)
        rows.append(b"\x00" + bytes([r, g, b]) * width)
    raw = b"".join(rows)

    return (b"\x89PNG\r\n\x1a\n" + png_chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
            + png_chunk(b"IDAT", zlib.compress(raw, 9)) + png_chunk(b"IEND", b""))


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    image = b""
    preview = b""
    catalogue = {}

    def log_message(self, fmt, *args):
        print("gateway:", fmt % args, flush=True)

    def send_json(self, status, body):
        data = json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def authorised(self):
        if not self.headers.get("Authorization", "").startswith("Bearer "):
            self.send_json(401, {"error": "key", "message": "no key"})
            return False
        return True

    def path_parts(self):
        if not self.path.startswith(PREFIX):
            return None
        return [p for p in self.path[len(PREFIX):].split("/") if p]

    def do_GET(self):
        parts = self.path_parts()
        if parts is None:
            return self.send_json(404, {"error": "not_found", "message": self.path})
        if not self.authorised():
            return
        if parts == ["status"]:
            with lock:
                queue = [r for r, v in runs.items() if v["state"] == "queued"]
                running = next((r for r, v in runs.items() if v["state"] == "running"), None)
            return self.send_json(200, {"gpu": {"name": "Stand-in gateway (no GPU)", "total": 25769803776, "used": 6442450944},
                                        "loaded": [{"name": "sd_xl_base_1.0.safetensors", "bytes": 6938078334}],
                                        "queue": queue, "running": running})
        if parts == ["nodes"]:
            return self.send_json(200, Handler.catalogue)
        if parts == ["models"]:
            with open(os.path.join(FIXTURES, "models.json")) as f:
                return self.send_json(200, json.load(f))
        if len(parts) == 3 and parts[0] == "runs" and parts[2] == "events":
            return self.stream(parts[1])
        if len(parts) == 2 and parts[0] == "images":
            with lock:
                entry = runs.get(parts[1].split("_")[0], {})
            data = with_flow(Handler.image, entry.get("graph"))
            self.send_response(200)
            self.send_header("Content-Type", "image/png")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)
            return
        self.send_json(404, {"error": "not_found", "message": self.path})

    def do_POST(self):
        parts = self.path_parts()
        length = int(self.headers.get("Content-Length", "0"))
        body = self.rfile.read(length) if length else b""
        if parts is None:
            return self.send_json(404, {"error": "not_found", "message": self.path})
        if not self.authorised():
            return
        if parts == ["runs"]:
            graph = json.loads(body or b"{}").get("graph", {})
            with lock:
                run = "run%03d" % (len(runs) + 1)
                runs[run] = {"graph": graph, "state": "queued"}
            return self.send_json(200, {"run": run, "position": 0})
        if parts == ["uploads"]:
            width = height = 0
            if body[:8] == b"\x89PNG\r\n\x1a\n":
                width, height = struct.unpack(">II", body[16:24])
            with lock:
                upload = "upload%03d.%s" % (len(uploads) + 1, "png" if body[:4] == b"\x89PNG" else "jpg")
                uploads[upload] = len(body)
            print(f"gateway: kept {upload}, {len(body)} bytes, {width}x{height}", flush=True)
            return self.send_json(200, {"id": upload, "width": width, "height": height})
        if len(parts) == 3 and parts[0] == "runs" and parts[2] == "cancel":
            cancelled.add(parts[1])
            return self.send_json(200, {})
        self.send_json(404, {"error": "not_found", "message": self.path})

    def event(self, kind, data):
        self.wfile.write(f"event: {kind}\ndata: {json.dumps(data)}\n\n".encode())
        self.wfile.flush()

    def stream(self, run):
        with lock:
            entry = runs.get(run)
        if entry is None:
            return self.send_json(404, {"error": "not_found", "message": run})
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Connection", "close")
        self.end_headers()
        self.close_connection = True
        start = time.time()
        types = {n["type"]: n for n in Handler.catalogue.get("nodes", [])}
        try:
            self.wfile.write(b": connected\n\n")
            self.event("queued", {"position": 0})
            time.sleep(0.4)
            entry["state"] = "running"
            self.event("started", {})
            size = (1024, 1024)
            for node in entry["graph"].get("nodes", []):
                if run in cancelled:
                    self.event("cancelled", {})
                    return
                values = node.get("values", {})
                if node["type"] == "LoadImage" and values.get("image") not in uploads:
                    # Forge only reads pictures sent to /uploads first.
                    self.event("error", {"id": node["id"], "error": "invalid", "message": f"no upload named {values.get('image')!r}"})
                    return
                if node["type"] == "EmptyLatent":
                    size = (values.get("width", 1024), values.get("height", 1024))
                if node["type"].startswith("Load"):
                    self.event("node", {"id": node["id"], "state": "cached"})
                    continue
                self.event("node", {"id": node["id"], "state": "running"})
                if "steps" in values:
                    steps = int(values["steps"])
                    for step in range(1, steps + 1):
                        if run in cancelled:
                            self.event("cancelled", {})
                            return
                        time.sleep(0.09)
                        self.event("progress", {"id": node["id"], "step": step, "steps": steps})
                        if step in (steps // 3, 2 * steps // 3) and Handler.preview:
                            self.event("preview", {"id": node["id"], "step": step, "jpeg": base64.b64encode(Handler.preview).decode()})
                else:
                    time.sleep(0.25)
                if not types.get(node["type"], {}).get("outputs", [1]):
                    self.event("image", {"id": node["id"], "image": f"{run}_{node['id']}", "index": 0, "width": size[0], "height": size[1]})
                self.event("node", {"id": node["id"], "state": "done"})
            self.event("done", {"seconds": round(time.time() - start, 1)})
        except (BrokenPipeError, ConnectionResetError):
            pass
        finally:
            entry["state"] = "done"


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=7421)
    parser.add_argument("--image", help="a PNG every output node returns")
    parser.add_argument("--preview", help="a JPEG samplers preview")
    args = parser.parse_args()
    with open(os.path.join(FIXTURES, "catalogue-v1.json")) as f:
        Handler.catalogue = json.load(f)
    Handler.image = open(args.image, "rb").read() if args.image else gradient_png()
    Handler.preview = open(args.preview, "rb").read() if args.preview else b""
    server = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    print(f"gateway: http://127.0.0.1:{args.port}{PREFIX}", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
