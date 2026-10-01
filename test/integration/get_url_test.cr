require "../minitest_helper"
require "http/server"
require "openssl/digest"
require "base64"
require "compress/gzip"
require "file_utils"
require "socket"

# A tiny local HTTP server (Crystal stdlib HTTP::Server, no python3
# dependency) serving fixed content + a redirect, started once for the
# whole file rather than per-example.
FILE_CONTENT  = "hello from get_url spec\n"
FILE_CHECKSUM = begin
  digest = OpenSSL::Digest.new("SHA256")
  digest.update(FILE_CONTENT)
  digest.final.hexstring
end
FILE_CHECKSUM_SHA384 = begin
  digest = OpenSSL::Digest.new("SHA384")
  digest.update(FILE_CONTENT)
  digest.final.hexstring
end

private GET_URL_TEST_SERVER = HTTP::Server.new do |context|
  case context.request.path
  when "/file.txt"
    context.response.status_code = 200
    context.response.print(FILE_CONTENT)
  when "/redirect.txt"
    context.response.status_code = 302
    context.response.headers["Location"] = "/file.txt"
  when "/sha256sums.txt"
    context.response.status_code = 200
    context.response.print("#{FILE_CHECKSUM}  file.txt\n0000000000000000000000000000000000000000000000000000000000000000  other.txt\n")
  when "/sha256sums-no-match.txt"
    context.response.status_code = 200
    context.response.print("0000000000000000000000000000000000000000000000000000000000000000  other.txt\n")
  when "/dyn/closer.cgi"
    # Stands in for apache.org/dyn/closer.cgi?action=download&...: a
    # redirect whose OWN path (/dyn/closer.cgi) has an unrelated basename,
    # pointing at the real package and naming it via Content-Disposition.
    context.response.status_code = 302
    context.response.headers["Location"] = "/pkg-1.0.tar.gz"
    context.response.headers["Content-Disposition"] = "attachment; filename=\"pkg-1.0.tar.gz\""
  when "/bare-cgi"
    # Same shape but NO Content-Disposition: the filename must then come
    # from the final (post-redirect) URL's basename.
    context.response.status_code = 302
    context.response.headers["Location"] = "/pkg-1.0.tar.gz"
  when "/pkg-1.0.tar.gz"
    context.response.status_code = 200
    context.response.print(FILE_CONTENT)
  when "/file.txt.sha256-bare"
    context.response.status_code = 200
    context.response.print("#{FILE_CHECKSUM}\n")
  when "/echo-headers.txt"
    if context.request.headers.has_key?("{}")
      context.response.status_code = 400
    else
      context.response.status_code = 200
      context.response.print(context.request.headers["X-Custom"]? || "no-custom-header")
    end
  when "/auth.txt"
    if context.request.headers["Authorization"]? == "Basic " + Base64.strict_encode("u1:p1")
      context.response.status_code = 200
      context.response.print("secret-authed")
    else
      context.response.status_code = 401
      context.response.headers["WWW-Authenticate"] = "Basic realm=\"x\""
      context.response.print("denied")
    end
  when "/echo-auth.txt"
    context.response.status_code = 200
    context.response.print(context.request.headers["Authorization"]? || "no-auth-header")
  when "/redirect-auth.txt"
    context.response.status_code = 302
    context.response.headers["Location"] = "/echo-auth.txt"
  when "/gz.txt"
    body = "gzip-body-here"
    context.response.status_code = 200
    if context.request.headers["Accept-Encoding"]?.try(&.includes?("gzip"))
      context.response.headers["Content-Encoding"] = "gzip"
      io = IO::Memory.new
      Compress::Gzip::Writer.open(io, &.print(body))
      context.response.print(io.to_s)
    else
      context.response.print(body)
    end
  else
    context.response.status_code = 404
  end
end
GET_URL_TEST_ADDRESS = GET_URL_TEST_SERVER.bind_unused_port
spawn { GET_URL_TEST_SERVER.listen }
Fiber.yield

private GET_URL_TEST_BASE = "http://#{GET_URL_TEST_ADDRESS}"

