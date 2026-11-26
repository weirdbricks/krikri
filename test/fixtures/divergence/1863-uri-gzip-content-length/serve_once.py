# One fixed HTTP exchange on a UNIX socket: the suite has no HTTP server and a
# fixed port would collide across parallel shards. The socket lives at a short
# /tmp path because AF_UNIX caps the whole path at 108 bytes and the corpus
# replay's scratch directory is already longer than that; the playbook learns
# the path from the file this helper writes, which keeps it out of the
# transcript. The 404 body is GitHub's API shape, and it is served compressed
# only when the request offers gzip (real ansible never does).
import gzip
import json
import os
import socket
import sys

BODY = json.dumps(
    {
        "message": "Not Found",
        "documentation_url": "https://docs.github.com/rest/releases/releases#get-the-latest-release",
        "status": "404",
    },
    separators=(",", ":"),
).encode()
GZ = gzip.compress(BODY, mtime=0)

info_path = sys.argv[1]
path = "/tmp/krikri-uri-1863-%d.sock" % os.getpid()
try:
    os.unlink(path)
except OSError:
    pass
srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
srv.bind(path)
srv.listen(1)
# The listener is up before the path file exists, so the playbook's wait cannot
# race the uri task's connect.
with open(info_path, "w") as fh:
    fh.write(path)
conn, _ = srv.accept()
req = b""
while b"\r\n\r\n" not in req:
    chunk = conn.recv(4096)
    if not chunk:
        break
    req += chunk
accept_encoding = ""
for line in req.split(b"\r\n")[1:]:
    if line.lower().startswith(b"accept-encoding:"):
        accept_encoding = line.split(b":", 1)[1].strip().decode()
if "gzip" in accept_encoding:
    payload, encoding = GZ, b"Content-Encoding: gzip\r\n"
else:
    payload, encoding = BODY, b""
conn.sendall(
    b"HTTP/1.1 404 Not Found\r\n"
    b"Content-Type: application/json\r\n"
    + encoding
    + b"Content-Length: "
    + str(len(payload)).encode()
    + b"\r\nConnection: close\r\n\r\n"
    + payload
)
conn.close()
srv.close()
os.unlink(path)
