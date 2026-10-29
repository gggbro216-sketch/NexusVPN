#!/usr/bin/env python3
"""Local HTTP fixture server for subscription tests (127.0.0.1 only).

Usage: http_fixture_server.py <port>
Paths:
  /sub/links      base64 list of share links (state-dependent, see /set)
  /sub/html       HTML page
  /sub/empty      empty body
  /sub/404        HTTP 404
  /sub/slow       sleeps 30 s (client timeout)
  /sub/redirect   302 -> /sub/links
  /sub/big        > 8 MiB body
  /set?v=N        switches /sub/links content version
"""
import base64
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

UUID = "b831381d-6324-4d53-ad4f-8cda48b30811"
VERSIONS = {
    1: [f"vless://{UUID}@a.example.com:443?security=tls#Server%20A",
        f"vless://{UUID}@b.example.com:443?security=tls#Server%20B",
        "trojan://pw@c.example.com:443#Server%20C"],
    # v2: B renamed by provider, C removed, D added, A unchanged
    2: [f"vless://{UUID}@a.example.com:443?security=tls#Server%20A",
        f"vless://{UUID}@b.example.com:443?security=tls#Server%20B%20(new%20name)",
        "trojan://pw@d.example.com:443#Server%20D"],
}
state = {"v": 1}


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def _send(self, code, body=b"", headers=None):
        self.send_response(code)
        for k, v in (headers or {}).items():
            self.send_header(k, v)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        p = self.path
        if p.startswith("/sub/"):
            p = p.split("?")[0]
        if p.startswith("/set?v="):
            state["v"] = int(p.split("=")[1])
            return self._send(200, b"ok")
        if p == "/sub/links":
            body = base64.b64encode("\n".join(VERSIONS[state["v"]]).encode())
            return self._send(200, body, {"subscription-userinfo": "upload=1; download=2; total=1000; expire=4102444800",
                                          "profile-title": "base64:" + base64.b64encode("Тест".encode()).decode()})
        if p == "/sub/html":
            return self._send(200, b"<!DOCTYPE html><html><body>login</body></html>", {"Content-Type": "text/html"})
        if p == "/sub/empty":
            return self._send(200, b"")
        if p == "/sub/404":
            return self._send(404, b"not found")
        if p == "/sub/slow":
            time.sleep(30)
            return self._send(200, b"late")
        if p == "/sub/redirect":
            return self._send(302, b"", {"Location": "/sub/links"})
        if p == "/sub/big":
            return self._send(200, b"A" * (9 * 1024 * 1024))
        return self._send(404)


if __name__ == "__main__":
    ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1])), Handler).serve_forever()