describe "get_url plugin" do
  it "downloads a new file" do
    dest = File.tempname("get-url-spec")
    result = PluginSpecHelper.run("get_url", {"url" => "#{GET_URL_TEST_BASE}/file.txt", "dest" => dest})

    result["changed"].as_bool.must_equal(true)
    falsey?(result["failed"]?.try(&.as_bool)).must_equal(true)
    File.read(dest).must_equal(FILE_CONTENT)
  ensure
    File.delete(dest) if dest && File.exists?(dest)
  end

  it "accepts headers: as a real dict (JSON text), not just the comma-separated string form" do
    # Real bug found benchmarking caddy_ansible.caddy_ansible: its own
    # `headers: '{{ caddy_github_headers }}'` (a real dict, `{}` by
    # default) arrives here as its JSON text ("{}") - previously always
    # split on "," then partitioned on ":" regardless of shape, turning
    # the literal text "{}" into an HTTP header literally NAMED "{}"
    # with an empty value. GitHub's real API rejected that outright
    # with 400 Bad Request; this spec's local server does the same.
    dest = File.tempname("get-url-spec")
    result = PluginSpecHelper.run("get_url", {"url" => "#{GET_URL_TEST_BASE}/echo-headers.txt", "dest" => dest, "headers" => "{}"})

    result["changed"].as_bool.must_equal(true)
    falsey?(result["failed"]?.try(&.as_bool)).must_equal(true)
    File.read(dest).must_equal("no-custom-header")
  ensure
    File.delete(dest) if dest && File.exists?(dest)
  end

  it "sends a populated dict's own key/value pairs as real headers" do
    dest = File.tempname("get-url-spec")
    result = PluginSpecHelper.run("get_url", {"url" => "#{GET_URL_TEST_BASE}/echo-headers.txt", "dest" => dest, "headers" => %({"X-Custom":"hello"})})

    result["changed"].as_bool.must_equal(true)
    falsey?(result["failed"]?.try(&.as_bool)).must_equal(true)
    File.read(dest).must_equal("hello")
  ensure
    File.delete(dest) if dest && File.exists?(dest)
  end

  it "still supports the comma-separated string form (key:value,key2:value2)" do
    dest = File.tempname("get-url-spec")
    result = PluginSpecHelper.run("get_url", {"url" => "#{GET_URL_TEST_BASE}/echo-headers.txt", "dest" => dest, "headers" => "X-Custom:legacy-form"})

    result["changed"].as_bool.must_equal(true)
    falsey?(result["failed"]?.try(&.as_bool)).must_equal(true)
    File.read(dest).must_equal("legacy-form")
  ensure
    File.delete(dest) if dest && File.exists?(dest)
  end

  it "verifies checksum and reports mismatch as a failure without touching dest" do
    dest = File.tempname("get-url-spec")
    result = PluginSpecHelper.run("get_url", {
      "url" => "#{GET_URL_TEST_BASE}/file.txt", "dest" => dest, "checksum" => "sha256:0000000000000000000000000000000000000000000000000000000000000000",
    })

    result["failed"].as_bool.must_equal(true)
    File.exists?(dest).must_equal(false)
  ensure
    File.delete(dest) if dest && File.exists?(dest)
  end

  it "treats an empty checksum: string the same as no checksum at all" do
    # Real bug found benchmarking juju4.openobserve's own "Download
    # openobserve from openobserve.ai" task: `checksum: "{{
    # openobserve_hash | default(omit) }}"` where openobserve_hash
    # DEFAULTS to "" - a real, DEFINED empty string, not undefined - for
    # this OS/arch combination, so default(omit) never fires; both real
    # Ansible and krikri receive checksum: "" identically. Real
    # Ansible's own get_url module treats a falsy checksum the same as
    # an absent one; this previously tried to verify against the empty
    # string and failed every download with "checksum mismatch:
    # expected , got <real hash>".
    dest = File.tempname("get-url-spec")
    result = PluginSpecHelper.run("get_url", {"url" => "#{GET_URL_TEST_BASE}/file.txt", "dest" => dest, "checksum" => ""})

    result["changed"].as_bool.must_equal(true)
    falsey?(result["failed"]?.try(&.as_bool)).must_equal(true)
    File.read(dest).must_equal(FILE_CONTENT)
  ensure
    File.delete(dest) if dest && File.exists?(dest)
  end

  it "verifies a sha384 checksum correctly, not silently as sha1" do
    # Real bug found benchmarking geerlingguy.composer's own "Download
    # Composer installer." task: `checksum: "sha384:{{ ... }}"`.
    # BasePlugin#native_checksum's own algorithm case only explicitly
    # handled "md5"/"sha256" - every other algorithm (sha1, sha224,
    # sha384, sha512) silently fell through to the `else` branch (SHA1)
    # regardless of what was actually requested, always computing a
    # 40-hex-char SHA1 digest against a 96-hex-char SHA384 expected
    # value - "checksum mismatch" on a download that was genuinely
    # correct.
    dest = File.tempname("get-url-spec")
    result = PluginSpecHelper.run("get_url", {
      "url" => "#{GET_URL_TEST_BASE}/file.txt", "dest" => dest, "checksum" => "sha384:#{FILE_CHECKSUM_SHA384}",
    })

    result["changed"].as_bool.must_equal(true)
    falsey?(result["failed"]?.try(&.as_bool)).must_equal(true)
    File.read(dest).must_equal(FILE_CONTENT)
  ensure
    File.delete(dest) if dest && File.exists?(dest)
  end

  it "is idempotent when dest exists and checksum matches" do
    dest = File.tempname("get-url-spec")
    File.write(dest, FILE_CONTENT)

    result = PluginSpecHelper.run("get_url", {
      "url" => "#{GET_URL_TEST_BASE}/file.txt", "dest" => dest, "checksum" => "sha256:#{FILE_CHECKSUM}",
    })

    result["changed"].as_bool.must_equal(false)
    falsey?(result["failed"]?.try(&.as_bool)).must_equal(true)
  ensure
    File.delete(dest) if dest && File.exists?(dest)
  end

  it "re-fetches an existing dest without force and without checksum, reporting changed when the URL content differs" do
    # Real bug found benchmarking buluma.fish (round952314): its "Add
    # fish repository key" task (get_url, no checksum:, no force:) hits
    # the live keyserver.ubuntu.com lookup, whose response can differ
    # between runs. Real ansible-core's get_url always performs the HTTP
    # request when dest exists (a conditional GET keyed on dest's mtime,
    # or a HEAD in check mode), then decides changed by comparing the
    # freshly fetched content's SHA1 against the existing dest file's
    # SHA1 - even with no checksum: param at all. krikri used to
    # short-circuit to ok purely on dest existence, never making a
    # request, so a warm rerun could never report changed: true where
    # real Ansible sometimes did.
    dest = File.tempname("get-url-spec")
    File.write(dest, "pre-existing, untouched")

    result = PluginSpecHelper.run("get_url", {"url" => "#{GET_URL_TEST_BASE}/file.txt", "dest" => dest})

    result["changed"].as_bool.must_equal(true)
    falsey?(result["failed"]?.try(&.as_bool)).must_equal(true)
    File.read(dest).must_equal(FILE_CONTENT)
  ensure
    File.delete(dest) if dest && File.exists?(dest)
  end

  it "is idempotent on an existing dest without force and without checksum when the URL content already matches" do
    # Same root cause as the spec above, other half of the behavior:
    # the fetch must happen (real Ansible always requests), but matching
    # content still converges to changed: false, not a forced rewrite.
    dest = File.tempname("get-url-spec")
    File.write(dest, FILE_CONTENT)

    result = PluginSpecHelper.run("get_url", {"url" => "#{GET_URL_TEST_BASE}/file.txt", "dest" => dest})

    result["changed"].as_bool.must_equal(false)
    falsey?(result["failed"]?.try(&.as_bool)).must_equal(true)
    File.read(dest).must_equal(FILE_CONTENT)
  ensure
    File.delete(dest) if dest && File.exists?(dest)
  end

  it "overwrites an existing dest when force is given" do
    dest = File.tempname("get-url-spec")
    File.write(dest, "stale content")

    result = PluginSpecHelper.run("get_url", {"url" => "#{GET_URL_TEST_BASE}/file.txt", "dest" => dest, "force" => "yes"})

    result["changed"].as_bool.must_equal(true)
    File.read(dest).must_equal(FILE_CONTENT)
  ensure
    File.delete(dest) if dest && File.exists?(dest)
  end

  it "is idempotent when force is given but the existing content already matches (no checksum needed)" do
    # Real bug found benchmarking geerlingguy.jenkins: its own "Add
    # Jenkins apt repository key." task uses force: true (real
    # Ansible's own get_url semantics: force: true means "always
    # re-fetch, bypassing freshness checks" - NOT "always report
    # changed"; it still compares the freshly downloaded content
    # against dest: before deciding changed). Previously
    # unconditionally returned changed: true after every force:
    # download regardless of whether the content actually differed, so
    # this exact task reported changed forever on a real host, never
    # converging.
    dest = File.tempname("get-url-spec")
    File.write(dest, FILE_CONTENT)

    result = PluginSpecHelper.run("get_url", {"url" => "#{GET_URL_TEST_BASE}/file.txt", "dest" => dest, "force" => "yes"})

    result["changed"].as_bool.must_equal(false)
    falsey?(result["failed"]?.try(&.as_bool)).must_equal(true)
    File.read(dest).must_equal(FILE_CONTENT)
  ensure
    File.delete(dest) if dest && File.exists?(dest)
  end

  it "reports changed without downloading under check_mode" do
    dest = File.tempname("get-url-spec")

    result = PluginSpecHelper.run("get_url", {"url" => "#{GET_URL_TEST_BASE}/file.txt", "dest" => dest, "_ansible_check_mode" => "true"})

    result["changed"].as_bool.must_equal(true)
    File.exists?(dest).must_equal(false)
  end

  it "fails clearly on a 404" do
    dest = File.tempname("get-url-spec")

    result = PluginSpecHelper.run("get_url", {"url" => "#{GET_URL_TEST_BASE}/missing.txt", "dest" => dest})

    result["failed"].as_bool.must_equal(true)
    File.exists?(dest).must_equal(false)
  end

  it "names a refused connect with urllib's own errno text" do
    # Live-verified against ansible-core 2.19.11: the msg for a refused
    # connect is urllib's URLError str(), "<urlopen error [Errno 111]
    # Connection refused>". krikri reported Crystal's connect wording
    # ("Error connecting to '127.0.0.1:<port>': Resource temporarily
    # unavailable") because Crystal 1.21.1's event loop raises the live
    # libc errno (EAGAIN) instead of the ECONNREFUSED the kernel recorded
    # (see PluginHelpers::SocketConnect).
    dest = File.tempname("get-url-spec")
    closed_server = TCPServer.new("127.0.0.1", 0)
    closed_port = closed_server.local_address.port
    closed_server.close

    result = PluginSpecHelper.run("get_url", {"url" => "http://127.0.0.1:#{closed_port}/x", "dest" => dest})

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_include("<urlopen error [Errno 111] Connection refused>")
    result["msg"].as_s.wont_include("Resource temporarily unavailable")
    File.exists?(dest).must_equal(false)
  ensure
    File.delete(dest) if dest && File.exists?(dest)
  end

  it "follows a redirect" do
    dest = File.tempname("get-url-spec")

    result = PluginSpecHelper.run("get_url", {"url" => "#{GET_URL_TEST_BASE}/redirect.txt", "dest" => dest})

    result["changed"].as_bool.must_equal(true)
    File.read(dest).must_equal(FILE_CONTENT)
  ensure
    File.delete(dest) if dest && File.exists?(dest)
  end

  it "names a directory-dest download after the redirect target, not the original URL path (Content-Disposition)" do
    # Real bug found benchmarking mrlesmithjr.guacamole (round 979121):
    # its download URL is apache.org/dyn/closer.cgi?action=download&...,
    # whose own path is just /dyn/closer.cgi. Real get_url derives a
    # directory-dest filename AFTER the request (final response's
    # Content-Disposition, else the FINAL post-redirect URL's basename);
    # krikri derived it up front from the original URL, landing the file
    # at <dir>/closer.cgi so the role's next unarchive task failed with
    # "Source ... failed to transfer" while real Ansible had already put
    # the tarball where unarchive expected it.
    dest_dir = File.join(File.tempname("get-url-spec"), "dl")
    Dir.mkdir_p(dest_dir)

    result = PluginSpecHelper.run("get_url", {
      "url"  => "#{GET_URL_TEST_BASE}/dyn/closer.cgi?action=download&filename=guac/1.0/source/pkg-1.0.tar.gz",
      "dest" => dest_dir,
    })

    result["changed"].as_bool.must_equal(true)
    falsey?(result["failed"]?.try(&.as_bool)).must_equal(true)
    result["dest"].as_s.must_equal(File.join(dest_dir, "pkg-1.0.tar.gz"))
    File.read(File.join(dest_dir, "pkg-1.0.tar.gz")).must_equal(FILE_CONTENT)
    File.exists?(File.join(dest_dir, "closer.cgi")).must_equal(false)
  ensure
    FileUtils.rm_rf(dest_dir) if dest_dir && Dir.exists?(dest_dir)
  end

  it "falls back to the final URL's basename for a directory dest when no Content-Disposition is sent" do
    dest_dir = File.join(File.tempname("get-url-spec"), "dl")
    Dir.mkdir_p(dest_dir)

    result = PluginSpecHelper.run("get_url", {"url" => "#{GET_URL_TEST_BASE}/bare-cgi", "dest" => dest_dir})

    result["changed"].as_bool.must_equal(true)
    falsey?(result["failed"]?.try(&.as_bool)).must_equal(true)
    result["dest"].as_s.must_equal(File.join(dest_dir, "pkg-1.0.tar.gz"))
    File.read(File.join(dest_dir, "pkg-1.0.tar.gz")).must_equal(FILE_CONTENT)
  ensure
    FileUtils.rm_rf(dest_dir) if dest_dir && Dir.exists?(dest_dir)
  end

  it "is idempotent on a directory-dest rerun (always re-requests, then content-compares the final dest)" do
    # Real get_url never short-circuits on a directory dest (its
    # dest-existence check is guarded by `not dest_is_dir` - the filename
    # isn't knowable before the request); idempotency comes from the
    # post-download SHA1 compare against the already-placed file.
    dest_dir = File.join(File.tempname("get-url-spec"), "dl")
    Dir.mkdir_p(dest_dir)
    File.write(File.join(dest_dir, "pkg-1.0.tar.gz"), FILE_CONTENT)

    result = PluginSpecHelper.run("get_url", {"url" => "#{GET_URL_TEST_BASE}/dyn/closer.cgi?filename=x", "dest" => dest_dir})

    result["changed"].as_bool.must_equal(false)
    falsey?(result["failed"]?.try(&.as_bool)).must_equal(true)
    File.exists?(File.join(dest_dir, "closer.cgi")).must_equal(false)
  ensure
    FileUtils.rm_rf(dest_dir) if dest_dir && Dir.exists?(dest_dir)
  end

  it "resolves a checksum URL by parsing the per-file hash from a sha256sums file" do
    # Real bug found benchmarking andrewrothstein.terraform (round 154 v3):
    # real Ansible's get_url documents checksum: as accepting a URL
    # pointing at a sha256sums-format file, not just a literal hash -
    # parse_checksum stored the URL string itself as the "expected" hash,
    # which could never match a real download.
    dest = File.tempname("get-url-spec")
    result = PluginSpecHelper.run("get_url", {
      "url" => "#{GET_URL_TEST_BASE}/file.txt", "dest" => dest, "checksum" => "sha256:#{GET_URL_TEST_BASE}/sha256sums.txt",
    })

    result["changed"].as_bool.must_equal(true)
    falsey?(result["failed"]?.try(&.as_bool)).must_equal(true)
    File.read(dest).must_equal(FILE_CONTENT)
  ensure
    File.delete(dest) if dest && File.exists?(dest)
  end

  it "resolves a checksum URL that holds only a bare hash, no filename at all" do
    # Real bug found benchmarking githubixx.kubectl's own "Download
    # kubectl binary" task: dl.k8s.io publishes one "<binary>.sha512"
    # file per binary containing NOTHING but the hex hash (no filename,
    # unlike the multi-file sha256sums format above) - real Ansible's
    # get_url accepts this shape directly. The sha*sums-style "<hash>
    # <filename>" parsing only ever matched a line with a filename
    # token to compare against, so a single bare-hash line never
    # matched anything and always raised "no checksum entry found",
    # even though the hash itself was right there on its own.
    dest = File.tempname("get-url-spec")
    result = PluginSpecHelper.run("get_url", {
      "url" => "#{GET_URL_TEST_BASE}/file.txt", "dest" => dest, "checksum" => "sha256:#{GET_URL_TEST_BASE}/file.txt.sha256-bare",
    })

    result["changed"].as_bool.must_equal(true)
    falsey?(result["failed"]?.try(&.as_bool)).must_equal(true)
    File.read(dest).must_equal(FILE_CONTENT)
  ensure
    File.delete(dest) if dest && File.exists?(dest)
  end

  it "fails when the checksum URL points to a sha256sums file with no matching entry" do
    dest = File.tempname("get-url-spec")
    result = PluginSpecHelper.run("get_url", {
      "url" => "#{GET_URL_TEST_BASE}/file.txt", "dest" => dest, "checksum" => "sha256:#{GET_URL_TEST_BASE}/sha256sums-no-match.txt",
    })

    result["failed"].as_bool.must_equal(true)
    File.exists?(dest).must_equal(false)
  ensure
    File.delete(dest) if dest && File.exists?(dest)
  end

  it "requires url and dest" do
    result = PluginSpecHelper.run("get_url", {"dest" => "/tmp/whatever"})
    result["failed"].as_bool.must_equal(true)

    result = PluginSpecHelper.run("get_url", {"url" => "#{GET_URL_TEST_BASE}/file.txt"})
    result["failed"].as_bool.must_equal(true)
  end

  it "retries basic auth on a 401 challenge when force_basic_auth is unset (the default)" do
    # Real get_url's force_basic_auth default is false: the first request
    # goes out WITHOUT Authorization and one retry is made WITH it on a
    # 401 challenge (urllib's HTTPBasicAuthHandler) - previously this
    # plugin always sent the header up front instead (mirroring the
    # force_basic_auth: true flow).
    dest = File.tempname("get-url-spec")
    result = PluginSpecHelper.run("get_url", {
      "url" => "#{GET_URL_TEST_BASE}/auth.txt", "dest" => dest,
      "url_username" => "u1", "url_password" => "p1",
    })

    result["changed"].as_bool.must_equal(true)
    falsey?(result["failed"]?.try(&.as_bool)).must_equal(true)
    File.read(dest).must_equal("secret-authed")
  ensure
    File.delete(dest) if dest && File.exists?(dest)
  end

  it "sends Basic auth on the first request when force_basic_auth is true" do
    dest = File.tempname("get-url-spec")
    result = PluginSpecHelper.run("get_url", {
      "url" => "#{GET_URL_TEST_BASE}/echo-auth.txt", "dest" => dest,
      "url_username" => "u1", "url_password" => "p1", "force_basic_auth" => "true",
    })

    result["changed"].as_bool.must_equal(true)
    File.read(dest).must_equal("Basic " + Base64.strict_encode("u1:p1"))
  ensure
    File.delete(dest) if dest && File.exists?(dest)
  end

  it "fails with a 401 when the credentials are wrong" do
    dest = File.tempname("get-url-spec")
    result = PluginSpecHelper.run("get_url", {
      "url" => "#{GET_URL_TEST_BASE}/auth.txt", "dest" => dest,
      "url_username" => "u1", "url_password" => "WRONG",
    })

    result["failed"].as_bool.must_equal(true)
    File.exists?(dest).must_equal(false)
  ensure
    File.delete(dest) if dest && File.exists?(dest)
  end

  it "requests identity encoding when decompress is false" do
    # decompress: false (real get_url's decompress param, default true)
    # must suppress the transparent gzip negotiation: the file gets
    # exactly the bytes the server meant to send. The /gz.txt endpoint
    # gzips only when the client offered gzip, so an identity request
    # comes back un-gzipped on the wire.
    dest = File.tempname("get-url-spec")
    result = PluginSpecHelper.run("get_url", {
      "url" => "#{GET_URL_TEST_BASE}/gz.txt", "dest" => dest, "decompress" => "false",
    })

    result["changed"].as_bool.must_equal(true)
    File.read(dest).must_equal("gzip-body-here")
  ensure
    File.delete(dest) if dest && File.exists?(dest)
  end

  it "transparently decompresses a gzip response by default (decompress unset)" do
    dest = File.tempname("get-url-spec")
    result = PluginSpecHelper.run("get_url", {"url" => "#{GET_URL_TEST_BASE}/gz.txt", "dest" => dest})

    result["changed"].as_bool.must_equal(true)
    File.read(dest).must_equal("gzip-body-here")
  ensure
    File.delete(dest) if dest && File.exists?(dest)
  end

  it "drops unredirected_headers after a redirect hop" do
    dest = File.tempname("get-url-spec")
    result = PluginSpecHelper.run("get_url", {
      "url" => "#{GET_URL_TEST_BASE}/redirect-auth.txt", "dest" => dest,
      "headers" => %({"Authorization": "Bearer token"}),
      "unredirected_headers" => %(["Authorization"]),
    })

    result["changed"].as_bool.must_equal(true)
    File.read(dest).must_equal("no-auth-header")
  ensure
    File.delete(dest) if dest && File.exists?(dest)
  end

  it "carries ordinary headers across a redirect hop by default" do
    dest = File.tempname("get-url-spec")
    result = PluginSpecHelper.run("get_url", {
      "url" => "#{GET_URL_TEST_BASE}/redirect-auth.txt", "dest" => dest,
      "headers" => %({"Authorization": "Bearer token"}),
    })

    result["changed"].as_bool.must_equal(true)
    File.read(dest).must_equal("Bearer token")
  ensure
    File.delete(dest) if dest && File.exists?(dest)
  end

  describe "tmp_dest:" do
    it "stages the download in the given directory" do
      staging = File.join(Dir.tempdir, "get-url-spec-staging-#{Random.rand(1_000_000)}")
      Dir.mkdir(staging)
      dest = File.tempname("get-url-spec")
      result = PluginSpecHelper.run("get_url", {
        "url" => "#{GET_URL_TEST_BASE}/file.txt", "dest" => dest, "tmp_dest" => staging,
      })

      result["changed"].as_bool.must_equal(true)
      falsey?(result["failed"]?.try(&.as_bool)).must_equal(true)
      File.read(dest).must_equal(FILE_CONTENT)
      Dir.children(staging).must_be_empty
    ensure
      FileUtils.rm_rf(staging) if staging
      File.delete(dest) if dest && File.exists?(dest)
    end

    it "fails with real Ansible's message when tmp_dest is a file" do
      tmp_file = File.tempname("get-url-spec-tmpdest")
      File.write(tmp_file, "x")
      dest = File.tempname("get-url-spec")
      result = PluginSpecHelper.run("get_url", {
        "url" => "#{GET_URL_TEST_BASE}/file.txt", "dest" => dest, "tmp_dest" => tmp_file,
      })

      result["failed"].as_bool.must_equal(true)
      result["msg"].as_s.must_equal("#{tmp_file} is a file but should be a directory.")
      File.exists?(dest).must_equal(false)
    ensure
      File.delete(tmp_file) if tmp_file && File.exists?(tmp_file)
      File.delete(dest) if dest && File.exists?(dest)
    end

    it "fails with real Ansible's message when tmp_dest does not exist" do
      missing = File.join(Dir.tempdir, "get-url-spec-missing-#{Random.rand(1_000_000)}")
      dest = File.tempname("get-url-spec")
      result = PluginSpecHelper.run("get_url", {
        "url" => "#{GET_URL_TEST_BASE}/file.txt", "dest" => dest, "tmp_dest" => missing,
      })

      result["failed"].as_bool.must_equal(true)
      result["msg"].as_s.must_equal("#{missing} directory does not exist.")
      File.exists?(dest).must_equal(false)
    ensure
      File.delete(dest) if dest && File.exists?(dest)
    end
  end

  it "writes normally when unsafe_writes is given but the atomic move succeeds (param has no effect on a normal filesystem)" do
    dest = File.tempname("get-url-spec")
    result = PluginSpecHelper.run("get_url", {
      "url" => "#{GET_URL_TEST_BASE}/file.txt", "dest" => dest, "unsafe_writes" => "true",
    })

    result["changed"].as_bool.must_equal(true)
    falsey?(result["failed"]?.try(&.as_bool)).must_equal(true)
    File.read(dest).must_equal(FILE_CONTENT)
  ensure
    File.delete(dest) if dest && File.exists?(dest)
  end

  it "reconciles stale mode on the skip path and reports changed like real Ansible" do
    # Real get_url runs set_fs_attributes_if_different even when the
    # download is skipped (no force, checksum matches), and a stale
    # file-common attribute flips the result to changed: true with msg
    # "file already exists but file attributes changed" - previously the
    # skip path applied mode/owner/group silently and always reported
    # changed: false, and owner: was its only reconciliation (no chattr
    # flags, no SELinux context).
    dest = File.tempname("get-url-spec")
    File.write(dest, FILE_CONTENT)
    File.chmod(dest, 0o644)

    result = PluginSpecHelper.run("get_url", {
      "url" => "#{GET_URL_TEST_BASE}/file.txt", "dest" => dest,
      "checksum" => "sha256:#{FILE_CHECKSUM}", "mode" => "0600",
    })

    result["changed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal("file already exists but file attributes changed")
    (File.info(dest).permissions.value & 0o777).must_equal(0o600)
  ensure
    File.delete(dest) if dest && File.exists?(dest)
  end

  it "reports changed: false on the skip path when the file-common attributes are already correct" do
    dest = File.tempname("get-url-spec")
    File.write(dest, FILE_CONTENT)
    File.chmod(dest, 0o600)

    result = PluginSpecHelper.run("get_url", {
      "url" => "#{GET_URL_TEST_BASE}/file.txt", "dest" => dest,
      "checksum" => "sha256:#{FILE_CHECKSUM}", "mode" => "0600",
    })

    result["changed"].as_bool.must_equal(false)
    File.read(dest).must_equal(FILE_CONTENT)
  ensure
    File.delete(dest) if dest && File.exists?(dest)
  end

  it "accepts '-'-prefixed attributes: (chattr flags) and reports changed like real Ansible's set_attributes_if_different" do
    # Mirrors lineinfile_spec.cr's own attributes: spec (real Ansible
    # reports changed unconditionally for '-'-prefixed requests,
    # ansible/ansible#33745). The dest lands on the default tempdir,
    # which rootless fuse-overlayfs containers back with a filesystem
    # that rejects every chattr flag op (real Ansible fails the task
    # there identically) - skip the success-path pin on such a fs.
    skip "filesystem rejects chattr flag operations" unless PluginSpecHelper.chattr_clear_supported?
    dest = File.tempname("get-url-spec")
    File.write(dest, FILE_CONTENT)

    result = PluginSpecHelper.run("get_url", {
      "url" => "#{GET_URL_TEST_BASE}/file.txt", "dest" => dest, "attributes" => "-i",
    })

    falsey?(result["failed"]?.try(&.as_bool)).must_equal(true)
    result["changed"].as_bool.must_equal(true)

    warm = PluginSpecHelper.run("get_url", {
      "url" => "#{GET_URL_TEST_BASE}/file.txt", "dest" => dest, "attributes" => "-i",
    })
    falsey?(warm["failed"]?.try(&.as_bool)).must_equal(true)
    warm["changed"].as_bool.must_equal(true)
  ensure
    File.delete(dest) if dest && File.exists?(dest)
  end

  it "accepts the SELinux context params as a no-op on a non-SELinux host (real Ansible skips chcon entirely there)" do
    dest = File.tempname("get-url-spec")
    result = PluginSpecHelper.run("get_url", {
      "url" => "#{GET_URL_TEST_BASE}/file.txt", "dest" => dest,
      "seuser" => "system_u", "serole" => "object_r", "setype" => "etc_t", "selevel" => "s0",
    })

    result["changed"].as_bool.must_equal(true)
    falsey?(result["failed"]?.try(&.as_bool)).must_equal(true)
    File.read(dest).must_equal(FILE_CONTENT)
  ensure
    File.delete(dest) if dest && File.exists?(dest)
  end

  it "copies a file:// URL like real Ansible's local-file handler, with full result metadata" do
    # Found via an ad-hoc CLI comparison sweep against real ansible
    # (2026-09-13): `ansible -m get_url -a "url=file:///etc/hostname
    # dest=/tmp/x"` succeeds and returns full stat metadata, while
    # krikri previously failed with "Unsupported scheme: file".
    src = File.tempname("get-url-spec-src")
    dest = File.tempname("get-url-spec")
    File.write(src, FILE_CONTENT)

    result = PluginSpecHelper.run("get_url", {"url" => "file://#{src}", "dest" => dest})

    result["changed"].as_bool.must_equal(true)
    falsey?(result["failed"]?.try(&.as_bool)).must_equal(true)
    File.read(dest).must_equal(FILE_CONTENT)
    %w(checksum_src dest gid group md5sum mode owner size state uid url).each do |key|
      result[key]?.wont_be_nil("expected #{key} in result (real Ansible's file:// get_url returns full stat metadata)")
    end
    result["size"].as_i.must_equal(FILE_CONTENT.size)
    result["state"].as_s.must_equal("file")
  ensure
    File.delete(src) if src && File.exists?(src)
    File.delete(dest) if dest && File.exists?(dest)
  end

  it "is idempotent on a second file:// run (changed: false without force)" do
    src = File.tempname("get-url-spec-src")
    dest = File.tempname("get-url-spec")
    File.write(src, FILE_CONTENT)
    File.write(dest, FILE_CONTENT)

    result = PluginSpecHelper.run("get_url", {"url" => "file://#{src}", "dest" => dest})

    result["changed"].as_bool.must_equal(false)
    falsey?(result["failed"]?.try(&.as_bool)).must_equal(true)
  ensure
    File.delete(src) if src && File.exists?(src)
    File.delete(dest) if dest && File.exists?(dest)
  end

  it "is idempotent on a second file:// run with force: true (content-compare, like the HTTP path)" do
    src = File.tempname("get-url-spec-src")
    dest = File.tempname("get-url-spec")
    File.write(src, FILE_CONTENT)
    File.write(dest, FILE_CONTENT)

    result = PluginSpecHelper.run("get_url", {"url" => "file://#{src}", "dest" => dest, "force" => "true"})

    result["changed"].as_bool.must_equal(false)
    falsey?(result["failed"]?.try(&.as_bool)).must_equal(true)
  ensure
    File.delete(src) if src && File.exists?(src)
    File.delete(dest) if dest && File.exists?(dest)
  end

  it "fails a file:// URL whose local source does not exist" do
    src = "#{File.tempname("get-url-spec-missing")}.never-created"
    dest = File.tempname("get-url-spec")

    result = PluginSpecHelper.run("get_url", {"url" => "file://#{src}", "dest" => dest})

    result["failed"].as_bool.must_equal(true)
    result["status_code"].as_i.must_equal(-1)
    File.exists?(dest).must_equal(false)
  ensure
    File.delete(dest) if dest && File.exists?(dest)
  end

  # Real Ansible builds the request's SSL context BEFORE urllib parses the
  # URL (module_utils/urls.py's Request.open: _configure_auth ->
  # make_context -> urllib.request.Request), so these failures happen with
  # no request at all - over a plain http:// URL, not only a broken one.
  # Every expectation here live-verified against ansible-core 2.19.11.
  describe "pre-request failures (real fetch_url's own handlers)" do
    it "fails a ciphers list that selects nothing, before any request" do
      dest = File.tempname("get-url-spec")
      result = PluginSpecHelper.run("get_url", {
        "url" => "#{GET_URL_TEST_BASE}/file.txt", "dest" => dest,
        "ciphers" => %(["fdpfji", "ahatju"]),
      })

      result["failed"].as_bool.must_equal(true)
      result["msg"].as_s.must_equal("Connection failure: ('No cipher can be selected.',)")
      result["url"].as_s.must_equal("#{GET_URL_TEST_BASE}/file.txt")
      result["dest"].as_s.must_equal(dest)
      result["elapsed"].as_i.must_equal(0)
      # status_code belongs to the OTHER get_url failure (its non-200
      # "Request failed" branch), not to this one.
      result["status_code"]?.must_be_nil
      File.exists?(dest).must_equal(false)
    ensure
      File.delete(dest) if dest && File.exists?(dest)
    end

    it "accepts a ciphers list that selects something" do
      dest = File.tempname("get-url-spec")
      result = PluginSpecHelper.run("get_url", {
        "url" => "#{GET_URL_TEST_BASE}/file.txt", "dest" => dest,
        "ciphers" => %(["ECDHE-RSA-AES256-GCM-SHA384"]),
      })

      falsey?(result["failed"]?.try(&.as_bool)).must_equal(true)
      result["dest"].as_s.must_equal(dest)
    ensure
      File.delete(dest) if dest && File.exists?(dest)
    end

    it "fails an unreadable client_cert with real's OSError wording" do
      dest = File.tempname("get-url-spec")
      missing = PluginSpecHelper.tmp_path("no-such-client-cert-#{Random::Secure.hex(4)}.pem")
      result = PluginSpecHelper.run("get_url", {
        "url" => "#{GET_URL_TEST_BASE}/file.txt", "dest" => dest, "client_cert" => missing,
      })

      result["msg"].as_s.must_equal("Connection failure: [Errno 2] No such file or directory")
      result["dest"].as_s.must_equal(dest)
      File.exists?(dest).must_equal(false)
    ensure
      File.delete(dest) if dest && File.exists?(dest)
    end

    it "fails a client_cert that is a directory the way real's open() does" do
      dest = File.tempname("get-url-spec")
      result = PluginSpecHelper.run("get_url", {
        "url" => "#{GET_URL_TEST_BASE}/file.txt", "dest" => dest, "client_cert" => PluginSpecHelper.tmp_path("."),
      })

      result["msg"].as_s.must_equal("Connection failure: [Errno 21] Is a directory")
    ensure
      File.delete(dest) if dest && File.exists?(dest)
    end

    it "ignores a client_key that has no client_cert (real never opens it)" do
      # make_context only calls load_cert_chain - the one call that reads
      # the keyfile - when client_cert is set.
      dest = File.tempname("get-url-spec")
      missing = PluginSpecHelper.tmp_path("no-such-client-key-#{Random::Secure.hex(4)}.pem")
      result = PluginSpecHelper.run("get_url", {
        "url" => "#{GET_URL_TEST_BASE}/file.txt", "dest" => dest, "client_key" => missing,
      })

      falsey?(result["failed"]?.try(&.as_bool)).must_equal(true)
      result["dest"].as_s.must_equal(dest)
    ensure
      File.delete(dest) if dest && File.exists?(dest)
    end

    it "reports the cipher failure ahead of a scheme-less URL's own error" do
      dest = File.tempname("get-url-spec")
      result = PluginSpecHelper.run("get_url", {
        "url" => "wezwmn", "dest" => dest, "ciphers" => %(["fdpfji"]),
      })

      result["msg"].as_s.must_equal("Connection failure: ('No cipher can be selected.',)")
    ensure
      File.delete(dest) if dest && File.exists?(dest)
    end

    it "skips the request - and the preflight - for a dest that matches its checksum" do
      # get_url.py only short-circuits on an existing dest when a checksum
      # was given and matches, and that happens before url_get/fetch_url:
      # live-verified that this task is ok even with a ciphers list that
      # could not possibly have connected.
      dest = PluginSpecHelper.tmp_path("checksum-skip-#{Random::Secure.hex(4)}.txt")
      File.write(dest, FILE_CONTENT)
      digest = OpenSSL::Digest.new("SHA256")
      digest.update(FILE_CONTENT)

      result = PluginSpecHelper.run("get_url", {
        "url" => "wezwmn", "dest" => dest, "checksum" => "sha256:#{digest.final.hexstring}",
        "ciphers" => %(["fdpfji"]),
      })

      falsey?(result["failed"]?.try(&.as_bool)).must_equal(true)
      result["msg"].as_s.must_equal("file already exists")
    ensure
      File.delete(dest) if dest && File.exists?(dest)
    end
  end
end
