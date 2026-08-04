require "../spec_helper"

private TMP_DIR = File.join(PluginSpecHelper::PROJECT_ROOT, "spec", "tmp")

Spec.before_suite do
  Dir.mkdir_p(TMP_DIR)
end

private def tmp_path(name : String) : String
  File.join(TMP_DIR, name)
end

describe "stat plugin" do
  it "reports exists: false for a missing path, with nothing else in the stat dict" do
    result = PluginSpecHelper.run("stat", {"path" => tmp_path("does-not-exist.txt")})

    result["failed"].as_bool.should be_false
    result["changed"].as_bool.should be_false
    result["stat"]["exists"].as_bool.should be_false
    result["stat"].as_h.size.should eq(1)
  end

  it "reports file attributes for a regular file, matching real ansible's stat module field shapes" do
    path = tmp_path("stat-file.txt")
    File.write(path, "hello vault world")
    File.chmod(path, 0o644)

    result = PluginSpecHelper.run("stat", {"path" => path})
    stat = result["stat"]

    stat["exists"].as_bool.should be_true
    stat["isreg"].as_bool.should be_true
    stat["isdir"].as_bool.should be_false
    stat["islnk"].as_bool.should be_false
    stat["mode"].as_s.should eq("0644")
    stat["size"].as_i64.should eq(17)
    stat["rusr"].as_bool.should be_true
    stat["wusr"].as_bool.should be_true
    stat["xusr"].as_bool.should be_false
    stat["checksum"].as_s.should eq(`sha1sum #{path}`.split(" ").first)
  end

  it "reports isdir: true for a directory and omits checksum" do
    path = tmp_path("stat-dir")
    Dir.mkdir_p(path)

    result = PluginSpecHelper.run("stat", {"path" => path})
    stat = result["stat"]

    stat["isdir"].as_bool.should be_true
    stat["isreg"].as_bool.should be_false
    stat.as_h.has_key?("checksum").should be_false
  end

  it "stats the link itself (not the target) when follow is not set" do
    target = tmp_path("stat-link-target.txt")
    link = tmp_path("stat-link.txt")
    File.write(target, "target")
    File.delete(link) if File.exists?(link)
    File.symlink(target, link)

    result = PluginSpecHelper.run("stat", {"path" => link})
    stat = result["stat"]

    stat["islnk"].as_bool.should be_true
    stat["isreg"].as_bool.should be_false
    stat["lnk_source"].as_s.should eq(target)
    stat.as_h.has_key?("checksum").should be_false
  end

  it "follows the symlink to the target when follow: true" do
    target = tmp_path("stat-follow-target.txt")
    link = tmp_path("stat-follow-link.txt")
    File.write(target, "followed")
    File.delete(link) if File.exists?(link)
    File.symlink(target, link)

    result = PluginSpecHelper.run("stat", {"path" => link, "follow" => "true"})
    stat = result["stat"]

    stat["islnk"].as_bool.should be_false
    stat["isreg"].as_bool.should be_true
    stat.as_h.has_key?("lnk_source").should be_false
  end

  it "skips the checksum when get_checksum: false" do
    path = tmp_path("stat-no-checksum.txt")
    File.write(path, "no checksum please")

    result = PluginSpecHelper.run("stat", {"path" => path, "get_checksum" => "false"})

    result["stat"].as_h.has_key?("checksum").should be_false
  end

  it "uses the requested checksum_algorithm" do
    path = tmp_path("stat-sha256.txt")
    File.write(path, "sha256 me")

    result = PluginSpecHelper.run("stat", {"path" => path, "checksum_algorithm" => "sha256"})

    result["stat"]["checksum"].as_s.should eq(`sha256sum #{path}`.split(" ").first)
  end

  it "fails with a clear message when path is missing" do
    result = PluginSpecHelper.run("stat", {} of String => String)

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should contain("path")
  end

  it "never reports changed, even for an existing writable file" do
    path = tmp_path("stat-never-changed.txt")
    File.write(path, "x")

    result = PluginSpecHelper.run("stat", {"path" => path})

    result["changed"].as_bool.should be_false
  end

  it "includes mimetype/charset by default (get_mime defaults to true, matching real Ansible)" do
    path = tmp_path("stat-mime.txt")
    File.write(path, "hello")

    result = PluginSpecHelper.run("stat", {"path" => path})
    stat = result["stat"]

    stat.as_h.has_key?("mimetype").should be_true
    stat.as_h.has_key?("charset").should be_true
    stat["mimetype"].as_s.should_not be_empty
  end

  it "omits mimetype/charset when get_mime: false" do
    path = tmp_path("stat-no-mime.txt")
    File.write(path, "hello")

    result = PluginSpecHelper.run("stat", {"path" => path, "get_mime" => "false"})

    result["stat"].as_h.has_key?("mimetype").should be_false
    result["stat"].as_h.has_key?("charset").should be_false
  end

  it "includes attr_flags/attributes by default (get_attributes defaults to true, matching real Ansible)" do
    path = tmp_path("stat-attrs.txt")
    File.write(path, "hello")

    result = PluginSpecHelper.run("stat", {"path" => path})
    stat = result["stat"]

    stat.as_h.has_key?("attr_flags").should be_true
    stat.as_h.has_key?("attributes").should be_true
    stat.as_h.has_key?("version").should be_true
    stat["attributes"].as_a.should be_a(Array(JSON::Any))
  end

  it "omits attr_flags/attributes/version when get_attributes: false" do
    path = tmp_path("stat-no-attrs.txt")
    File.write(path, "hello")

    result = PluginSpecHelper.run("stat", {"path" => path, "get_attributes" => "false"})

    result["stat"].as_h.has_key?("attr_flags").should be_false
    result["stat"].as_h.has_key?("attributes").should be_false
    result["stat"].as_h.has_key?("version").should be_false
  end
end
