require "../minitest_helper"
require "http/server"
require "base64"
require "compress/gzip"
require "file_utils"
require "../../src/krikri/param_sentinels"

# A tiny local HTTP server exercising GET/POST/redirect/JSON/plain-text
# responses, started once for the whole file.
#
# The /ims-* routes are a SimpleHTTPRequestHandler-style conditional-GET
# server (304 when If-Modified-Since >= the fixture file's mtime) so the
# dest: idempotency specs need no internet; /echo-ims reports the wire
# headers those specs assert on.
#
# /ims-flip serves the same conditional-GET behavior from its OWN fixture
# so the one spec that needs to move a server file's mtime forward (the
# re-download spec) never mutates a fixture other specs read: IMS_OLD is
# shared by every 304-expecting spec, and under -p N a concurrent warm
# run against it would see the 2030 mtime and get a 200 instead.
IMS_OLD  = File.join(Dir.tempdir, "uri-spec-ims-old-#{Random::Secure.hex(4)}.asc")
IMS_NEW  = File.join(Dir.tempdir, "uri-spec-ims-new-#{Random::Secure.hex(4)}.asc")
IMS_FLIP = File.join(Dir.tempdir, "uri-spec-ims-flip-#{Random::Secure.hex(4)}.asc")
File.write(IMS_OLD, "ims-body")
File.write(IMS_NEW, "ims-body-v2")
File.write(IMS_FLIP, "ims-body")
File.touch(IMS_OLD, time: Time.utc(2020, 1, 1, 0, 0, 0))
File.touch(IMS_NEW, time: Time.utc(2030, 1, 1, 0, 0, 0))
File.touch(IMS_FLIP, time: Time.utc(2020, 1, 1, 0, 0, 0))

