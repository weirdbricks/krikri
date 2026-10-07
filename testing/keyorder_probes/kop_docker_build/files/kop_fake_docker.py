import http.server, json, os, socketserver, sys

path, mode = sys.argv[1], sys.argv[2]
VERSION = {"ApiVersion": "1.43", "MinAPIVersion": "1.12", "Version": "24.0.7", "Os": "linux", "Arch": "amd64"}


class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def _send(self, code, body):
        data = json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        p = self.path.split("?")[0]
        if p.endswith("/_ping"):
            self.send_response(200); self.send_header("Content-Length", "2"); self.end_headers(); self.wfile.write(b"OK"); return
        if p.endswith("/version"):
            return self._send(200, VERSION)
        if mode == "e500":
            return self._send(500, {"message": "kop fake daemon: internal failure"})
        return self._send(404, {"message": "kop fake daemon: no such thing"})

    do_POST = do_DELETE = do_HEAD = do_GET


class S(socketserver.UnixStreamServer):
    def get_request(self):
        req, _ = super().get_request()
        return req, ("local", 0)


if os.path.exists(path):
    os.unlink(path)
S(path, H).serve_forever()
