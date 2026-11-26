# #1863 - drew1kun.dnscrypt: a compressed uri response loses `content_length`

- Issue: https://github.com/weirdbricks/krikri/issues/1863
- Role: `drew1kun.dnscrypt` (rocky), round `logs___1795714389`
- Class: output gap (uri result fields)

**What diverged.** The role's `Retrieve the latest dnscrypt-proxy versions for
all architectures` task fetches the GitHub releases API, which answers 404 for
that repository with a JSON body. Real ansible's result carries
`"content_length": "130"`; krikri's carried no `content_length` at all.

**Why.** `plugins/uri.cr` built its `HTTP::Client` with Crystal's default
`compress = true`, so the plugin offered `Accept-Encoding: gzip, deflate` and
Crystal transparently inflated the answer - deleting `Content-Encoding` and
`Content-Length` from the response headers when it did. GitHub gzips a body
only for a client that offers gzip, so real ansible (whose http.client always
sends `Accept-Encoding: identity`) got the identity bytes and the header,
while krikri got the compressed one and lost it. Real decodes a gzip body
itself (urls.py's GzipDecodedReader, on the 2xx path only) and never touches
the headers, so the fix offers identity like urllib, inflates explicitly, and
takes `msg`'s byte count from the `Content-Length` header as real does.

**Fixture.** The role's task verbatim, with the public GitHub URL replaced by
a GitHub-shaped 404 served from a UNIX socket (`serve_once.py`): the suite has
no HTTP server and a fixed port would collide across parallel shards. The
socket lives at a short `/tmp/...` path because AF_UNIX caps the whole path at
108 bytes while the replay's scratch directory is longer, so the helper writes
its path into the scratch tree and the task reads it back (`unix_socket:`), which
also keeps the path out of the transcript. The helper compresses its body only
when the request offers gzip, exactly like GitHub, so the case pins the wire
behaviour and the header preservation in one transcript.

The round also flagged the role's next task (`Download dnscrypt-proxy version:
2.0.17`, `no_log: true`): real prints an `[ERROR]` block with the
download-failure message above the censored per-item line, and krikri used to
suppress it under the no_log display gate. That is a second, independent gap
and has its own case, `1863-unarchive-no-log-error-block`.

`expected.out` was captured with `bin/krikri-capture-case` from real
ansible-core 2.21.6.
