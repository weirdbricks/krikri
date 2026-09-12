require "../spec_helper"
require "http/server"
require "base64"
require "compress/gzip"
require "file_utils"

# A tiny local HTTP server exercising GET/POST/redirect/JSON/plain-text
# responses, started once for the whole file.
uri_test_server = HTTP::Server.new do |context|
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
uri_test_address = uri_test_server.bind_unused_port
spawn { uri_test_server.listen }
Fiber.yield

uri_base = "http://#{uri_test_address}"

describe "uri plugin" do
  it "requires url" do
    result = PluginSpecHelper.run("uri", {} of String => String)
    result["failed"].as_bool.should be_true
  end

  it "performs a GET and does not include content by default" do
    result = PluginSpecHelper.run("uri", {"url" => "#{uri_base}/text"})
    result["failed"].as_bool.should be_false
    result["changed"].as_bool.should be_false
    result["status"].as_i.should eq(200)
    result.as_h.has_key?("content").should be_false
  end

  it "includes content when return_content is set" do
    result = PluginSpecHelper.run("uri", {"url" => "#{uri_base}/text", "return_content" => "true"})
    result["content"].as_s.should eq("plain text body")
  end

  it "always parses a json content-type into both content and json, regardless of return_content" do
    result = PluginSpecHelper.run("uri", {"url" => "#{uri_base}/json"})
    result["content"].as_s.should eq(%({"ok":true,"n":5}))
    result["json"]["ok"].as_bool.should be_true
    result["json"]["n"].as_i.should eq(5)
  end

  it "fails with a Status code message when the response isn't in status_code" do
    result = PluginSpecHelper.run("uri", {"url" => "#{uri_base}/notfound"})
    result["failed"].as_bool.should be_true
    result["status"].as_i.should eq(404)
    # Live-verified against ansible-core 2.19.4: real fetch_url stuffs
    # urllib's str(HTTPError) into info['msg'], which uri.py appends:
    # "Status code was 404 and not [200]: HTTP Error 404: Not Found".
    result["msg"].as_s.should eq("Status code was 404 and not [200]: HTTP Error 404: Not Found")
  end

  it "accepts a custom status_code list" do
    result = PluginSpecHelper.run("uri", {"url" => "#{uri_base}/notfound", "status_code" => "404,410"})
    result["failed"].as_bool.should be_false
  end

  it "sends a POST body and reports the real status code" do
    result = PluginSpecHelper.run("uri", {"url" => "#{uri_base}/echo", "method" => "POST", "body" => "hello", "status_code" => "201"})
    result["failed"].as_bool.should be_false
    result["status"].as_i.should eq(201)
    result["json"]["received"].as_s.should eq("hello")
  end

  it "form-encodes a dict body under body_format: form-urlencoded" do
    result = PluginSpecHelper.run("uri", {
      "url" => "#{uri_base}/form", "method" => "POST", "body" => %({"x":"1","y":"hello world"}),
      "body_format" => "form-urlencoded", "return_content" => "true",
    })
    content = result["content"].as_s
    content.should contain("x=1")
    content.should contain("y=hello+world")
  end

  it "follows a redirect by default and reports redirected: true" do
    result = PluginSpecHelper.run("uri", {"url" => "#{uri_base}/redirect", "return_content" => "true"})
    result["status"].as_i.should eq(200)
    result["redirected"].as_bool.should be_true
    result["content"].as_s.should eq("plain text body")
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
    result = PluginSpecHelper.run("uri", {"url" => "#{uri_base}/redirect"})
    result["url"].as_s.should eq("#{uri_base}/text")
  end

  it "does not follow a redirect when follow_redirects: none" do
    result = PluginSpecHelper.run("uri", {"url" => "#{uri_base}/redirect", "follow_redirects" => "none"})
    result["status"].as_i.should eq(302)
    result["location"].as_s.should eq("/text")
    result["failed"].as_bool.should be_true
  end

  it "never reports changed, even for a mutating POST" do
    result = PluginSpecHelper.run("uri", {"url" => "#{uri_base}/echo", "method" => "POST", "status_code" => "201"})
    result["changed"].as_bool.should be_false
  end

  it "is skipped under check_mode regardless of method" do
    result = PluginSpecHelper.run("uri", {"url" => "#{uri_base}/text", "check_mode" => "true"})
    result["failed"].as_bool.should be_false
    result["changed"].as_bool.should be_false
    result["skipped"].as_bool.should be_true
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
      result = PluginSpecHelper.run("uri", {"url" => "#{uri_base}/text", "dest" => path})
      result["failed"].as_bool.should be_false
      result["changed"].as_bool.should be_true
      File.read(path).should eq("plain text body")
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
      result = PluginSpecHelper.run("uri", {"url" => "#{uri_base}/text", "dest" => path})
      result["failed"].as_bool.should be_false
      result["changed"].as_bool.should be_true
      result["msg"].as_s.should eq("OK (15 bytes)")
      result["path"].as_s.should eq(path)
    ensure
      File.delete(path) if File.exists?(path)
    end
  end

  it "skips via creates: when the file exists, real-exit-shape (stdout, changed: false)" do
    marker = File.tempname("uri_creates_spec")
    File.write(marker, "x")
    begin
      result = PluginSpecHelper.run("uri", {"url" => "#{uri_base}/text", "creates" => marker})
      result["changed"].as_bool.should be_false
      result["failed"].as_bool.should be_false
      result["stdout"].as_s.should eq("skipped, since '#{marker}' exists")
    ensure
      File.delete(marker)
    end
  end

  it "skips via removes: when the file does not exist" do
    result = PluginSpecHelper.run("uri", {"url" => "#{uri_base}/text", "removes" => "/nonexistent-uri-spec-xyz"})
    result["changed"].as_bool.should be_false
    result["failed"].as_bool.should be_false
    result["stdout"].as_s.should eq("skipped, since '/nonexistent-uri-spec-xyz' does not exist")
  end

  it "runs when creates: points at a missing file" do
    result = PluginSpecHelper.run("uri", {"url" => "#{uri_base}/text", "creates" => "/nonexistent-uri-spec-xyz"})
    result["failed"].as_bool.should be_false
    result["status"].as_i.should eq(200)
  end

  it "retries basic auth on a 401 challenge when force_basic_auth is unset (the default)" do
    result = PluginSpecHelper.run("uri", {"url" => "#{uri_base}/auth", "url_username" => "u1", "url_password" => "p1", "return_content" => "true"})
    result["failed"].as_bool.should be_false
    result["status"].as_i.should eq(200)
    result["content"].as_s.should eq("secret-authed")
  end

  it "sends Basic auth on the first request when force_basic_auth is true" do
    result = PluginSpecHelper.run("uri", {"url" => "#{uri_base}/echo-headers", "url_username" => "u1", "url_password" => "p1", "force_basic_auth" => "true"})
    result["failed"].as_bool.should be_false
    result["json"]["authorization"].as_s.should eq("Basic " + Base64.strict_encode("u1:p1"))
  end

  it "accepts the documented user:/password: aliases" do
    result = PluginSpecHelper.run("uri", {"url" => "#{uri_base}/auth", "user" => "u1", "password" => "p1"})
    result["failed"].as_bool.should be_false
    result["status"].as_i.should eq(200)
  end

  it "fails with a 401 when the credentials are wrong" do
    result = PluginSpecHelper.run("uri", {"url" => "#{uri_base}/auth", "url_username" => "u1", "url_password" => "bad"})
    result["failed"].as_bool.should be_true
    result["status"].as_i.should eq(401)
  end

  it "sends cache-control: no-cache when force is set" do
    result = PluginSpecHelper.run("uri", {"url" => "#{uri_base}/echo-headers", "force" => "true"})
    result["json"]["cache_control"].as_s.should eq("no-cache")
  end

  it "does not send cache-control by default" do
    result = PluginSpecHelper.run("uri", {"url" => "#{uri_base}/echo-headers"})
    result["json"]["cache_control"].as_s?.should be_nil
  end

  it "decompresses a gzip response by default" do
    result = PluginSpecHelper.run("uri", {"url" => "#{uri_base}/gz", "return_content" => "true"})
    result["content"].as_s.should eq("gzip-body-here")
  end

  it "requests identity encoding when decompress is false" do
    # Asserted on the wire (the spec server only gzips when the request
    # offered gzip), matching real Ansible's decompress: false observable:
    # undecoded response bytes.
    result = PluginSpecHelper.run("uri", {"url" => "#{uri_base}/echo-headers", "decompress" => "false"})
    result["json"]["accept_encoding"].as_s.should eq("identity")
  end

  it "drops unredirected_headers on a redirect hop" do
    result = PluginSpecHelper.run("uri", {
      "url" => "#{uri_base}/redirect-auth", "follow_redirects" => "all",
      "headers" => %({"Authorization": "Token secret"}),
      "unredirected_headers" => %(["Authorization"]),
    })
    result["json"]["authorization"].as_s?.should be_nil
  end

  it "keeps all headers on a redirect by default" do
    result = PluginSpecHelper.run("uri", {
      "url" => "#{uri_base}/redirect-auth", "follow_redirects" => "all",
      "headers" => %({"Authorization": "Token secret"}),
    })
    result["json"]["authorization"].as_s.should eq("Token secret")
  end

  it "lands a directory-shaped dest under the Content-Disposition filename" do
    # Live-verified against ansible-core 2.19.4: real uri.py's
    # get_response_filename prefers Content-Disposition's filename
    # param, then the URL basename, then index.html.
    dir = File.tempname("uri_dest_dir_spec")
    Dir.mkdir(dir)
    begin
      result = PluginSpecHelper.run("uri", {"url" => "#{uri_base}/disp", "dest" => dir})
      result["failed"].as_bool.should be_false
      result["changed"].as_bool.should be_true
      result["path"].as_s.should eq(File.join(dir, "dl-1.2.3.tar.gz"))
      File.read(result["path"].as_s).should eq("file-content")
    ensure
      File.delete(File.join(dir, "dl-1.2.3.tar.gz")) if File.exists?(File.join(dir, "dl-1.2.3.tar.gz"))
      FileUtils.rmdir(dir) rescue nil
    end
  end

  it "applies dest file-common args (mode) and reports the file-common result keys" do
    path = File.tempname("uri_dest_mode_spec")
    begin
      result = PluginSpecHelper.run("uri", {"url" => "#{uri_base}/filecontent", "dest" => path, "mode" => "0600"})
      result["failed"].as_bool.should be_false
      result["changed"].as_bool.should be_true
      result["mode"].as_s.should eq("0600")
      result["state"].as_s.should eq("file")
      result["size"].as_i.should eq(15)
      result["uid"].as_i.should eq(File.info(path).owner_id.to_i64)
      result.as_h.has_key?("owner").should be_true
      result.as_h.has_key?("group").should be_true
      File.info(path).permissions.value.should eq(0o600)
    ensure
      File.delete(path) if File.exists?(path)
    end
  end

  it "posts a src: file body and fails the body/src mutual exclusion like real Ansible" do
    body_file = File.tempname("uri_src_spec")
    File.write(body_file, "file payload")
    begin
      result = PluginSpecHelper.run("uri", {"url" => "#{uri_base}/src", "method" => "POST", "src" => body_file, "return_content" => "true"})
      result["failed"].as_bool.should be_false
      result["status"].as_i.should eq(200)
      result["content"].as_s.should eq("got:file payload")

      conflict = PluginSpecHelper.run("uri", {"url" => "#{uri_base}/src", "method" => "POST", "src" => body_file, "body" => "x"})
      conflict["failed"].as_bool.should be_true
      conflict["msg"].as_s.should eq("parameters are mutually exclusive: body|src")
    ensure
      File.delete(body_file) if File.exists?(body_file)
    end
  end

  it "rejects a non-upper-single-word method like real Ansible" do
    result = PluginSpecHelper.run("uri", {"url" => "#{uri_base}/text", "method" => "GET POST"})
    result["failed"].as_bool.should be_true
    result["msg"].as_s.should eq("Parameter 'method' needs to be a single word in uppercase, like GET or POST.")
  end

  it "reports elapsed on a successful request" do
    result = PluginSpecHelper.run("uri", {"url" => "#{uri_base}/text"})
    result["elapsed"].as_i.should be_close(0, 30)
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
    result["failed"].as_bool.should be_true
    result["status"].as_i.should eq(-1)
    result["elapsed"].as_i.should eq(0)
    result["redirected"].as_bool.should be_false
  end
end
