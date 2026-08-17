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

  # A zip containing a symlink member (`zip -y` stores it as an actual
  # symlink, matching how e.g. square/sudo_pair's own GitHub release
  # archive links a shared LICENSE/README into several sub-crate dirs) -
  # regression fixture for zip_changed?'s own symlink handling.
  Dir.mkdir_p(File.join(TMP_DIR, "symlink_src"))
  File.write(File.join(TMP_DIR, "symlink_src", "real.txt"), "real content")
  File.symlink("real.txt", File.join(TMP_DIR, "symlink_src", "link.txt"))
  `cd #{File.join(TMP_DIR, "symlink_src")} && zip -qy #{File.join(TMP_DIR, "symlink.zip")} real.txt link.txt`

  # A GitHub-release-shaped archive: everything nested one level down
  # inside a single top-level directory (`myproject-1.0/...`), the shape
  # extra_opts: ['--strip-components=1'] exists to flatten.
  Dir.mkdir_p(File.join(TMP_DIR, "wrapped", "myproject-1.0"))
  File.write(File.join(TMP_DIR, "wrapped", "myproject-1.0", "index.php"), "<?php")
  `tar czf #{File.join(TMP_DIR, "wrapped.tar.gz")} -C #{File.join(TMP_DIR, "wrapped")} myproject-1.0`
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

  it "applies mode: recursively to every extracted file, not just dest itself" do
    # Real bug found benchmarking robertdebock.nextcloud: `owner:`/
    # `group:` used to only ever be applied to the DESTINATION
    # DIRECTORY itself (a `chown #{owner} #{dest}`, no `-R`), while
    # real ansible-playbook's own unarchive module does a final
    # os.walk()-based pass applying owner:/group:/mode: to every
    # extracted path. Left everything but dest itself at its
    # archive-native ownership - broke a role's downstream `occ`
    # commands relying on the extracted tree being fully owned by the
    # web server user ("Cannot write into 'apps' directory"). Using
    # mode: here (not owner:/group:) since the spec runs as a normal
    # user and can't chown to an arbitrary user/group without root.
    dest = fresh_dest("tar-recursive-mode")
    result = PluginSpecHelper.run("unarchive", {
      "src"  => File.join(TMP_DIR, "archive.tar.gz"),
      "dest" => dest,
      "mode" => "0700",
    })

    result["changed"].as_bool.should be_true
    (File.info(dest).permissions.value & 0o777).should eq(0o700)
    (File.info(File.join(dest, "a.txt")).permissions.value & 0o777).should eq(0o700)
    (File.info(File.join(dest, "sub", "b.txt")).permissions.value & 0o777).should eq(0o700)
  end

  it "fails the task when owner: can't actually be applied, instead of silently succeeding" do
    # Proactive audit fix (same "real command failure silently
    # discarded" shape as apt_repository.cr's own update_cache bug and
    # sysctl.cr's own apply_kernel_value bug found this round):
    # apply_dest_attributes used to discard chown/chgrp/chmod's exit
    # code entirely - a bogus owner: name (a real, common typo/stale-
    # variable mistake) silently "succeeded" instead of failing the
    # task, matching real Ansible's own AnsibleModule.set_owner_if_
    # different behavior of failing on a real chown error.
    dest = fresh_dest("tar-bad-owner")
    result = PluginSpecHelper.run("unarchive", {
      "src"   => File.join(TMP_DIR, "archive.tar.gz"),
      "dest"  => dest,
      "owner" => "crystal_ansible_spec_nonexistent_user",
    })

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should contain("owner")
  end

  it "reports changed: false on an idempotent rerun (tar --compare based)" do
    dest = fresh_dest("tar-idempotent")
    PluginSpecHelper.run("unarchive", {"src" => File.join(TMP_DIR, "archive.tar.gz"), "dest" => dest})

    result = PluginSpecHelper.run("unarchive", {"src" => File.join(TMP_DIR, "archive.tar.gz"), "dest" => dest})

    result["changed"].as_bool.should be_false
  end

  it "honors extra_opts: ['--strip-components=1'] to flatten a wrapped archive" do
    # Real bug found benchmarking robertdebock.phpmyadmin: extra_opts was
    # entirely unimplemented (silently dropped), so a role unpacking a
    # GitHub-release-style tarball (single top-level wrapper dir) got
    # that wrapper dir preserved instead of stripped - every file the
    # role expected directly under dest/ was actually one level deeper
    # and effectively missing (e.g. dest/index.php never existed).
    dest = fresh_dest("tar-strip-components")
    result = PluginSpecHelper.run("unarchive", {"src" => File.join(TMP_DIR, "wrapped.tar.gz"), "dest" => dest, "extra_opts" => "--strip-components=1"})

    result["changed"].as_bool.should be_true
    File.exists?(File.join(dest, "myproject-1.0")).should be_false
    File.read(File.join(dest, "index.php")).should eq("<?php")
  end

  it "honors extra_opts: when it arrives as a JSON-array-encoded string, not just the comma-joined literal-list form" do
    # Real bug found live-verifying prometheus.prometheus.node_exporter
    # (round 22): `extra_opts:` in that role's own task is a `{{ }}`-
    # TEMPLATED expression (`"{{ _common_binary_unarchive_opts |
    # default(omit, true) }}"`), not a literal YAML list - a literal
    # list gets comma-joined by playbook_parser.cr's own #stringify_
    # value at parse time (the shape every other test in this file
    # passes), but a templated expression that resolves to an array at
    # RUNTIME instead goes through VariableLookup#format_value, which
    # renders an Array as `value.to_json` - a JSON-array string
    # (`["--strip-components=1"]`), a completely different, unhandled
    # text convention. Splitting THAT on "," left one garbage element
    # still wrapped in brackets/quotes, corrupting the `tar` command
    # line so badly that `tar --compare` silently reported no changes
    # and extraction never ran at all - the archive downloaded and
    # passed its checksum check, but nothing was ever unpacked.
    dest = fresh_dest("tar-strip-components-json-array")
    result = PluginSpecHelper.run("unarchive", {"src" => File.join(TMP_DIR, "wrapped.tar.gz"), "dest" => dest, "extra_opts" => %(["--strip-components=1"])})

    result["changed"].as_bool.should be_true
    File.exists?(File.join(dest, "myproject-1.0")).should be_false
    File.read(File.join(dest, "index.php")).should eq("<?php")
  end

  it "is idempotent on a --strip-components=1 rerun despite tar --compare's own benign warning" do
    # Real bug found benchmarking robertdebock.phpmyadmin: GNU tar
    # --compare always emits a bogus "Cannot stat: No such file or
    # directory" warning (exit code 1) for the stripped-away top-level
    # path whenever --strip-components is used, even when nothing
    # actually differs - a raw exit-code check treats that as "changed"
    # forever. Real ansible-playbook stays changed: false on an
    # identical rerun (confirmed live) because its own is_unarchived()
    # parses tar's output and explicitly ignores this exact warning
    # pattern.
    dest = fresh_dest("tar-strip-components-idempotent")
    PluginSpecHelper.run("unarchive", {"src" => File.join(TMP_DIR, "wrapped.tar.gz"), "dest" => dest, "extra_opts" => "--strip-components=1"})

    result = PluginSpecHelper.run("unarchive", {"src" => File.join(TMP_DIR, "wrapped.tar.gz"), "dest" => dest, "extra_opts" => "--strip-components=1"})

    result["changed"].as_bool.should be_false
  end

  it "still detects a real content change under --strip-components=1" do
    dest = fresh_dest("tar-strip-components-changed")
    PluginSpecHelper.run("unarchive", {"src" => File.join(TMP_DIR, "wrapped.tar.gz"), "dest" => dest, "extra_opts" => "--strip-components=1"})
    File.write(File.join(dest, "index.php"), "<?php /* tampered */")
    File.utime(Time.utc - 1.hour, Time.utc - 1.hour, File.join(dest, "index.php"))

    result = PluginSpecHelper.run("unarchive", {"src" => File.join(TMP_DIR, "wrapped.tar.gz"), "dest" => dest, "extra_opts" => "--strip-components=1"})

    result["changed"].as_bool.should be_true
  end

  it "reports changed: true when an extracted file is modified since the last extraction" do
    dest = fresh_dest("tar-changed")
    PluginSpecHelper.run("unarchive", {"src" => File.join(TMP_DIR, "archive.tar.gz"), "dest" => dest})
    File.write(File.join(dest, "a.txt"), "tampered")
    # tar --compare only flags a real content change via its own "Mod
    # time differs" line - force a >1s mtime skew so the change reliably
    # crosses tar's one-second mtime granularity, matching real
    # ansible-playbook's own TgzArchive#is_unarchived, which has the
    # identical granularity limit (no separate "size differs" signal).
    File.utime(Time.utc - 1.hour, Time.utc - 1.hour, File.join(dest, "a.txt"))

    result = PluginSpecHelper.run("unarchive", {"src" => File.join(TMP_DIR, "archive.tar.gz"), "dest" => dest})

    result["changed"].as_bool.should be_true
  end

  it "is idempotent on a mode: override rerun despite tar --compare's own Mode differs line" do
    # Real bug found benchmarking prometheus.prometheus.alertmanager round
    # 134: its own unarchive task sets `mode: 0755` (applied recursively
    # to every extracted file, matching real ansible-playbook's actual
    # behavior - see this file's header comment) - since the archive's
    # OWN embedded member mode is 0644, `tar --compare` legitimately
    # reports "Mode differs" for those files on every single rerun. Real
    # Ansible's own TgzArchive#is_unarchived (unarchive.py) explicitly
    # ignores a Mode-differs line whenever mode: was itself given on the
    # task (trusting set_fs_attributes_if_different() to have already
    # applied it) - previously unarchive.cr treated every Mode differs
    # line as meaningful unconditionally, making any mode:-overriding
    # unarchive task permanently non-idempotent.
    dest = fresh_dest("tar-mode-override-idempotent")
    PluginSpecHelper.run("unarchive", {"src" => File.join(TMP_DIR, "archive.tar.gz"), "dest" => dest, "mode" => "0755"})

    result = PluginSpecHelper.run("unarchive", {"src" => File.join(TMP_DIR, "archive.tar.gz"), "dest" => dest, "mode" => "0755"})

    result["changed"].as_bool.should be_false
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

  it "reports changed: false on an idempotent zip rerun when a member is a symlink" do
    # Regression: zip_changed? compared a symlink member's DEREFERENCED
    # content (`md5sum < dest_path`, which shell redirection always
    # follows) against the archive's own raw member content (the target
    # path string a zip stores for a symlink entry, e.g. "real.txt") -
    # permanently mismatched even on a byte-correct extraction, so any
    # zip containing a symlink was re-extracted (reported changed: true)
    # on every single run. Found benchmarking robertdebock.sudo_pair's
    # own square/sudo_pair release archive (LICENSE/README symlinked
    # into multiple sub-crate dirs).
    dest = fresh_dest("zip-symlink-idempotent")
    PluginSpecHelper.run("unarchive", {"src" => File.join(TMP_DIR, "symlink.zip"), "dest" => dest})
    File.symlink?(File.join(dest, "link.txt")).should be_true

    result = PluginSpecHelper.run("unarchive", {"src" => File.join(TMP_DIR, "symlink.zip"), "dest" => dest})

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

  it "excludes a member when exclude: is a Python-repr list string, not just JSON" do
    # A Jinja `{% if %}...{{ [list_expr] }}...{% endif %}` template
    # idiom renders as Python's str() form (single-quoted), not JSON -
    # same bug class already found live in apt.cr/package.cr's own
    # name: parsing (round 27), proactively fixed here too.
    dest = fresh_dest("exclude-pyrepr")
    result = PluginSpecHelper.run("unarchive", {"src" => File.join(TMP_DIR, "archive.tar.gz"), "dest" => dest, "exclude" => "['sub/b.txt']"})

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
