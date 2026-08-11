require "../spec_helper"
require "http/server"
require "openssl/digest"

# A tiny local HTTP server (Crystal stdlib HTTP::Server, no python3
# dependency) serving fixed content + a redirect, started once for the
# whole file rather than per-example.
FILE_CONTENT  = "hello from get_url spec\n"
FILE_CHECKSUM = begin
  digest = OpenSSL::Digest.new("SHA256")
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

  it "requires url and dest" do
    result = PluginSpecHelper.run("get_url", {"dest" => "/tmp/whatever"})
    result["failed"].as_bool.should be_true

    result = PluginSpecHelper.run("get_url", {"url" => "#{get_url_base}/file.txt"})
    result["failed"].as_bool.should be_true
  end
end
