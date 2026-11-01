require "../minitest_helper"
require "digest"
require "system/user"

describe "copy plugin - owner/group" do
  it "actually applies owner: (previously a dead stub, never chown'd at all)" do
    # Real bug found benchmarking cloudalchemy.grafana's own "Create/
    # Update dashboards file (provisioning)" task (copy: content: ...,
    # owner: root, group: grafana) - apply_file_attributes' own owner:/
    # group: handling was a literal no-op stub ("Would need: File.chown
    # - not available in Crystal stdlib", which is simply wrong; file.cr
    # already uses File.chown successfully elsewhere in this codebase).
    # The file silently kept its default group (whatever the process
    # happened to be running as), which meant Grafana's own service user
    # couldn't read its own dashboard provisioning config - the whole
    # service refused to start.
    #
    # No root needed here: chown-ing a file to the CURRENT user's own
    # uid is always permitted, and is enough to exercise the previously-
    # dead code path.
    dest = File.tempname("copy-owner-spec")
    me = (System::User.find_by?(id: LibC.getuid.to_s) || raise "unexpected nil").username

    result = PluginSpecHelper.run("copy", {"content" => "hello\n", "dest" => dest, "owner" => me})

    result["changed"].as_bool.must_equal(true)
    File.info(dest).owner_id.must_equal(LibC.getuid.to_s)
  ensure
    File.delete(dest) if dest && File.exists?(dest)
  end

  it "fails with Ansible's exact message when owner: is an explicit empty string" do
    # Found benchmarking kilip.chezmoi (round900811): an explicit
    # `owner: ""` was silently treated as "no ownership change
    # requested" (the copy succeeded, changed: true) instead of being
    # attempted and failing like Ansible, whose basic.py only
    # skips the chown when the param is None and fails the lookup of an
    # empty name with exactly "chown failed: failed to look up user "
    # (trailing space - the empty name interpolated into basic.py:789's
    # own format string). Verified live against ansible-core 2.19.11
    # before fixing.
    dest = File.tempname("copy-empty-owner-spec")

    result = PluginSpecHelper.run("copy", {"content" => "hello\n", "dest" => dest, "owner" => ""})

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal("chown failed: failed to look up user ")
  ensure
    File.delete(dest) if dest && File.exists?(dest)
  end

  it "fails with Ansible's exact message when group: is an explicit empty string" do
    # Same round900811 bug class as the empty owner: above -
    # Ansible's group analogue is "chgrp failed: failed to look up
    # group " (basic.py:830, chgrp not chown), trailing space included.
    dest = File.tempname("copy-empty-group-spec")

    result = PluginSpecHelper.run("copy", {"content" => "hello\n", "dest" => dest, "group" => ""})

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal("chgrp failed: failed to look up group ")
  ensure
    File.delete(dest) if dest && File.exists?(dest)
  end

  it "keeps path, dest stat and checksum on the failure for an unresolvable owner: over identical content" do
    # Issue #670 (zaiste.essentials "provide default SSH config"): when
    # the dest already holds identical content, Ansible's copy action
    # short-circuits into the file module, whose fail_json(path=...) gets
    # _return_formatted's add_path_info stat block grafted onto the
    # failure, and the action then injects its local_checksum into any
    # result lacking one - failed ones included (live-verified vs
    # 2.19.11). krikri printed a bare {changed, msg} there because the
    # OwnerLookupFailure escaped to run_and_capture.
    src = File.tempname("copy-owner-stat-src")
    dest = File.tempname("copy-owner-stat-dest")
    content = "hello world\n"
    File.write(src, content)
    File.write(dest, content)
    File.chmod(dest, 0o644)

    result = PluginSpecHelper.run("copy",
      {"src" => src, "dest" => dest, "owner" => "this_user_does_not_exist_zzz"})

    result["failed"].as_bool.must_equal(true)
    result["changed"].as_bool.must_equal(false)
    result["msg"].as_s.must_equal("chown failed: failed to look up user this_user_does_not_exist_zzz")
    result["path"].as_s.must_equal(dest)
    result["state"].as_s.must_equal("file")
    result["uid"].as_i64.must_equal(File.info(dest).owner_id.to_i64)
    result["mode"].as_s.must_equal("0644")
    result["size"].as_i64.must_equal(content.bytesize.to_i64)
    result["checksum"].as_s.must_equal(Digest::SHA1.hexdigest(content))
  ensure
    File.delete(src) if src && File.exists?(src)
    File.delete(dest) if dest && File.exists?(dest)
  end

  it "still succeeds when owner:/group: are omitted entirely (the param not given at all)" do
    # The critical no-regression case: only a PRESENT-but-unresolvable
    # value fails now - omitting owner:/group: must behave exactly as
    # before (no lookup attempted, no failure).
    dest = File.tempname("copy-no-attrs-spec")

    result = PluginSpecHelper.run("copy", {"content" => "hello\n", "dest" => dest})

    falsey?(result["failed"]?.try(&.as_bool)).must_equal(true)
    result["changed"].as_bool.must_equal(true)
    File.read(dest).must_equal("hello\n")
  ensure
    File.delete(dest) if dest && File.exists?(dest)
  end
end