URI_TEST_SERVER = HTTP::Server.new do |context|
  request = context.request
  response = context.response

  # Echoes the request headers roles most commonly probe for, so specs
  # can assert what the plugin actually put on the wire.
  if request.method == "GET" && request.path == "/echo-headers"
    picked = {"authorization" => request.headers["Authorization"]?, "cache_control" => request.headers["Cache-Control"]?, "accept_encoding" => request.headers["Accept-Encoding"]?, "user_agent" => request.headers["User-Agent"]?}
    response.status_code = 200
    response.headers["Content-Type"] = "application/json"
    response.print(picked.to_json)
  elsif request.method == "GET" && request.path == "/auth"
    if request.headers["Authorization"]? == "Basic " + Base64.strict_encode("u1:p1")
      response.status_code = 200
      response.headers["Content-Type"] = "text/plain"
      response.print("secret-authed")
    else
      response.status_code = 401
      response.headers["WWW-Authenticate"] = "Basic realm=\"x\""
      response.print("denied")
    end
  elsif request.method == "GET" && request.path == "/redirect-auth"
    response.status_code = 302
    response.headers["Location"] = "/echo-headers"
  elsif request.method == "GET" && request.path == "/gz"
    body = "gzip-body-here"
    if request.headers["Accept-Encoding"]?.try(&.includes?("gzip"))
      response.status_code = 200
      response.headers["Content-Type"] = "text/plain"
      response.headers["Content-Encoding"] = "gzip"
      io = IO::Memory.new
      Compress::Gzip::Writer.open(io, &.print(body))
      response.print(io.to_s)
    else
      response.status_code = 200
      response.headers["Content-Type"] = "text/plain"
      response.print(body)
    end
  elsif {"GET", "/disp"} == {request.method, request.path}
    response.status_code = 200
    response.headers["Content-Type"] = "text/plain"
    response.headers["Content-Disposition"] = "attachment; filename=\"dl-1.2.3.tar.gz\""
    response.print("file-content")
  elsif request.method == "POST" && request.path == "/src"
    body = request.body.try(&.gets_to_end) || ""
    response.status_code = 200
    response.headers["Content-Type"] = "text/plain"
    response.print("got:" + body)
  elsif request.method == "GET" && request.path == "/filecontent"
    response.status_code = 200
    response.headers["Content-Type"] = "text/plain"
    response.print("plain text body")
  elsif request.method == "GET" && request.path.in?("/ims-old", "/ims-new", "/ims-flip")
    file = case request.path
           when "/ims-new"  then IMS_NEW
           when "/ims-flip" then IMS_FLIP
           else                  IMS_OLD
           end
    mtime = File.info(file).modification_time
    ims_header = request.headers["If-Modified-Since"]?
    sent = ims_header.try do |header|
      begin
        Time::Format::HTTP_DATE.parse(header)
      rescue Time::Format::Error
        nil
      end
    end
    if sent && sent.to_unix >= mtime.to_unix
      response.status_code = 304
    else
      response.status_code = 200
      response.headers["Content-Type"] = "text/plain"
      response.headers["Last-Modified"] = Time::Format::HTTP_DATE.format(mtime)
      response.print(File.read(file))
    end
  elsif request.method == "GET" && request.path == "/echo-ims"
    picked = {"if_modified_since" => request.headers["If-Modified-Since"]?, "cache_control" => request.headers["Cache-Control"]?}
    response.status_code = 200
    response.headers["Content-Type"] = "application/json"
    response.print(picked.to_json)
  else
    case {request.method, request.path}
    when {"GET", "/json"}
      response.status_code = 200
      response.headers["Content-Type"] = "application/json"
      response.print(%({"ok":true,"n":5}))
    when {"GET", "/text"}
      response.status_code = 200
      response.headers["Content-Type"] = "text/plain"
      response.print("plain text body")
    when {"GET", "/notfound"}
      response.status_code = 404
    when {"GET", "/redirect"}
      response.status_code = 302
      response.headers["Location"] = "/text"
    when {"POST", "/echo"}
      body = request.body.try(&.gets_to_end) || ""
      response.status_code = 201
      response.headers["Content-Type"] = "application/json"
      response.print(%({"received":#{body.to_json}}))
    when {"POST", "/form"}
      body = request.body.try(&.gets_to_end) || ""
      response.status_code = 200
      response.headers["Content-Type"] = "text/plain"
      response.print(body)
    else
      response.status_code = 404
    end
  end
end
URI_TEST_ADDRESS = URI_TEST_SERVER.bind_unused_port
spawn { URI_TEST_SERVER.listen }
Fiber.yield

URI_BASE = "http://#{URI_TEST_ADDRESS}"

describe "uri plugin" do
  it "requires url" do
    result = PluginSpecHelper.run("uri", {} of String => String)
    result["failed"].as_bool.must_equal(true)
  end

  it "performs a GET and does not include content by default" do
    result = PluginSpecHelper.run("uri", {"url" => "#{URI_BASE}/text"})
    falsey?(result["failed"]?.try(&.as_bool)).must_equal(true)
    result["changed"].as_bool.must_equal(false)
    result["status"].as_i.must_equal(200)
    result.as_h.has_key?("content").must_equal(false)
  end

  it "includes content when return_content is set" do
    result = PluginSpecHelper.run("uri", {"url" => "#{URI_BASE}/text", "return_content" => "true"})
    result["content"].as_s.must_equal("plain text body")
  end

  it "always parses a json content-type into both content and json, regardless of return_content" do
    result = PluginSpecHelper.run("uri", {"url" => "#{URI_BASE}/json"})
    result["content"].as_s.must_equal(%({"ok":true,"n":5}))
    result["json"]["ok"].as_bool.must_equal(true)
    result["json"]["n"].as_i.must_equal(5)
  end

  it "fails with a Status code message when the response isn't in status_code" do
    result = PluginSpecHelper.run("uri", {"url" => "#{URI_BASE}/notfound"})
    result["failed"].as_bool.must_equal(true)
    result["status"].as_i.must_equal(404)
    # Live-verified against ansible-core 2.19.4: real fetch_url stuffs
    # urllib's str(HTTPError) into info['msg'], which uri.py appends:
    # "Status code was 404 and not [200]: HTTP Error 404: Not Found".
    result["msg"].as_s.must_equal("Status code was 404 and not [200]: HTTP Error 404: Not Found")
  end

  it "carries an empty content on a connection failure, matching real Ansible" do
    # Live-verified against ansible-core 2.19: a uri request that dies
    # before any HTTP response (connection refused) still fails with
    # {"status": -1, "content": "", "msg": "Status code was -1 and not
    # [200]: Request failed: ..."} - fetch_url's body ('' when there was
    # no response) is merged into resp before fail_json. Previously this
    # result had no content key, so a role's failed_when reading the
    # registered result's .content (geerlingguy.node_exporter's
    # "'Metrics' not in metrics_output.content", round 970310) blew up
    # with "object of type 'dict' has no attribute 'content'" instead of
    # reporting the request failure the way real Ansible does.
    closed_server = TCPServer.new("127.0.0.1", 0)
    closed_port = closed_server.local_address.port
    closed_server.close
    result = PluginSpecHelper.run("uri", {"url" => "http://127.0.0.1:#{closed_port}/", "return_content" => "true"})
    result["failed"].as_bool.must_equal(true)
    result["status"].as_i.must_equal(-1)
    result["content"].as_s.must_equal("")
    result["msg"].as_s.must_match(%r{\AStatus code was -1 and not \[200\]: Request failed: })
  end

  it "names the refused connect with urllib's own errno text" do
    # Live-verified against ansible-core 2.19.11: a refused connect puts
    # urllib's URLError str() in the msg. krikri used to report Crystal's
    # connect wording here ("Error connecting to '127.0.0.1:<port>':
    # Resource temporarily unavailable"), because Crystal 1.21.1's event
    # loop raises the live libc errno (EAGAIN) instead of the ECONNREFUSED
    # the kernel recorded - see PluginHelpers::SocketConnect.
    closed_server = TCPServer.new("127.0.0.1", 0)
    closed_port = closed_server.local_address.port
    closed_server.close
    result = PluginSpecHelper.run("uri", {"url" => "http://127.0.0.1:#{closed_port}/"})

    result["failed"].as_bool.must_equal(true)
    result["status"].as_i.must_equal(-1)
    result["msg"].as_s.must_equal(
      "Status code was -1 and not [200]: Request failed: <urlopen error [Errno 111] Connection refused>")
  end

  it "accepts a custom status_code list" do
    result = PluginSpecHelper.run("uri", {"url" => "#{URI_BASE}/notfound", "status_code" => "404,410"})
    falsey?(result["failed"]?.try(&.as_bool)).must_equal(true)
  end

  it "sends a POST body and reports the real status code" do
    result = PluginSpecHelper.run("uri", {"url" => "#{URI_BASE}/echo", "method" => "POST", "body" => "hello", "status_code" => "201"})
    falsey?(result["failed"]?.try(&.as_bool)).must_equal(true)
    result["status"].as_i.must_equal(201)
    result["json"]["received"].as_s.must_equal("hello")
  end

  it "form-encodes a dict body under body_format: form-urlencoded" do
    result = PluginSpecHelper.run("uri", {
      "url" => "#{URI_BASE}/form", "method" => "POST", "body" => %({"x":"1","y":"hello world"}),
      "body_format" => "form-urlencoded", "return_content" => "true",
    })
    content = result["content"].as_s
    content.must_include("x=1")
    content.must_include("y=hello+world")
  end

  it "follows a redirect by default and reports redirected: true" do
    result = PluginSpecHelper.run("uri", {"url" => "#{URI_BASE}/redirect", "return_content" => "true"})
    result["status"].as_i.must_equal(200)
    result["redirected"].as_bool.must_equal(true)
    result["content"].as_s.must_equal("plain text body")
  end

  it "reports the FINAL (post-redirect) URL as result.url, matching real Ansible" do
    # Real bug found via a live 100-role confirm round:
    # tigattack.mergerfs's own idiom - `uri: {url: .../releases/
    # latest}`, then `mergerfs_github_release_page['url'].split('/')
    # [-1]` to extract the real version tag from the redirect target -
    # relies on real Ansible's own uri: module behavior: result.url is
    # the FINAL URL after following redirects, not the originally-
    # requested one (verified live against ansible-core 2.19.12: GitHub's
    # own /releases/latest redirects to /releases/tag/<version>, and
    # result.url comes back as that target). This engine previously
    # always returned the ORIGINAL request url unchanged, so
    # `.split('/')[-1]` on a "/releases/latest"-shaped URL produced the
    # literal string "latest" instead of a real version, silently
    # breaking any role using this idiom to resolve a "latest" download.
    result = PluginSpecHelper.run("uri", {"url" => "#{URI_BASE}/redirect"})
    result["url"].as_s.must_equal("#{URI_BASE}/text")
  end

  it "does not follow a redirect when follow_redirects: none" do
    result = PluginSpecHelper.run("uri", {"url" => "#{URI_BASE}/redirect", "follow_redirects" => "none"})
    result["status"].as_i.must_equal(302)
    result["location"].as_s.must_equal("/text")
    result["failed"].as_bool.must_equal(true)
  end

  it "never reports changed, even for a mutating POST" do
    result = PluginSpecHelper.run("uri", {"url" => "#{URI_BASE}/echo", "method" => "POST", "status_code" => "201"})
    result["changed"].as_bool.must_equal(false)
  end

  it "is skipped under check_mode regardless of method" do
    result = PluginSpecHelper.run("uri", {"url" => "#{URI_BASE}/text", "_ansible_check_mode" => "true"})
    falsey?(result["failed"]?.try(&.as_bool)).must_equal(true)
    result["changed"].as_bool.must_equal(false)
    result["skipped"].as_bool.must_equal(true)
  end

  it "writes the response body to dest: and reports changed, real bug found live-verifying prometheus.prometheus.node_exporter" do
    # `dest:` writing was entirely unimplemented (the plugin's own doc
    # comment said so outright) - prometheus.prometheus._common's own
    # "Download {{ __common_binary_basename }}" task uses `uri:` with
    # `dest:` (not `get_url:`) to fetch the release tarball; the module
    # reported "OK (N bytes)" and `changed: false` while silently never
    # writing anything, so the very next task (`unarchive:`) failed with
    # "Source ... failed to transfer" against a file that never existed.
    path = File.tempname("uri_dest_spec")
    begin
      result = PluginSpecHelper.run("uri", {"url" => "#{URI_BASE}/text", "dest" => path})
      falsey?(result["failed"]?.try(&.as_bool)).must_equal(true)
      result["changed"].as_bool.must_equal(true)
      File.read(path).must_equal("plain text body")
    ensure
      File.delete(path) if File.exists?(path)
    end
  end

  it "reports changed: true on a dest: rerun even when the content hasn't changed, live-verified against real Ansible" do
    # Live-verified against ansible-core 2.19.4 (the same identical-content
    # fetch run twice in a row): real uri.py sets resp['changed'] = True
    # unconditionally after write_file - the SHA1 check inside write_file
    # only gates the physical move, NOT the reported status. The old
    # changed-false-on-identical behavior here was a guessed fix that
    # diverged from real Ansible.
    path = File.tempname("uri_dest_spec")
    begin
      File.write(path, "plain text body")
      result = PluginSpecHelper.run("uri", {"url" => "#{URI_BASE}/text", "dest" => path})
      falsey?(result["failed"]?.try(&.as_bool)).must_equal(true)
      result["changed"].as_bool.must_equal(true)
      result["msg"].as_s.must_equal("OK (15 bytes)")
      result["path"].as_s.must_equal(path)
    ensure
      File.delete(path) if File.exists?(path)
    end
  end

  it "skips via creates: when the file exists, real-exit-shape (stdout, changed: false)" do
    marker = File.tempname("uri_creates_spec")
    File.write(marker, "x")
    begin
      result = PluginSpecHelper.run("uri", {"url" => "#{URI_BASE}/text", "creates" => marker})
      result["changed"].as_bool.must_equal(false)
      falsey?(result["failed"]?.try(&.as_bool)).must_equal(true)
      result["stdout"].as_s.must_equal("skipped, since '#{marker}' exists")
    ensure
      File.delete(marker)
    end
  end

  it "skips via removes: when the file does not exist" do
    result = PluginSpecHelper.run("uri", {"url" => "#{URI_BASE}/text", "removes" => "/nonexistent-uri-spec-xyz"})
    result["changed"].as_bool.must_equal(false)
    falsey?(result["failed"]?.try(&.as_bool)).must_equal(true)
    result["stdout"].as_s.must_equal("skipped, since '/nonexistent-uri-spec-xyz' does not exist")
  end

  it "runs when creates: points at a missing file" do
    result = PluginSpecHelper.run("uri", {"url" => "#{URI_BASE}/text", "creates" => "/nonexistent-uri-spec-xyz"})
    falsey?(result["failed"]?.try(&.as_bool)).must_equal(true)
    result["status"].as_i.must_equal(200)
  end

  it "retries basic auth on a 401 challenge when force_basic_auth is unset (the default)" do
    result = PluginSpecHelper.run("uri", {"url" => "#{URI_BASE}/auth", "url_username" => "u1", "url_password" => "p1", "return_content" => "true"})
    falsey?(result["failed"]?.try(&.as_bool)).must_equal(true)
    result["status"].as_i.must_equal(200)
    result["content"].as_s.must_equal("secret-authed")
  end

  it "sends Basic auth on the first request when force_basic_auth is true" do
    result = PluginSpecHelper.run("uri", {"url" => "#{URI_BASE}/echo-headers", "url_username" => "u1", "url_password" => "p1", "force_basic_auth" => "true"})
    falsey?(result["failed"]?.try(&.as_bool)).must_equal(true)
    result["json"]["authorization"].as_s.must_equal("Basic " + Base64.strict_encode("u1:p1"))
  end

  it "accepts the documented user:/password: aliases" do
    result = PluginSpecHelper.run("uri", {"url" => "#{URI_BASE}/auth", "user" => "u1", "password" => "p1"})
    falsey?(result["failed"]?.try(&.as_bool)).must_equal(true)
    result["status"].as_i.must_equal(200)
  end

  it "fails with a 401 when the credentials are wrong" do
    result = PluginSpecHelper.run("uri", {"url" => "#{URI_BASE}/auth", "url_username" => "u1", "url_password" => "bad"})
    result["failed"].as_bool.must_equal(true)
    result["status"].as_i.must_equal(401)
  end

  it "sends cache-control: no-cache when force is set" do
    result = PluginSpecHelper.run("uri", {"url" => "#{URI_BASE}/echo-headers", "force" => "true"})
    result["json"]["cache_control"].as_s.must_equal("no-cache")
  end

  it "does not send cache-control by default" do
    result = PluginSpecHelper.run("uri", {"url" => "#{URI_BASE}/echo-headers"})
    result["json"]["cache_control"].as_s?.must_be_nil
  end

  it "decompresses a gzip response by default" do
    result = PluginSpecHelper.run("uri", {"url" => "#{URI_BASE}/gz", "return_content" => "true"})
    result["content"].as_s.must_equal("gzip-body-here")
  end

  it "requests identity encoding when decompress is false" do
    # Asserted on the wire (the spec server only gzips when the request
    # offered gzip), matching real Ansible's decompress: false observable:
    # undecoded response bytes.
    result = PluginSpecHelper.run("uri", {"url" => "#{URI_BASE}/echo-headers", "decompress" => "false"})
    result["json"]["accept_encoding"].as_s.must_equal("identity")
  end

  it "drops unredirected_headers on a redirect hop" do
    result = PluginSpecHelper.run("uri", {
      "url" => "#{URI_BASE}/redirect-auth", "follow_redirects" => "all",
      "headers" => %({"Authorization": "Token secret"}),
      "unredirected_headers" => %(["Authorization"]),
    })
    result["json"]["authorization"].as_s?.must_be_nil
  end

  it "keeps all headers on a redirect by default" do
    result = PluginSpecHelper.run("uri", {
      "url" => "#{URI_BASE}/redirect-auth", "follow_redirects" => "all",
      "headers" => %({"Authorization": "Token secret"}),
    })
    result["json"]["authorization"].as_s.must_equal("Token secret")
  end

  it "lands a directory-shaped dest under the Content-Disposition filename" do
    # Live-verified against ansible-core 2.19.4: real uri.py's
    # get_response_filename prefers Content-Disposition's filename
    # param, then the URL basename, then index.html.
    dir = File.tempname("uri_dest_dir_spec")
    Dir.mkdir(dir)
    begin
      result = PluginSpecHelper.run("uri", {"url" => "#{URI_BASE}/disp", "dest" => dir})
      falsey?(result["failed"]?.try(&.as_bool)).must_equal(true)
      result["changed"].as_bool.must_equal(true)
      result["path"].as_s.must_equal(File.join(dir, "dl-1.2.3.tar.gz"))
      File.read(result["path"].as_s).must_equal("file-content")
    ensure
      File.delete(File.join(dir, "dl-1.2.3.tar.gz")) if File.exists?(File.join(dir, "dl-1.2.3.tar.gz"))
      FileUtils.rmdir(dir) rescue nil
    end
  end

  it "applies dest file-common args (mode) and reports the file-common result keys" do
    path = File.tempname("uri_dest_mode_spec")
    begin
      result = PluginSpecHelper.run("uri", {"url" => "#{URI_BASE}/filecontent", "dest" => path, "mode" => "0600"})
      falsey?(result["failed"]?.try(&.as_bool)).must_equal(true)
      result["changed"].as_bool.must_equal(true)
      result["mode"].as_s.must_equal("0600")
      result["state"].as_s.must_equal("file")
      result["size"].as_i.must_equal(15)
      result["uid"].as_i.must_equal(File.info(path).owner_id.to_i64)
      result.as_h.has_key?("owner").must_equal(true)
      result.as_h.has_key?("group").must_equal(true)
      File.info(path).permissions.value.must_equal(0o600)
    ensure
      File.delete(path) if File.exists?(path)
    end
  end

  it "posts a src: file body and fails the body/src mutual exclusion like real Ansible" do
    body_file = File.tempname("uri_src_spec")
    File.write(body_file, "file payload")
    begin
      result = PluginSpecHelper.run("uri", {"url" => "#{URI_BASE}/src", "method" => "POST", "src" => body_file, "return_content" => "true"})
      falsey?(result["failed"]?.try(&.as_bool)).must_equal(true)
      result["status"].as_i.must_equal(200)
      result["content"].as_s.must_equal("got:file payload")

      conflict = PluginSpecHelper.run("uri", {"url" => "#{URI_BASE}/src", "method" => "POST", "src" => body_file, "body" => "x"})
      conflict["failed"].as_bool.must_equal(true)
      conflict["msg"].as_s.must_equal("parameters are mutually exclusive: body|src")
    ensure
      File.delete(body_file) if File.exists?(body_file)
    end
  end

  it "rejects a non-upper-single-word method like real Ansible" do
    result = PluginSpecHelper.run("uri", {"url" => "#{URI_BASE}/text", "method" => "GET POST"})
    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal("Parameter 'method' needs to be a single word in uppercase, like GET or POST.")
  end

  it "reports elapsed on a successful request" do
    result = PluginSpecHelper.run("uri", {"url" => "#{URI_BASE}/text"})
    result["elapsed"].as_i.must_be_close_to(0, 30)
  end

  it "reports status: -1 when the request fails before any HTTP response, matching real Ansible" do
    # Real bug found via levonet.ci_registry_rm_container's 400-role
    # differential round: the exception-rescue path returned its failure
    # result WITHOUT a status key, so a role's `when: r.status == 200`
    # after an `ignore_errors: yes` uri task died with "object of type
    # 'dict' has no attribute 'status'" instead of evaluating false the
    # way real Ansible does (fetch_url initializes its info dict with
    # status=-1 and keeps it there on connection failures).
    # Bind-and-release a port to guarantee a fast, deterministic
    # ECONNREFUSED instead of probing a port some other process might own.
    probe = TCPServer.new("127.0.0.1", 0)
    refused_port = probe.local_address.port
    probe.close
    result = PluginSpecHelper.run("uri", {"url" => "http://127.0.0.1:#{refused_port}/", "timeout" => "2"})
    result["failed"].as_bool.must_equal(true)
    result["status"].as_i.must_equal(-1)
    result["elapsed"].as_i.must_equal(0)
    result["redirected"].as_bool.must_equal(false)
  end

  it "sends If-Modified-Since derived from an existing dest file's mtime, as an HTTP-date in GMT" do
    # Real uri.py: dest already a regular FILE -> fetch_url gets
    # last_mod_time = the file's mtime, which urls.py renders with
    # rfc2822_date_string(timetuple, 'GMT'). Round 981032
    # (claranet.postgresql warm run): this header never went out, so a
    # 304-able fetch re-downloaded every run and reported changed.
    path = File.tempname("uri_ims_dest")
    File.write(path, "stale")
    File.touch(path, time: Time.utc(2021, 6, 15, 12, 30, 45))
    begin
      result = PluginSpecHelper.run("uri", {"url" => "#{URI_BASE}/echo-ims", "dest" => path})
      result["json"]["if_modified_since"].as_s.must_equal(Time::Format::HTTP_DATE.format(Time.utc(2021, 6, 15, 12, 30, 45)))
      result["json"]["if_modified_since"].as_s.must_match(/\ATue, 15 Jun 2021 12:30:45 GMT\z/)
    ensure
      File.delete(path) if File.exists?(path)
    end
  end

  it "cold/warm dest: rerun is changed/ok via 304, live-verified against real Ansible (round 981032 claranet.postgresql)" do
    # Live-verified against ansible-core 2.19: cold run 200/changed=true,
    # warm run 304/changed=false with msg "HTTP Error 304: Not Modified"
    # (urllib raises HTTPError for a 304 - no handler exists for it - so
    # fetch_url's info carries urllib's own string), path: and the
    # file-common stat keys still present (AnsibleModule._return_formatted's
    # add_path_info runs for ANY result whose path: exists), and the dest
    # file left untouched.
    dest = File.tempname("uri_ims_warm")
    begin
      cold = PluginSpecHelper.run("uri", {"url" => "#{URI_BASE}/ims-old", "dest" => dest, "status_code" => "200,304"})
      falsey?(cold["failed"]?.try(&.as_bool)).must_equal(true)
      cold["changed"].as_bool.must_equal(true)
      cold["status"].as_i.must_equal(200)
      File.read(dest).must_equal("ims-body")

      warm = PluginSpecHelper.run("uri", {"url" => "#{URI_BASE}/ims-old", "dest" => dest, "status_code" => "200,304"})
      falsey?(warm["failed"]?.try(&.as_bool)).must_equal(true)
      warm["changed"].as_bool.must_equal(false)
      warm["status"].as_i.must_equal(304)
      warm["msg"].as_s.must_equal("HTTP Error 304: Not Modified")
      warm["path"].as_s.must_equal(dest)
      warm["state"].as_s.must_equal("file")
      warm["size"].as_i.must_equal(8)
      warm.as_h.has_key?("mode").must_equal(true)
      File.read(dest).must_equal("ims-body")
    ensure
      File.delete(dest) if File.exists?(dest)
    end
  end

  it "re-downloads (200, changed) once the server file is newer than the dest file" do
    dest = File.tempname("uri_ims_touch")
    begin
      cold = PluginSpecHelper.run("uri", {"url" => "#{URI_BASE}/ims-flip", "dest" => dest, "status_code" => "200,304"})
      cold["changed"].as_bool.must_equal(true)

      File.touch(IMS_FLIP, time: Time.utc(2030, 1, 1, 0, 0, 0))
      result = PluginSpecHelper.run("uri", {"url" => "#{URI_BASE}/ims-flip", "dest" => dest, "status_code" => "200,304"})
      result["changed"].as_bool.must_equal(true)
      result["status"].as_i.must_equal(200)
    ensure
      File.touch(IMS_FLIP, time: Time.utc(2020, 1, 1, 0, 0, 0))
      File.delete(dest) if File.exists?(dest)
    end
  end

  it "does not send If-Modified-Since when dest is a directory (real isfile gate)" do
    dir = File.tempname("uri_ims_dir")
    Dir.mkdir(dir)
    begin
      result = PluginSpecHelper.run("uri", {"url" => "#{URI_BASE}/echo-ims", "dest" => dir})
      result["json"]["if_modified_since"].as_s?.must_be_nil
    ensure
      File.delete(File.join(dir, "echo-ims")) if File.exists?(File.join(dir, "echo-ims"))
      FileUtils.rmdir(dir) rescue nil
    end
  end

  it "sends cache-control instead of If-Modified-Since under force: true" do
    # urls.py's if/elif: force: takes the cache-control branch, no
    # conditional-get header.
    path = File.tempname("uri_ims_force")
    File.write(path, "stale")
    begin
      result = PluginSpecHelper.run("uri", {"url" => "#{URI_BASE}/echo-ims", "dest" => path, "force" => "true"})
      result["json"]["if_modified_since"].as_s?.must_be_nil
      result["json"]["cache_control"].as_s.must_equal("no-cache")
    ensure
      File.delete(path) if File.exists?(path)
    end
  end

  it "lets a user-supplied If-Modified-Since header win over the derived one" do
    path = File.tempname("uri_ims_user")
    File.write(path, "stale")
    begin
      result = PluginSpecHelper.run("uri", {
        "url" => "#{URI_BASE}/echo-ims", "dest" => path,
        "headers" => %({"If-Modified-Since": "Mon, 01 Jan 2001 00:00:00 GMT"}),
      })
      result["json"]["if_modified_since"].as_s.must_equal("Mon, 01 Jan 2001 00:00:00 GMT")
    ensure
      File.delete(path) if File.exists?(path)
    end
  end

  it "fails a 304 outside status_code with the urllib-shaped msg" do
    path = File.tempname("uri_ims_fail")
    File.write(path, "ims-body")
    begin
      result = PluginSpecHelper.run("uri", {"url" => "#{URI_BASE}/ims-old", "dest" => path})
      result["failed"].as_bool.must_equal(true)
      result["status"].as_i.must_equal(304)
      result["msg"].as_s.must_equal("Status code was 304 and not [200]: HTTP Error 304: Not Modified")
    ensure
      File.delete(path) if File.exists?(path)
    end
  end

  # The connection-failure result shape (real uri.py's own resp assembly
  # for a request that ran and came back with status -1): redirected and
  # elapsed are always there, content only when return_content asked for
  # it (live-verified vs 2.19.11 - a return_content: false
  # connection-refused result has NO content key).
  describe "pre-request failures (real fetch_url's own handlers)" do
    it "fails a ciphers list that selects nothing, before any request" do
      result = PluginSpecHelper.run("uri", {
        "url" => "#{URI_BASE}/text", "ciphers" => %(["fdpfji", "ahatju"]),
      })

      result["failed"].as_bool.must_equal(true)
      result["msg"].as_s.must_equal(
        "Status code was -1 and not [200]: Connection failure: ('No cipher can be selected.',)")
      result["status"].as_i.must_equal(-1)
      result["elapsed"].as_i.must_equal(0)
      result["redirected"].as_bool.must_equal(false)
      result["url"].as_s.must_equal("#{URI_BASE}/text")
      result["content"]?.must_be_nil
    end

    it "carries an empty content on the same failure when return_content is set" do
      result = PluginSpecHelper.run("uri", {
        "url" => "#{URI_BASE}/text", "ciphers" => %(["fdpfji"]), "return_content" => "true",
      })

      result["content"].as_s.must_equal("")
      result["msg"].as_s.must_equal(
        "Status code was -1 and not [200]: Connection failure: ('No cipher can be selected.',)")
    end

    it "omits content on a plain connection failure without return_content" do
      closed_server = TCPServer.new("127.0.0.1", 0)
      closed_port = closed_server.local_address.port
      closed_server.close
      result = PluginSpecHelper.run("uri", {"url" => "http://127.0.0.1:#{closed_port}/"})

      result["status"].as_i.must_equal(-1)
      result["content"]?.must_be_nil
    end

    it "fails an unreadable ca_path with real's OSError wording" do
      missing = PluginSpecHelper.tmp_path("no-such-ca-#{Random::Secure.hex(4)}.pem")
      result = PluginSpecHelper.run("uri", {"url" => "#{URI_BASE}/text", "ca_path" => missing})

      result["msg"].as_s.must_equal(
        "Status code was -1 and not [200]: Connection failure: [Errno 2] No such file or directory")
    end

    it "fails an unreadable client_cert before the request" do
      missing = PluginSpecHelper.tmp_path("no-such-client-cert-#{Random::Secure.hex(4)}.pem")
      result = PluginSpecHelper.run("uri", {"url" => "#{URI_BASE}/text", "client_cert" => missing})

      result["msg"].as_s.must_equal(
        "Status code was -1 and not [200]: Connection failure: [Errno 2] No such file or directory")
    end

    it "fails a client_cert that is a directory the way real's open() does" do
      result = PluginSpecHelper.run("uri", {
        "url" => "#{URI_BASE}/text", "client_cert" => PluginSpecHelper.tmp_path("."),
      })

      result["msg"].as_s.must_equal(
        "Status code was -1 and not [200]: Connection failure: [Errno 21] Is a directory")
    end

    it "lets a creates: skip win over the preflight, like real does" do
      # uri.py short-circuits on creates:/removes: BEFORE fetch_url ever
      # builds the context - live-verified with a bogus ciphers list.
      existing = PluginSpecHelper.tmp_path("creates-exists-#{Random::Secure.hex(4)}.txt")
      File.write(existing, "x")
      result = PluginSpecHelper.run("uri", {
        "url" => "#{URI_BASE}/text", "ciphers" => %(["fdpfji"]),
        "creates" => existing,
      })

      falsey?(result["failed"]?.try(&.as_bool)).must_equal(true)
      result["stdout"].as_s.must_equal("skipped, since '#{existing}' exists")
    ensure
      File.delete(existing) if existing && File.exists?(existing)
    end

    it "reports the cipher failure ahead of a scheme-less URL's own error" do
      result = PluginSpecHelper.run("uri", {"url" => "wezwmn", "ciphers" => %(["fdpfji"])})

      result["msg"].as_s.must_equal(
        "Status code was -1 and not [200]: Connection failure: ('No cipher can be selected.',)")
    end
  end

  # The module-side twin of the uri action plugin's non-mapping
  # form-multipart guard (real uri.py's own prepare_multipart call), which
  # is the one a remote_src: true task reaches - different wording, and
  # only the tagged/untagged class names differ. Both live-verified vs
  # 2.19.11.
  describe "form-multipart body validation" do
    it "fails a non-mapping body with real's module-side message and Python class names" do
      {
        "asgaub"                          => "str",
        "5"                               => "int",
        "1.5"                             => "float",
        "true"                            => "bool",
        %(["1", "2"])                     => "list",
        Krikri::NON_STRING_PARAM_PREFIX + "5" => "int",
      }.each do |body, class_name|
        result = PluginSpecHelper.run("uri", {
          "url" => "#{URI_BASE}/text", "body_format" => "form-multipart",
          "body" => body, "remote_src" => "true",
        })
        result["failed"].as_bool.must_equal(true)
        result["msg"].as_s.must_equal(
          "failed to parse body as form-multipart: Mapping is required, cannot be type #{class_name}")
      end
    end

    it "fails a missing body as NoneType" do
      result = PluginSpecHelper.run("uri", {
        "url" => "#{URI_BASE}/text", "body_format" => "form-multipart", "remote_src" => "true",
      })

      result["msg"].as_s.must_equal(
        "failed to parse body as form-multipart: Mapping is required, cannot be type NoneType")
    end

    it "reports the body failure ahead of a creates: skip" do
      # uri.py validates the body BEFORE the creates:/removes:
      # short-circuits - live-verified with a removes: file that does not
      # exist (which would otherwise skip with ok).
      result = PluginSpecHelper.run("uri", {
        "url" => "#{URI_BASE}/text", "body_format" => "form-multipart",
        "body" => "asgaub", "remote_src" => "true",
        "removes" => PluginSpecHelper.tmp_path("never-created-#{Random::Secure.hex(4)}.txt"),
      })

      result["msg"].as_s.must_include("failed to parse body as form-multipart")
    end
  end

  # real uri.py reads src: inside its uri() helper, i.e. AFTER the
  # creates:/removes: short-circuits, and its own failure carries elapsed
  # and nothing else (no url/status/redirected).
  describe "src: handling" do
    it "fails a src: the plugin cannot read with only elapsed beside msg" do
      missing = PluginSpecHelper.tmp_path("no-such-src-#{Random::Secure.hex(4)}.txt")
      result = PluginSpecHelper.run("uri", {
        "url" => "#{URI_BASE}/text", "src" => missing, "remote_src" => "true",
      })

      result["failed"].as_bool.must_equal(true)
      result["msg"].as_s.must_equal("Unable to open source file #{missing}")
      result["elapsed"].as_i.must_equal(0)
      result["url"]?.must_be_nil
      result["status"]?.must_be_nil
      result["redirected"]?.must_be_nil
    end

    it "fails a src: that is a directory instead of crashing the plugin" do
      # File.read on a directory raises the plain IO::Error - which is
      # File::Error's PARENT, so the narrower rescue never caught it.
      result = PluginSpecHelper.run("uri", {
        "url" => "#{URI_BASE}/text", "src" => PluginSpecHelper.tmp_path("."), "remote_src" => "true",
      })

      result["failed"].as_bool.must_equal(true)
      result["msg"].as_s.must_equal("Unable to open source file #{PluginSpecHelper.tmp_path(".")}")
    end

    it "lets a creates: skip win over a missing src:, like real does" do
      existing = PluginSpecHelper.tmp_path("creates-exists-src-#{Random::Secure.hex(4)}.txt")
      File.write(existing, "x")
      result = PluginSpecHelper.run("uri", {
        "url" => "#{URI_BASE}/text", "remote_src" => "true",
        "src" => PluginSpecHelper.tmp_path("no-such-src-#{Random::Secure.hex(4)}.txt"),
        "creates" => existing,
      })

      falsey?(result["failed"]?.try(&.as_bool)).must_equal(true)
      result["stdout"].as_s.must_equal("skipped, since '#{existing}' exists")
    ensure
      File.delete(existing) if existing && File.exists?(existing)
    end
  end
end
