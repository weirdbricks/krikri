require "../spec_helper"
require "file_utils"
require "http/server"

private TMP_DIR = File.join(PluginSpecHelper::PROJECT_ROOT, "spec", "tmp", "unarchive")

Spec.before_suite do
  FileUtils.rm_rf(TMP_DIR) if Dir.exists?(TMP_DIR)
  Dir.mkdir_p(File.join(TMP_DIR, "src", "sub"))
  File.write(File.join(TMP_DIR, "src", "a.txt"), "hello")
  File.write(File.join(TMP_DIR, "src", "sub", "b.txt"), "nested")
  `tar czf #{File.join(TMP_DIR, "archive.tar.gz")} -C #{File.join(TMP_DIR, "src")} .`
  `cd #{TMP_DIR} && zip -qr archive.zip src`
end

# A tiny local HTTP server serving the tar.gz built above, plus a
# redirect - real Ansible's own unarchive module fetches src: first
# when remote_src: true and src: contains "://" (GitHub's own release-
# asset URLs are themselves a redirect to a signed storage URL, so
# redirect-following isn't optional here).
unarchive_test_server = HTTP::Server.new do |context|
  case context.request.path
  when "/archive.tar.gz"
    context.response.status_code = 200
    context.response.headers["Content-Type"] = "application/gzip"
    IO.copy(File.open(File.join(TMP_DIR, "archive.tar.gz")), context.response)
  when "/redirect.tar.gz"
    context.response.status_code = 302
    context.response.headers["Location"] = "/archive.tar.gz"
  else
    context.response.status_code = 404
  end
end
unarchive_test_address = unarchive_test_server.bind_unused_port
spawn { unarchive_test_server.listen }
Fiber.yield
unarchive_base = "http://#{unarchive_test_address}"

private def fresh_dest(name : String) : String
  path = File.join(TMP_DIR, name)
  FileUtils.rm_rf(path) if Dir.exists?(path)
  Dir.mkdir_p(path)
  path
end

