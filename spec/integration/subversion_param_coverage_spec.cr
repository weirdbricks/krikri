require "../spec_helper"
require "file_utils"

# Parameter-coverage pass for `subversion:`'s real-Ansible boolean gates:
# checkout / update / switch / export / in_place / validate_certs, plus
# dest becoming optional when checkout=no, update=no, and export=no.
#
# Every svn invocation here goes through a shim `svn` on PATH (via
# `environment:`, forwarded as the `_environment` param blob) that logs
# its argv and prints canned output - nothing here talks to a real svn
# server or network.

private def shim_dir(name : String) : String
  dir = File.join(Dir.tempdir, "krikri-svn-#{name}-#{Random.rand(1_000_000)}")
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

private def calls(log : String) : Array(String)
  File.read_lines(log)
end

describe "subversion plugin - parameter coverage" do
  it "checkout=no skips checkout when dest has no working copy yet" do
    dir = shim_dir("checkout-no")
    log = File.join(dir, "calls.log")
    write_svn_shim(dir, log)

    result = run_subversion(dir, log, {
      "repo"     => "svn+ssh://example.com/repo",
      "dest"     => File.join(dir, "wc"),
      "checkout" => "no",
    })

    result["failed"]?.try(&.as_bool).should be_falsey
    result["changed"].as_bool.should be_falsey
    calls(log).should be_empty
  ensure
    FileUtils.rm_rf(dir) if dir
  end

  it "checkout defaults to true: a missing dest gets checked out" do
    dir = shim_dir("checkout-yes")
    log = File.join(dir, "calls.log")
    write_svn_shim(dir, log)

    result = run_subversion(dir, log, {
      "repo" => "svn+ssh://example.com/repo",
      "dest" => File.join(dir, "wc"),
    })

    result["changed"].as_bool.should be_truthy
    calls(log).any?(&.starts_with?("checkout")).should be_truthy
  ensure
    FileUtils.rm_rf(dir) if dir
  end

  it "check mode with a missing dest reports changed without running checkout" do
    dir = shim_dir("check-mode")
    log = File.join(dir, "calls.log")
    write_svn_shim(dir, log)

    result = run_subversion(dir, log, {
      "repo"       => "svn+ssh://example.com/repo",
      "dest"       => File.join(dir, "wc"),
      "_ansible_check_mode" => "yes",
    })

    result["changed"].as_bool.should be_truthy
    calls(log).should be_empty
  ensure
    FileUtils.rm_rf(dir) if dir
  end

  it "dest is optional when checkout=no, update=no, and export=no (info-only)" do
    dir = shim_dir("no-dest")
    log = File.join(dir, "calls.log")
    write_svn_shim(dir, log)

    result = run_subversion(dir, log, {
      "repo"     => "svn+ssh://example.com/repo",
      "checkout" => "no",
      "update"   => "no",
      "export"   => "no",
    })

    result["failed"]?.try(&.as_bool).should be_falsey
    result["changed"].as_bool.should be_falsey
    result["after"].as_s.should eq("Revision: 42")
  ensure
    FileUtils.rm_rf(dir) if dir
  end

  it "dest is required whenever checkout, update, or export is enabled" do
    result = PluginSpecHelper.run("subversion", {
      "repo"   => "svn+ssh://example.com/repo",
      "update" => "yes",
    })

    result["failed"].as_bool.should be_truthy
    result["msg"].as_s.should contain("destination directory")
  end

  it "update=no skips svn update on an existing working copy" do
    dir = shim_dir("update-no")
    log = File.join(dir, "calls.log")
    write_svn_shim(dir, log)
    wc = File.join(dir, "wc")
    FileUtils.mkdir_p(File.join(wc, ".svn"))

    result = run_subversion(dir, log, {
      "repo"   => "svn+ssh://example.com/repo",
      "dest"   => wc,
      "update" => "no",
    })

    result["failed"]?.try(&.as_bool).should be_falsey
    result["changed"].as_bool.should be_falsey
    calls(log).should be_empty
  ensure
    FileUtils.rm_rf(dir) if dir
  end

  it "update defaults to true and runs svn update on an existing working copy" do
    dir = shim_dir("update-yes")
    log = File.join(dir, "calls.log")
    write_svn_shim(dir, log)
    wc = File.join(dir, "wc")
    FileUtils.mkdir_p(File.join(wc, ".svn"))

    result = run_subversion(dir, log, {
      "repo" => "svn+ssh://example.com/repo",
      "dest" => wc,
    })

    result["changed"].as_bool.should be_truthy
    calls(log).any?(&.starts_with?("update")).should be_truthy
    calls(log).any?(&.starts_with?("switch")).should be_falsey
  ensure
    FileUtils.rm_rf(dir) if dir
  end

  it "switch=no skips svn switch even when the working copy URL differs" do
    dir = shim_dir("switch-no")
    log = File.join(dir, "calls.log")
    write_svn_shim(dir, log)
    wc = File.join(dir, "wc")
    FileUtils.mkdir_p(File.join(wc, ".svn"))

    result = run_subversion(dir, log, {
      "repo"   => "svn+ssh://example.com/other-repo",
      "dest"   => wc,
      "switch" => "no",
    })

    result["failed"]?.try(&.as_bool).should be_falsey
    calls(log).any?(&.starts_with?("switch")).should be_falsey
    calls(log).any?(&.starts_with?("update")).should be_truthy
  ensure
    FileUtils.rm_rf(dir) if dir
  end

  it "switch defaults to true: a URL mismatch runs svn switch" do
    dir = shim_dir("switch-yes")
    log = File.join(dir, "calls.log")
    write_svn_shim(dir, log)
    wc = File.join(dir, "wc")
    FileUtils.mkdir_p(File.join(wc, ".svn"))

    result = run_subversion(dir, log, {
      "repo" => "svn+ssh://example.com/other-repo",
      "dest" => wc,
    })

    result["failed"]?.try(&.as_bool).should be_falsey
    calls(log).any?(&.starts_with?("switch")).should be_truthy
  ensure
    FileUtils.rm_rf(dir) if dir
  end

  it "export=yes runs svn export instead of checkout" do
    dir = shim_dir("export-yes")
    log = File.join(dir, "calls.log")
    write_svn_shim(dir, log)
    dest = File.join(dir, "export-dest")
    FileUtils.mkdir_p(dest)

    result = run_subversion(dir, log, {
      "repo"   => "svn+ssh://example.com/repo",
      "dest"   => dest,
      "export" => "yes",
    })

    result["failed"]?.try(&.as_bool).should be_falsey
    result["changed"].as_bool.should be_truthy
    calls(log).any?(&.starts_with?("export")).should be_truthy
    calls(log).any?(&.starts_with?("checkout")).should be_falsey
  ensure
    FileUtils.rm_rf(dir) if dir
  end

  it "export=yes passes --force when force=yes" do
    dir = shim_dir("export-force")
    log = File.join(dir, "calls.log")
    write_svn_shim(dir, log)

    result = run_subversion(dir, log, {
      "repo"   => "svn+ssh://example.com/repo",
      "dest"   => File.join(dir, "export-dest"),
      "export" => "yes",
      "force"  => "yes",
    })

    result["failed"]?.try(&.as_bool).should be_falsey
    export_call = calls(log).find!(&.starts_with?("export"))
    export_call.should contain("--force")
  ensure
    FileUtils.rm_rf(dir) if dir
  end

  it "an existing non-svn dest directory fails without in_place" do
    dir = shim_dir("not-repo")
    log = File.join(dir, "calls.log")
    write_svn_shim(dir, log)
    dest = File.join(dir, "dest")
    FileUtils.mkdir_p(dest)

    result = run_subversion(dir, log, {
      "repo" => "svn+ssh://example.com/repo",
      "dest" => dest,
    })

    result["failed"].as_bool.should be_truthy
    result["msg"].as_s.should contain("not a subversion repository")
  ensure
    FileUtils.rm_rf(dir) if dir
  end

  it "in_place=yes re-checks out over an existing non-svn directory" do
    dir = shim_dir("in-place")
    log = File.join(dir, "calls.log")
    write_svn_shim(dir, log)
    dest = File.join(dir, "dest")
    FileUtils.mkdir_p(dest)

    result = run_subversion(dir, log, {
      "repo"     => "svn+ssh://example.com/repo",
      "dest"     => dest,
      "in_place" => "yes",
    })

    result["failed"]?.try(&.as_bool).should be_falsey
    result["changed"].as_bool.should be_truthy
    checkout_call = calls(log).find!(&.starts_with?("checkout"))
    checkout_call.should contain("--force")
  ensure
    FileUtils.rm_rf(dir) if dir
  end

  it "validate_certs defaults to no: --trust-server-cert is passed to svn" do
    dir = shim_dir("certs-default")
    log = File.join(dir, "calls.log")
    write_svn_shim(dir, log)

    result = run_subversion(dir, log, {
      "repo" => "svn+ssh://example.com/repo",
      "dest" => File.join(dir, "wc"),
    })

    result["failed"]?.try(&.as_bool).should be_falsey
    calls(log).join("\n").should contain("--trust-server-cert")
  ensure
    FileUtils.rm_rf(dir) if dir
  end

  it "validate_certs=yes omits --trust-server-cert" do
    dir = shim_dir("certs-yes")
    log = File.join(dir, "calls.log")
    write_svn_shim(dir, log)

    result = run_subversion(dir, log, {
      "repo"           => "svn+ssh://example.com/repo",
      "dest"           => File.join(dir, "wc"),
      "validate_certs" => "yes",
    })

    result["failed"]?.try(&.as_bool).should be_falsey
    calls(log).join("\n").should_not contain("--trust-server-cert")
  ensure
    FileUtils.rm_rf(dir) if dir
  end
end
