#!/usr/bin/env python3
"""A stand-in Cloudflare API for tests/fm-tunnel.test.sh.

Speaks the subset of api.cloudflare.com/client/v4 that bin/fm-tunnel-lib.sh
calls, keeping tunnels / zones / DNS records / Access apps / policies in a JSON
state file so a test can seed fixtures before a run and assert on what the real
script actually created, updated, or deleted afterwards.

State file keys the test may seed or read:
  tunnels, dns, apps, policies, zones   - the resources
  requests                              - every request, as "METHOD path"
  token                                 - the bearer token that authenticates
  fail                                  - list of "METHOD /path-prefix" globs
                                          answered 403, to exercise the
                                          lookup-failed / delete-failed paths

Usage: fake-cloudflare.py <state-file> <port-file>
"""
import fnmatch
import json
import os
import sys
import threading
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import urlparse, parse_qs

STATE = sys.argv[1]
PORTFILE = sys.argv[2]
LOCK = threading.Lock()
SEQ = [0]


def load():
    with open(STATE) as f:
        return json.load(f)


def save(s):
    tmp = STATE + ".tmp"
    with open(tmp, "w") as f:
        json.dump(s, f, indent=1)
    os.replace(tmp, STATE)


def newid(prefix):
    SEQ[0] += 1
    return "%s-%08x" % (prefix, SEQ[0])


class H(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def reply(self, code, body):
        raw = json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def ok(self, result, extra=None):
        body = {"success": True, "errors": [], "messages": [], "result": result}
        if extra:
            body.update(extra)
        self.reply(200, body)

    def err(self, code, msg):
        self.reply(code, {"success": False, "errors": [{"code": 1000, "message": msg}], "result": None})

    def body(self):
        n = int(self.headers.get("Content-Length") or 0)
        return json.loads(self.rfile.read(n) or b"{}")

    def handle_any(self, method):
        with LOCK:
            s = load()
            u = urlparse(self.path)
            path, q = u.path, parse_qs(u.query)
            s.setdefault("requests", []).append("%s %s" % (method, path))
            save(s)

            auth = self.headers.get("Authorization") or ""
            if auth != "Bearer " + s["token"]:
                return self.err(403, "Invalid API Token")
            for pat in s.get("fail", []):
                fm, fp = pat.split(" ", 1)
                if fm in (method, "*") and fnmatch.fnmatch(path, fp):
                    return self.err(403, "Actor does not have permission")

            p = [x for x in path.split("/") if x]
            # /accounts/<a>/...
            if p[0] == "accounts":
                rest = p[2:]
                if rest[:1] == ["cfd_tunnel"]:
                    return self.tunnels(method, rest[1:], q, s)
                if rest[:1] == ["access"] and rest[1:2] == ["apps"]:
                    return self.access(method, rest[2:], q, s)
            if p[0] == "zones":
                if len(p) == 1:
                    name = (q.get("name") or [""])[0]
                    return self.ok([z for z in s["zones"] if z["name"] == name])
                if p[2:3] == ["dns_records"]:
                    return self.dns(method, p[1], p[3:], q, s)
            return self.err(404, "not found: " + path)

    def tunnels(self, m, rest, q, s):
        if not rest:
            if m == "GET":
                name = (q.get("name") or [""])[0]
                return self.ok([t for t in s["tunnels"] if t["name"] == name])
            if m == "POST":
                b = self.body()
                t = {"id": newid("tun"), "name": b["name"], "deleted_at": None}
                s["tunnels"].append(t)
                save(s)
                return self.ok(t)
        tid = rest[0]
        if rest[1:] == ["configurations"] and m == "PUT":
            s["ingress"] = {"tunnel": tid, "config": self.body()["config"]}
            save(s)
            return self.ok(s["ingress"])
        if rest[1:] == ["token"] and m == "GET":
            return self.ok("run-token-for-" + tid)
        if not rest[1:] and m == "DELETE":
            s["tunnels"] = [t for t in s["tunnels"] if t["id"] != tid]
            save(s)
            return self.ok({"id": tid})
        return self.err(404, "tunnel route")

    def dns(self, m, zid, rest, q, s):
        if not rest:
            if m == "GET":
                name = (q.get("name") or [""])[0]
                return self.ok([r for r in s["dns"] if r["name"] == name])
            if m == "POST":
                b = self.body()
                r = dict(b, id=newid("dns"), zone_id=zid)
                s["dns"].append(r)
                save(s)
                return self.ok(r)
        rid = rest[0]
        rec = next((r for r in s["dns"] if r["id"] == rid), None)
        if rec is None:
            return self.err(404, "no such record")
        if m == "GET":
            return self.ok(rec)
        if m == "PUT":
            rec.update(self.body())
            save(s)
            return self.ok(rec)
        if m == "DELETE":
            s["dns"] = [r for r in s["dns"] if r["id"] != rid]
            save(s)
            return self.ok({"id": rid})
        return self.err(404, "dns route")

    def access(self, m, rest, q, s):
        if not rest:
            if m == "GET":
                dom = (q.get("domain") or [""])[0]
                res = [a for a in s["apps"] if a["domain"] == dom]
                return self.ok(res, {"result_info": {"page": 1, "total_pages": 1}})
            if m == "POST":
                b = self.body()
                a = dict(b, id=newid("app"))
                s["apps"].append(a)
                save(s)
                return self.ok(a)
        aid = rest[0]
        if rest[1:2] == ["policies"]:
            if len(rest) == 2:
                if m == "GET":
                    return self.ok([p for p in s["policies"] if p["app"] == aid])
                if m == "POST":
                    b = self.body()
                    pol = dict(b, id=newid("pol"), app=aid)
                    s["policies"].append(pol)
                    save(s)
                    return self.ok(pol)
            pid = rest[2]
            if m == "PUT":
                for pol in s["policies"]:
                    if pol["id"] == pid:
                        pol.update(self.body())
                save(s)
                return self.ok({"id": pid})
            if m == "DELETE":
                s["policies"] = [p for p in s["policies"] if p["id"] != pid]
                save(s)
                return self.ok({"id": pid})
        app = next((a for a in s["apps"] if a["id"] == aid), None)
        if app is None:
            return self.err(404, "no such app")
        if m == "GET":
            return self.ok(app)
        if m == "PUT":
            app.update(self.body())
            save(s)
            return self.ok(app)
        if m == "DELETE":
            s["apps"] = [a for a in s["apps"] if a["id"] != aid]
            s["policies"] = [p for p in s["policies"] if p["app"] != aid]
            save(s)
            return self.ok({"id": aid})
        return self.err(404, "access route")

    def do_GET(self):
        self.handle_any("GET")

    def do_POST(self):
        self.handle_any("POST")

    def do_PUT(self):
        self.handle_any("PUT")

    def do_DELETE(self):
        self.handle_any("DELETE")


srv = HTTPServer(("127.0.0.1", 0), H)
with open(PORTFILE, "w") as f:
    f.write(str(srv.server_address[1]))
srv.serve_forever()
