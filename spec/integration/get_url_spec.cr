require "../spec_helper"
require "http/server"
require "openssl/digest"
require "base64"
require "compress/gzip"
require "file_utils"

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

get_url_test_server = HTTP::Server.new do |context|
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
get_url_test_address = get_url_test_server.bind_unused_port
spawn { get_url_test_server.listen }
Fiber.yield

get_url_base = "http://#{get_url_test_address}"

describe "get_url plugin" do
  it "downloads a new file" do
    dest = File.tempname("get-url-spec")
    result = PluginSpecHelper.run("get_url", {"url" => "#{get_url_base}/file.txt", "dest" => dest})

    result["changed"].as_bool.should be_true
    result["failed"].as_bool.should be_false
    File.read(dest).should eq(FILE_CONTENT)
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
    result = PluginSpecHelper.run("get_url", {"url" => "#{get_url_base}/echo-headers.txt", "dest" => dest, "headers" => "{}"})

    result["changed"].as_bool.should be_true
    result["failed"].as_bool.should be_false
    File.read(dest).should eq("no-custom-header")
  ensure
    File.delete(dest) if dest && File.exists?(dest)
  end

  it "sends a populated dict's own key/value pairs as real headers" do
    dest = File.tempname("get-url-spec")
    result = PluginSpecHelper.run("get_url", {"url" => "#{get_url_base}/echo-headers.txt", "dest" => dest, "headers" => %({"X-Custom":"hello"})})

    result["changed"].as_bool.should be_true
    result["failed"].as_bool.should be_false
    File.read(dest).should eq("hello")
  ensure
    File.delete(dest) if dest && File.exists?(dest)
  end

  it "still supports the comma-separated string form (key:value,key2:value2)" do
    dest = File.tempname("get-url-spec")
    result = PluginSpecHelper.run("get_url", {"url" => "#{get_url_base}/echo-headers.txt", "dest" => dest, "headers" => "X-Custom:legacy-form"})

    result["changed"].as_bool.should be_true
    result["failed"].as_bool.should be_false
    File.read(dest).should eq("legacy-form")
  ensure
    File.delete(dest) if dest && File.exists?(dest)
  end

  it "verifies checksum and reports mismatch as a failure without touching dest" do
    dest = File.tempname("get-url-spec")
    result = PluginSpecHelper.run("get_url", {
      "url" => "#{get_url_base}/file.txt", "dest" => dest, "checksum" => "sha256:0000000000000000000000000000000000000000000000000000000000000000",
    })

    result["failed"].as_bool.should be_true
    File.exists?(dest).should be_false
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
    result = PluginSpecHelper.run("get_url", {"url" => "#{get_url_base}/file.txt", "dest" => dest, "checksum" => ""})

    result["changed"].as_bool.should be_true
    result["failed"].as_bool.should be_false
    File.read(dest).should eq(FILE_CONTENT)
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
      "url" => "#{get_url_base}/file.txt", "dest" => dest, "checksum" => "sha384:#{FILE_CHECKSUM_SHA384}",
    })

    result["changed"].as_bool.should be_true
    result["failed"].as_bool.should be_false
    File.read(dest).should eq(FILE_CONTENT)
  ensure
    File.delete(dest) if dest && File.exists?(dest)
  end

  it "is idempotent when dest exists and checksum matches" do
    dest = File.tempname("get-url-spec")
    File.write(dest, FILE_CONTENT)

    result = PluginSpecHelper.run("get_url", {
      "url" => "#{get_url_base}/file.txt", "dest" => dest, "checksum" => "sha256:#{FILE_CHECKSUM}",
    })

    result["changed"].as_bool.should be_false
    result["failed"].as_bool.should be_false
  ensure
    File.delete(dest) if dest && File.exists?(dest)
  end

  it "skips an existing dest without force and without checksum" do
    dest = File.tempname("get-url-spec")
    File.write(dest, "pre-existing, untouched")

    result = PluginSpecHelper.run("get_url", {"url" => "#{get_url_base}/file.txt", "dest" => dest})

    result["changed"].as_bool.should be_false
    File.read(dest).should eq("pre-existing, untouched")
  ensure
    File.delete(dest) if dest && File.exists?(dest)
  end

  it "overwrites an existing dest when force is given" do
    dest = File.tempname("get-url-spec")
    File.write(dest, "stale content")

    result = PluginSpecHelper.run("get_url", {"url" => "#{get_url_base}/file.txt", "dest" => dest, "force" => "yes"})

    result["changed"].as_bool.should be_true
    File.read(dest).should eq(FILE_CONTENT)
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

    result = PluginSpecHelper.run("get_url", {"url" => "#{get_url_base}/file.txt", "dest" => dest, "force" => "yes"})

    result["changed"].as_bool.should be_false
    result["failed"].as_bool.should be_false
    File.read(dest).should eq(FILE_CONTENT)
  ensure
    File.delete(dest) if dest && File.exists?(dest)
  end

  it "reports changed without downloading under check_mode" do
    dest = File.tempname("get-url-spec")

    result = PluginSpecHelper.run("get_url", {"url" => "#{get_url_base}/file.txt", "dest" => dest, "check_mode" => "true"})

    result["changed"].as_bool.should be_true
    File.exists?(dest).should be_false
  end

  it "fails clearly on a 404" do
    dest = File.tempname("get-url-spec")

    result = PluginSpecHelper.run("get_url", {"url" => "#{get_url_base}/missing.txt", "dest" => dest})

    result["failed"].as_bool.should be_true
    File.exists?(dest).should be_false
  end

  it "follows a redirect" do
    dest = File.tempname("get-url-spec")

    result = PluginSpecHelper.run("get_url", {"url" => "#{get_url_base}/redirect.txt", "dest" => dest})

    result["changed"].as_bool.should be_true
    File.read(dest).should eq(FILE_CONTENT)
  ensure
    File.delete(dest) if dest && File.exists?(dest)
  end

  it "resolves a checksum URL by parsing the per-file hash from a sha256sums file" do
    # Real bug found benchmarking andrewrothstein.terraform (round 154 v3):
    # real Ansible's get_url documents checksum: as accepting a URL
    # pointing at a sha256sums-format file, not just a literal hash -
    # parse_checksum stored the URL string itself as the "expected" hash,
    # which could never match a real download.
    dest = File.tempname("get-url-spec")
    result = PluginSpecHelper.run("get_url", {
      "url" => "#{get_url_base}/file.txt", "dest" => dest, "checksum" => "sha256:#{get_url_base}/sha256sums.txt",
    })

    result["changed"].as_bool.should be_true
    result["failed"].as_bool.should be_false
    File.read(dest).should eq(FILE_CONTENT)
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
      "url" => "#{get_url_base}/file.txt", "dest" => dest, "checksum" => "sha256:#{get_url_base}/file.txt.sha256-bare",
    })

    result["changed"].as_bool.should be_true
    result["failed"].as_bool.should be_false
    File.read(dest).should eq(FILE_CONTENT)
  ensure
    File.delete(dest) if dest && File.exists?(dest)
  end

  it "fails when the checksum URL points to a sha256sums file with no matching entry" do
    dest = File.tempname("get-url-spec")
    result = PluginSpecHelper.run("get_url", {
      "url" => "#{get_url_base}/file.txt", "dest" => dest, "checksum" => "sha256:#{get_url_base}/sha256sums-no-match.txt",
    })

    result["failed"].as_bool.should be_true
    File.exists?(dest).should be_false
  ensure
    File.delete(dest) if dest && File.exists?(dest)
  end

  it "requires url and dest" do
    result = PluginSpecHelper.run("get_url", {"dest" => "/tmp/whatever"})
    result["failed"].as_bool.should be_true

    result = PluginSpecHelper.run("get_url", {"url" => "#{get_url_base}/file.txt"})
    result["failed"].as_bool.should be_true
  end

  it "retries basic auth on a 401 challenge when force_basic_auth is unset (the default)" do
    # Real get_url's force_basic_auth default is false: the first request
    # goes out WITHOUT Authorization and one retry is made WITH it on a
    # 401 challenge (urllib's HTTPBasicAuthHandler) - previously this
    # plugin always sent the header up front instead (mirroring the
    # force_basic_auth: true flow).
    dest = File.tempname("get-url-spec")
    result = PluginSpecHelper.run("get_url", {
      "url" => "#{get_url_base}/auth.txt", "dest" => dest,
      "url_username" => "u1", "url_password" => "p1",
    })

    result["changed"].as_bool.should be_true
    result["failed"].as_bool.should be_false
    File.read(dest).should eq("secret-authed")
  ensure
    File.delete(dest) if dest && File.exists?(dest)
  end

  it "sends Basic auth on the first request when force_basic_auth is true" do
    dest = File.tempname("get-url-spec")
    result = PluginSpecHelper.run("get_url", {
      "url" => "#{get_url_base}/echo-auth.txt", "dest" => dest,
      "url_username" => "u1", "url_password" => "p1", "force_basic_auth" => "true",
    })

    result["changed"].as_bool.should be_true
    File.read(dest).should eq("Basic " + Base64.strict_encode("u1:p1"))
  ensure
    File.delete(dest) if dest && File.exists?(dest)
  end

  it "fails with a 401 when the credentials are wrong" do
    dest = File.tempname("get-url-spec")
    result = PluginSpecHelper.run("get_url", {
      "url" => "#{get_url_base}/auth.txt", "dest" => dest,
      "url_username" => "u1", "url_password" => "WRONG",
    })

    result["failed"].as_bool.should be_true
    File.exists?(dest).should be_false
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
      "url" => "#{get_url_base}/gz.txt", "dest" => dest, "decompress" => "false",
    })

    result["changed"].as_bool.should be_true
    File.read(dest).should eq("gzip-body-here")
  ensure
    File.delete(dest) if dest && File.exists?(dest)
  end

  it "transparently decompresses a gzip response by default (decompress unset)" do
    dest = File.tempname("get-url-spec")
    result = PluginSpecHelper.run("get_url", {"url" => "#{get_url_base}/gz.txt", "dest" => dest})

    result["changed"].as_bool.should be_true
    File.read(dest).should eq("gzip-body-here")
  ensure
    File.delete(dest) if dest && File.exists?(dest)
  end

  it "drops unredirected_headers after a redirect hop" do
    dest = File.tempname("get-url-spec")
    result = PluginSpecHelper.run("get_url", {
      "url" => "#{get_url_base}/redirect-auth.txt", "dest" => dest,
      "headers" => %({"Authorization": "Bearer token"}),
      "unredirected_headers" => %(["Authorization"]),
    })

    result["changed"].as_bool.should be_true
    File.read(dest).should eq("no-auth-header")
  ensure
    File.delete(dest) if dest && File.exists?(dest)
  end

  it "carries ordinary headers across a redirect hop by default" do
    dest = File.tempname("get-url-spec")
    result = PluginSpecHelper.run("get_url", {
      "url" => "#{get_url_base}/redirect-auth.txt", "dest" => dest,
      "headers" => %({"Authorization": "Bearer token"}),
    })

    result["changed"].as_bool.should be_true
    File.read(dest).should eq("Bearer token")
  ensure
    File.delete(dest) if dest && File.exists?(dest)
  end

  describe "tmp_dest:" do
    it "stages the download in the given directory" do
      staging = File.join(Dir.tempdir, "get-url-spec-staging-#{Random.rand(1_000_000)}")
      Dir.mkdir(staging)
      dest = File.tempname("get-url-spec")
      result = PluginSpecHelper.run("get_url", {
        "url" => "#{get_url_base}/file.txt", "dest" => dest, "tmp_dest" => staging,
      })

      result["changed"].as_bool.should be_true
      result["failed"].as_bool.should be_false
      File.read(dest).should eq(FILE_CONTENT)
      Dir.children(staging).should be_empty
    ensure
      FileUtils.rm_rf(staging) if staging
      File.delete(dest) if dest && File.exists?(dest)
    end

    it "fails with real Ansible's message when tmp_dest is a file" do
      tmp_file = File.tempname("get-url-spec-tmpdest")
      File.write(tmp_file, "x")
      dest = File.tempname("get-url-spec")
      result = PluginSpecHelper.run("get_url", {
        "url" => "#{get_url_base}/file.txt", "dest" => dest, "tmp_dest" => tmp_file,
      })

      result["failed"].as_bool.should be_true
      result["msg"].as_s.should eq("#{tmp_file} is a file but should be a directory.")
      File.exists?(dest).should be_false
    ensure
      File.delete(tmp_file) if tmp_file && File.exists?(tmp_file)
      File.delete(dest) if dest && File.exists?(dest)
    end

    it "fails with real Ansible's message when tmp_dest does not exist" do
      missing = File.join(Dir.tempdir, "get-url-spec-missing-#{Random.rand(1_000_000)}")
      dest = File.tempname("get-url-spec")
      result = PluginSpecHelper.run("get_url", {
        "url" => "#{get_url_base}/file.txt", "dest" => dest, "tmp_dest" => missing,
      })

      result["failed"].as_bool.should be_true
      result["msg"].as_s.should eq("#{missing} directory does not exist.")
      File.exists?(dest).should be_false
    ensure
      File.delete(dest) if dest && File.exists?(dest)
    end
  end

  it "writes normally when unsafe_writes is given but the atomic move succeeds (param has no effect on a normal filesystem)" do
    dest = File.tempname("get-url-spec")
    result = PluginSpecHelper.run("get_url", {
      "url" => "#{get_url_base}/file.txt", "dest" => dest, "unsafe_writes" => "true",
    })

    result["changed"].as_bool.should be_true
    result["failed"].as_bool.should be_false
    File.read(dest).should eq(FILE_CONTENT)
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
      "url" => "#{get_url_base}/file.txt", "dest" => dest,
      "checksum" => "sha256:#{FILE_CHECKSUM}", "mode" => "0600",
    })

    result["changed"].as_bool.should be_true
    result["msg"].as_s.should eq("file already exists but file attributes changed")
    (File.info(dest).permissions.value & 0o777).should eq(0o600)
  ensure
    File.delete(dest) if dest && File.exists?(dest)
  end

  it "reports changed: false on the skip path when the file-common attributes are already correct" do
    dest = File.tempname("get-url-spec")
    File.write(dest, FILE_CONTENT)
    File.chmod(dest, 0o600)

    result = PluginSpecHelper.run("get_url", {
      "url" => "#{get_url_base}/file.txt", "dest" => dest,
      "checksum" => "sha256:#{FILE_CHECKSUM}", "mode" => "0600",
    })

    result["changed"].as_bool.should be_false
    File.read(dest).should eq(FILE_CONTENT)
  ensure
    File.delete(dest) if dest && File.exists?(dest)
  end

  it "accepts '-'-prefixed attributes: (chattr flags) and reports changed like real Ansible's set_attributes_if_different" do
    # Mirrors lineinfile_spec.cr's own attributes: spec (real Ansible
    # reports changed unconditionally for '-'-prefixed requests,
    # ansible/ansible#33745).
    dest = File.tempname("get-url-spec")
    File.write(dest, FILE_CONTENT)

    result = PluginSpecHelper.run("get_url", {
      "url" => "#{get_url_base}/file.txt", "dest" => dest, "attributes" => "-i",
    })

    result["failed"].as_bool.should be_falsey
    result["changed"].as_bool.should be_true

    warm = PluginSpecHelper.run("get_url", {
      "url" => "#{get_url_base}/file.txt", "dest" => dest, "attributes" => "-i",
    })
    warm["failed"].as_bool.should be_falsey
    warm["changed"].as_bool.should be_true
  ensure
    File.delete(dest) if dest && File.exists?(dest)
  end

  it "accepts the SELinux context params as a no-op on a non-SELinux host (real Ansible skips chcon entirely there)" do
    dest = File.tempname("get-url-spec")
    result = PluginSpecHelper.run("get_url", {
      "url" => "#{get_url_base}/file.txt", "dest" => dest,
      "seuser" => "system_u", "serole" => "object_r", "setype" => "etc_t", "selevel" => "s0",
    })

    result["changed"].as_bool.should be_true
    result["failed"].as_bool.should be_false
    File.read(dest).should eq(FILE_CONTENT)
  ensure
    File.delete(dest) if dest && File.exists?(dest)
  end
end