describe "unarchive plugin" do
  it "extracts a tar.gz, preserving directory structure" do
    dest = fresh_dest("tar-extract")
    result = PluginSpecHelper.run("unarchive", {"src" => File.join(TMP_DIR, "archive.tar.gz"), "dest" => dest})

    result["changed"].as_bool.should be_true
    result["handler"].as_s.should eq("TgzArchive")
    File.read(File.join(dest, "a.txt")).should eq("hello")
    File.read(File.join(dest, "sub", "b.txt")).should eq("nested")
  end

  it "reports changed: false on an idempotent rerun (tar --compare based)" do
    dest = fresh_dest("tar-idempotent")
    PluginSpecHelper.run("unarchive", {"src" => File.join(TMP_DIR, "archive.tar.gz"), "dest" => dest})

    result = PluginSpecHelper.run("unarchive", {"src" => File.join(TMP_DIR, "archive.tar.gz"), "dest" => dest})

    result["changed"].as_bool.should be_false
  end

  it "reports changed: true when an extracted file is modified since the last extraction" do
    dest = fresh_dest("tar-changed")
    PluginSpecHelper.run("unarchive", {"src" => File.join(TMP_DIR, "archive.tar.gz"), "dest" => dest})
    File.write(File.join(dest, "a.txt"), "tampered")

    result = PluginSpecHelper.run("unarchive", {"src" => File.join(TMP_DIR, "archive.tar.gz"), "dest" => dest})

    result["changed"].as_bool.should be_true
  end

  it "extracts a zip archive" do
    dest = fresh_dest("zip-extract")
    result = PluginSpecHelper.run("unarchive", {"src" => File.join(TMP_DIR, "archive.zip"), "dest" => dest})

    result["changed"].as_bool.should be_true
    result["handler"].as_s.should eq("ZipArchive")
    File.read(File.join(dest, "src", "a.txt")).should eq("hello")
  end

  it "reports changed: false on an idempotent zip rerun" do
    dest = fresh_dest("zip-idempotent")
    PluginSpecHelper.run("unarchive", {"src" => File.join(TMP_DIR, "archive.zip"), "dest" => dest})

    result = PluginSpecHelper.run("unarchive", {"src" => File.join(TMP_DIR, "archive.zip"), "dest" => dest})

    result["changed"].as_bool.should be_false
  end

  it "skips entirely when creates: already exists" do
    dest = fresh_dest("creates-skip")
    File.write(File.join(dest, "marker.txt"), "already here")

    result = PluginSpecHelper.run("unarchive", {"src" => File.join(TMP_DIR, "archive.tar.gz"), "dest" => dest, "creates" => File.join(dest, "marker.txt")})

    result["changed"].as_bool.should be_false
    File.exists?(File.join(dest, "a.txt")).should be_false
  end

  it "excludes a member matching exclude:" do
    dest = fresh_dest("exclude")
    result = PluginSpecHelper.run("unarchive", {"src" => File.join(TMP_DIR, "archive.tar.gz"), "dest" => dest, "exclude" => "sub/b.txt"})

    result["changed"].as_bool.should be_true
    File.exists?(File.join(dest, "a.txt")).should be_true
    File.exists?(File.join(dest, "sub", "b.txt")).should be_false
  end

  it "fails with a clear message when dest doesn't already exist" do
    missing_dest = File.join(TMP_DIR, "does-not-exist-dir")
    FileUtils.rm_rf(missing_dest) if Dir.exists?(missing_dest)

    result = PluginSpecHelper.run("unarchive", {"src" => File.join(TMP_DIR, "archive.tar.gz"), "dest" => missing_dest})

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should contain("must be an existing dir")
  end

  it "includes the member list when list_files: true" do
    dest = fresh_dest("list-files")
    result = PluginSpecHelper.run("unarchive", {"src" => File.join(TMP_DIR, "archive.tar.gz"), "dest" => dest, "list_files" => "true"})

    # tar member order depends on filesystem readdir order, not a
    # meaningful contract - sorted here so the assertion is about content.
    result["files"].as_a.map(&.as_s).sort!.should eq(["./", "./a.txt", "./sub/", "./sub/b.txt"])
  end

  it "fetches src: from a URL first when it contains :// (remote_src: true + a URL), real Ansible's own documented behavior" do
    # Real bug found benchmarking geerlingguy.node_exporter's own
    # "Download and unarchive node_exporter into temporary location."
    # task (`src: "{{ a_url }}"`, `remote_src: true`). This class's own
    # doc comment previously (wrongly) claimed remote_src: "has no
    # effect" - real Ansible's unarchive module explicitly documents
    # fetching src: first when it contains "://". Previously src: went
    # straight to a local-file-path existence check, always false for
    # a URL, failing outright with "Source ... failed to transfer" even
    # though the URL was perfectly reachable.
    dest = fresh_dest("url-src")
    result = PluginSpecHelper.run("unarchive", {"src" => "#{unarchive_base}/archive.tar.gz", "dest" => dest, "remote_src" => "true"})

    result["changed"].as_bool.should be_true
    File.read(File.join(dest, "a.txt")).should eq("hello")
    File.read(File.join(dest, "sub", "b.txt")).should eq("nested")
  end

  it "follows a redirect when fetching src: from a URL" do
    dest = fresh_dest("url-src-redirect")
    result = PluginSpecHelper.run("unarchive", {"src" => "#{unarchive_base}/redirect.tar.gz", "dest" => dest, "remote_src" => "true"})

    result["changed"].as_bool.should be_true
    File.read(File.join(dest, "a.txt")).should eq("hello")
  end

  it "fails with a clear message when src or dest is missing" do
    result = PluginSpecHelper.run("unarchive", {"dest" => TMP_DIR})

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should contain("src")
  end
end
