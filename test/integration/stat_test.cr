require "../minitest_helper"
require "file_utils"

# The classic suite pre-created a shared spec/tmp in before_suite; the
# minitest suite gives every test its own tmp_path subtree instead.
private def tmp_path(name : String) : String
  PluginSpecHelper.tmp_path(name)
end

describe "stat plugin" do
  serial!

  it "reports exists: false for a missing path, with nothing else in the stat dict" do
    result = PluginSpecHelper.run("stat", {"path" => tmp_path("does-not-exist.txt")})

    falsey?(result["failed"]?.try(&.as_bool)).must_equal(true)
    result["changed"].as_bool.must_equal(false)
    result["stat"]["exists"].as_bool.must_equal(false)
    result["stat"].as_h.size.must_equal(1)
  end

  it "expands a leading ~ in path using $HOME (Ansible's stat module is type: path)" do
    original_home = ENV["HOME"]?
    home = File.join(Dir.tempdir, "crystal_ansible_spec_home_#{Random.rand(100_000)}")
    Dir.mkdir_p(home)
    ENV["HOME"] = home
    File.write(File.join(home, "tilde_stat.txt"), "x")
    begin
      result = PluginSpecHelper.run("stat", {"path" => "~/tilde_stat.txt"})

      result["stat"]["exists"].as_bool.must_equal(true)
    ensure
      FileUtils.rm_rf(home)
      ENV["HOME"] = original_home if original_home
    end
  end

  it "reports file attributes for a regular file, matching Ansible's stat module field shapes" do
    path = tmp_path("stat-file.txt")
    File.write(path, "hello vault world")
    File.chmod(path, 0o644)

    result = PluginSpecHelper.run("stat", {"path" => path})
    stat = result["stat"]

    stat["exists"].as_bool.must_equal(true)
    stat["isreg"].as_bool.must_equal(true)
    stat["isdir"].as_bool.must_equal(false)
    stat["islnk"].as_bool.must_equal(false)
    stat["mode"].as_s.must_equal("0644")
    stat["size"].as_i64.must_equal(17)
    stat["rusr"].as_bool.must_equal(true)
    stat["wusr"].as_bool.must_equal(true)
    stat["xusr"].as_bool.must_equal(false)
    stat["checksum"].as_s.must_equal(`sha1sum #{path}`.split(" ").first)
  end

  it "reports isdir: true for a directory and omits checksum" do
    path = tmp_path("stat-dir")
    Dir.mkdir_p(path)

    result = PluginSpecHelper.run("stat", {"path" => path})
    stat = result["stat"]

    stat["isdir"].as_bool.must_equal(true)
    stat["isreg"].as_bool.must_equal(false)
    stat.as_h.has_key?("checksum").must_equal(false)
  end

  it "stats the link itself (not the target) when follow is not set" do
    target = tmp_path("stat-link-target.txt")
    link = tmp_path("stat-link.txt")
    File.write(target, "target")
    # delete? not exists?: exists? follows the link, so a leftover DANGLING
    # symlink (its target gone) survives the cleanup and the symlink below
    # fails with AlreadyExistsError on any non-fresh checkout.
    File.delete?(link)
    File.symlink(target, link)

    result = PluginSpecHelper.run("stat", {"path" => link})
    stat = result["stat"]

    stat["islnk"].as_bool.must_equal(true)
    stat["isreg"].as_bool.must_equal(false)
    stat["lnk_source"].as_s.must_equal(target)
    stat.as_h.has_key?("checksum").must_equal(false)
  end

  it "follows the symlink to the target when follow: true" do
    target = tmp_path("stat-follow-target.txt")
    link = tmp_path("stat-follow-link.txt")
    File.write(target, "followed")
    File.delete?(link)
    File.symlink(target, link)

    result = PluginSpecHelper.run("stat", {"path" => link, "follow" => "true"})
    stat = result["stat"]

    stat["islnk"].as_bool.must_equal(false)
    stat["isreg"].as_bool.must_equal(true)
    stat.as_h.has_key?("lnk_source").must_equal(false)
  end

  it "skips the checksum when get_checksum: false" do
    path = tmp_path("stat-no-checksum.txt")
    File.write(path, "no checksum please")

    result = PluginSpecHelper.run("stat", {"path" => path, "get_checksum" => "false"})

    result["stat"].as_h.has_key?("checksum").must_equal(false)
  end

  it "uses the requested checksum_algorithm" do
    path = tmp_path("stat-sha256.txt")
    File.write(path, "sha256 me")

    result = PluginSpecHelper.run("stat", {"path" => path, "checksum_algorithm" => "sha256"})

    result["stat"]["checksum"].as_s.must_equal(`sha256sum #{path}`.split(" ").first)
  end

  it "fails with a clear message when path is missing" do
    result = PluginSpecHelper.run("stat", {} of String => String)

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal("missing required arguments: path")
  end

  it "never reports changed, even for an existing writable file" do
    path = tmp_path("stat-never-changed.txt")
    File.write(path, "x")

    result = PluginSpecHelper.run("stat", {"path" => path})

    result["changed"].as_bool.must_equal(false)
  end

  it "includes mimetype/charset by default (get_mime defaults to true, matching Ansible)" do
    path = tmp_path("stat-mime.txt")
    File.write(path, "hello")

    result = PluginSpecHelper.run("stat", {"path" => path})
    stat = result["stat"]

    stat.as_h.has_key?("mimetype").must_equal(true)
    stat.as_h.has_key?("charset").must_equal(true)
    stat["mimetype"].as_s.wont_be_empty
  end

  it "omits mimetype/charset when get_mime: false" do
    path = tmp_path("stat-no-mime.txt")
    File.write(path, "hello")

    result = PluginSpecHelper.run("stat", {"path" => path, "get_mime" => "false"})

    result["stat"].as_h.has_key?("mimetype").must_equal(false)
    result["stat"].as_h.has_key?("charset").must_equal(false)
  end

  it "includes attr_flags/attributes by default (get_attributes defaults to true, matching Ansible)" do
    path = tmp_path("stat-attrs.txt")
    File.write(path, "hello")

    result = PluginSpecHelper.run("stat", {"path" => path})
    stat = result["stat"]

    stat.as_h.has_key?("attr_flags").must_equal(true)
    stat.as_h.has_key?("attributes").must_equal(true)
    stat.as_h.has_key?("version").must_equal(true)
    stat["attributes"].as_a.must_be_instance_of(Array(JSON::Any))
  end

  it "omits attr_flags/attributes/version when get_attributes: false" do
    path = tmp_path("stat-no-attrs.txt")
    File.write(path, "hello")

    result = PluginSpecHelper.run("stat", {"path" => path, "get_attributes" => "false"})

    result["stat"].as_h.has_key?("attr_flags").must_equal(false)
    result["stat"].as_h.has_key?("attributes").must_equal(false)
    result["stat"].as_h.has_key?("version").must_equal(false)
  end

  it "accepts path's documented dest/name aliases (Ansible's argument_spec)" do
    target = tmp_path("stat-alias-dest.txt")
    File.write(target, "via alias")

    {"dest" => target, "name" => target}.each do |alias_name, aliased_path|
      result = PluginSpecHelper.run("stat", {"path" => tmp_path("stat-alias-missing.txt"), alias_name => aliased_path})

      result["stat"]["exists"].as_bool.must_equal(true)
    end
  end

  it "resolves alias precedence like Ansible: any alias beats the canonical, last alias in the spec wins" do
    canonical = tmp_path("stat-prec-canonical.txt")
    last_alias = tmp_path("stat-prec-last-alias.txt")
    File.write(canonical, "canonical")
    File.write(last_alias, "last alias")

    # Ansible's _handle_aliases overwrites the canonical name with
    # each present alias in spec order, so `name` (path's last alias)
    # beats `dest`, which beats `path`. Live-verified against
    # ansible-core 2.19.4 with three different paths.
    result = PluginSpecHelper.run("stat", {
      "path" => tmp_path("stat-prec-missing.txt"),
      "dest" => canonical,
      "name" => last_alias,
    })

    result["stat"]["exists"].as_bool.must_equal(true)
    result["stat"]["checksum"].as_s.must_equal(`sha1sum #{last_alias}`.split(" ").first)
  end

  it "lets a checksum alias beat the canonical checksum_algorithm (Ansible alias precedence)" do
    path = tmp_path("stat-checksum-alias.txt")
    File.write(path, "alias wins")

    result = PluginSpecHelper.run("stat", {
      "path"               => path,
      "checksum_algorithm" => "sha256",
      "checksum"           => "md5",
    })

    result["stat"]["checksum"].as_s.must_equal(`md5sum #{path}`.split(" ").first)
  end

  it "applies the get_mime mime_type alias (later in the spec's alias list than mime, so it wins)" do
    path = tmp_path("stat-mime-alias.txt")
    File.write(path, "hello")

    result = PluginSpecHelper.run("stat", {"path" => path, "get_mime" => "false", "mime" => "false", "mime_type" => "true"})

    result["stat"].as_h.has_key?("mimetype").must_equal(true)
  end

  it "applies the get_attributes attr/attributes aliases" do
    path = tmp_path("stat-attrs-alias.txt")
    File.write(path, "hello")

    result = PluginSpecHelper.run("stat", {"path" => path, "get_attributes" => "false", "attr" => "true"})
    result["stat"].as_h.has_key?("attr_flags").must_equal(true)

    result = PluginSpecHelper.run("stat", {"path" => path, "get_attributes" => "false", "attributes" => "true"})
    result["stat"].as_h.has_key?("attr_flags").must_equal(true)
  end

  it "fails with Ansible's invalid-choice message for an unknown checksum_algorithm" do
    path = tmp_path("stat-bad-algo.txt")
    File.write(path, "x")

    result = PluginSpecHelper.run("stat", {"path" => path, "checksum_algorithm" => "sha3"})

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal(
      "value of checksum_algorithm must be one of: md5, sha1, sha224, sha256, sha384, sha512, got: sha3"
    )
  end

  it "accepts y/n as bool spellings for follow/get_mime (Ansible's boolean coercion)" do
    path = tmp_path("stat-yn-bool.txt")
    File.write(path, "yn")

    result = PluginSpecHelper.run("stat", {"path" => path, "get_mime" => "n"})
    result["stat"].as_h.has_key?("mimetype").must_equal(false)

    link = tmp_path("stat-yn-link.txt")
    File.delete?(link)
    File.symlink(path, link)
    result = PluginSpecHelper.run("stat", {"path" => link, "follow" => "y"})
    result["stat"]["islnk"].as_bool.must_equal(false)
    result["stat"]["isreg"].as_bool.must_equal(true)
  end
end

# ansible-core 2.19.11's registered stat result runs changed, stat,
# failed (failed: false appended by _return_formatted) - live-verified
# via `{{ r | to_json }}` on a registered stat: task (the -v dump sorts
# alphabetically, so the order is only observable programmatically).
# krikri's wire result carries no `failed` key on success (PluginResult
# only emits it when failed or failed_flag is set), so the pinned order
# below covers the keys krikri actually emits, in Ansible's relative order.
describe "stat plugin result key order" do
  it "serializes the existing-path result in real stat's key order" do
    path = tmp_path("stat-order.txt")
    File.write(path, "order")

    result = PluginSpecHelper.run("stat", {"path" => path})

    result["changed"].as_bool.must_equal(false)
    result.as_h.keys.must_equal(["changed", "stat"])
  ensure
    File.delete(path) if path && File.exists?(path)
  end

  it "serializes the missing-path result in real stat's key order" do
    result = PluginSpecHelper.run("stat", {"path" => tmp_path("stat-order-missing.txt")})

    result.as_h.keys.must_equal(["changed", "stat"])
    result["stat"].as_h.keys.must_equal(["exists"])
  end
end
