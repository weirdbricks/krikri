require "../spec_helper"
require "file_utils"

# Result-shape pass for `subversion:`'s before/after fields, verified
# live against real ansible-core (2.19/2.21 - the module's success-shape
# code is identical in both):
#
#   fresh checkout:   {"changed": true, "before": null,
#                      "after": ["Revision: 3", "URL: file:///..."]}
#   idempotent rerun: {"changed": false, "before": [..], "after": [..]}
#   pinned checkout:  same as fresh (before: null, after = pinned pair)
#   export:           {"changed": true} - no before/after, no msg
#   update r2->r3:    {"changed": true, "before": [..], "after": [..]}
#
# No success path ever carries a `msg` (real Ansible's subversion.py
# only passes msg to fail_json). before/after is a two-element
# [revision-line, URL-line] pair from `svn info` (real get_revision()
# returns a 2-tuple), and check mode on an existing working copy
# reports bare "Revision: N" strings instead (real needs_update()).
#
# Every svn invocation goes through a shim `svn` on PATH (via
# `environment:`, forwarded as the `_environment` param blob).

private def shim_dir(name : String) : String
  dir = File.join(Dir.tempdir, "krikri-svn-shape-#{name}-#{Random.rand(1_000_000)}")
  FileUtils.mkdir_p(dir)
  dir
end

private def write_svn_shim(dir : String, log : String) : String
  shim = File.join(dir, "svn")
  File.write(shim, <<-'SHIM')
    #!/bin/sh
    echo "$@" >> "$KRIKRI_SVN_CALLS"
    case "$1" in
      update|switch|checkout|export) touch "$KRIKRI_SVN_STATE" ;;
    esac
    case "$1" in
      info)
        case "$*" in
          *' -r HEAD'*) echo "Revision: 99" ;;
          *)
            if [ -f "$KRIKRI_SVN_STATE" ]; then
              echo "Revision: 99"
            else
              echo "Revision: 42"
            fi
            ;;
        esac
        echo "URL: svn+ssh://example.com/repo"
        ;;
      checkout|export|switch|update)
        echo "U    file.txt"
        ;;
    esac
    exit 0
    SHIM
  File.chmod(shim, 0o755)
  File.touch(log)
  shim
end

private def run_subversion(dir : String, log : String, params : Hash(String, String)) : JSON::Any
  PluginSpecHelper.run("subversion", params.merge({
    "_environment" => {
      "PATH"             => "#{dir}:/usr/bin:/bin",
      "KRIKRI_SVN_CALLS" => log,
      "KRIKRI_SVN_STATE" => File.join(dir, "state"),
    }.to_json,
  }), vars: {"ansible_connection" => "local"})
end

describe "subversion plugin - result shape" do
  it "fresh checkout reports before: null and the [revision, URL] after pair, with no msg" do
    dir = shim_dir("fresh-checkout")
    log = File.join(dir, "calls.log")
    write_svn_shim(dir, log)

    result = run_subversion(dir, log, {
      "repo" => "svn+ssh://example.com/repo",
      "dest" => File.join(dir, "wc"),
    })

    result["changed"].as_bool.should be_truthy
    result["before"].as_nil.should be_nil
    result["after"].as_a.map(&.as_s).should eq([
      "Revision: 99",
      "URL: svn+ssh://example.com/repo",
    ])
    result.as_h.has_key?("msg").should be_falsey
  ensure
    FileUtils.rm_rf(dir) if dir
  end

  it "pinned-revision checkout has the same before: null shape" do
    dir = shim_dir("pinned-checkout")
    log = File.join(dir, "calls.log")
    write_svn_shim(dir, log)

    result = run_subversion(dir, log, {
      "repo"     => "svn+ssh://example.com/repo",
      "dest"     => File.join(dir, "wc"),
      "revision" => "2",
    })

    result["changed"].as_bool.should be_truthy
    result["before"].as_nil.should be_nil
    result["after"].as_a.map(&.as_s).should eq([
      "Revision: 99",
      "URL: svn+ssh://example.com/repo",
    ])
    result.as_h.has_key?("msg").should be_falsey
  ensure
    FileUtils.rm_rf(dir) if dir
  end

  it "idempotent re-run at the target revision reports [revision, URL] before/after pairs" do
    dir = shim_dir("idempotent")
    log = File.join(dir, "calls.log")
    write_svn_shim(dir, log)
    FileUtils.touch(File.join(dir, "state"))
    FileUtils.mkdir_p(File.join(dir, "wc", ".svn"))

    result = run_subversion(dir, log, {
      "repo" => "svn+ssh://example.com/repo",
      "dest" => File.join(dir, "wc"),
    })

    result["changed"].as_bool.should be_falsey
    result["before"].as_a.map(&.as_s).should eq([
      "Revision: 99",
      "URL: svn+ssh://example.com/repo",
    ])
    result["after"].as_a.should eq(result["before"].as_a)
    result.as_h.has_key?("msg").should be_falsey
  ensure
    FileUtils.rm_rf(dir) if dir
  end

  it "export reports only changed, with no before, after, or msg" do
    dir = shim_dir("export-shape")
    log = File.join(dir, "calls.log")
    write_svn_shim(dir, log)

    result = run_subversion(dir, log, {
      "repo"   => "svn+ssh://example.com/repo",
      "dest"   => File.join(dir, "export-dest"),
      "export" => "yes",
    })

    result.as_h.should eq({"changed" => JSON::Any.new(true)})
  ensure
    FileUtils.rm_rf(dir) if dir
  end

  it "check mode on an existing working copy reports bare Revision strings" do
    dir = shim_dir("check-mode-shape")
    log = File.join(dir, "calls.log")
    write_svn_shim(dir, log)
    FileUtils.touch(File.join(dir, "state"))
    FileUtils.mkdir_p(File.join(dir, "wc", ".svn"))

    result = run_subversion(dir, log, {
      "repo"                => "svn+ssh://example.com/repo",
      "dest"                => File.join(dir, "wc"),
      "_ansible_check_mode" => "yes",
      "switch"              => "no",
    })

    result["changed"].as_bool.should be_falsey
    result["before"].as_s.should eq("Revision: 99")
    result["after"].as_s.should eq("Revision: 99")
    result.as_h.has_key?("msg").should be_falsey
  ensure
    FileUtils.rm_rf(dir) if dir
  end

  it "update=no and checkout=no no-ops report only changed, with no msg" do
    dir = shim_dir("no-op-shape")
    log = File.join(dir, "calls.log")
    write_svn_shim(dir, log)
    FileUtils.touch(File.join(dir, "state"))
    FileUtils.mkdir_p(File.join(dir, "wc", ".svn"))

    result = run_subversion(dir, log, {
      "repo"   => "svn+ssh://example.com/repo",
      "dest"   => File.join(dir, "wc"),
      "update" => "no",
    })
    result.as_h.has_key?("msg").should be_falsey

    result = run_subversion(dir, log, {
      "repo"     => "svn+ssh://example.com/repo",
      "dest"     => File.join(dir, "absent-wc"),
      "checkout" => "no",
    })
    result["changed"].as_bool.should be_falsey
    result.as_h.has_key?("msg").should be_falsey
  ensure
    FileUtils.rm_rf(dir) if dir
  end
end
