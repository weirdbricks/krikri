require "../minitest_helper"
require "file_utils"

# Issue #788 (iancleary.colorls): a `gem:` install whose `gem install` run
# fails (public_suffix 7.0.5 refusing ruby 3.0) diverged from real ansible
# in the failure result's shape, live-diffed vs ansible-playbook 2.17 in an
# ubuntu 22.04 container (ruby 3.0.2):
#   1. krikri prefixed its own "Failed to install gem: " onto the message;
#      real gem.py shells every command through
#      AnsibleModule.run_command(check_rc=True), so the payload is
#      basic.py's own shape - msg IS stderr.rstrip() (trailing newline
#      dropped, no wrapper text);
#   2. krikri's result carried only msg/stdout/stderr; real's run_command
#      failure adds cmd/rc, and _return_formatted adds the
#      stdout_lines/stderr_lines splits.
# The msg trailing newline also leaked into krikri's fatal display as an
# extra blank line before the Origin: block - rstrip-ing msg fixes that.

private def with_failing_gem_shim(&)
  dir = PluginSpecHelper.tmp_path("fake-gem-install-failure")
  FileUtils.rm_r(dir) if File.exists?(dir)
  Dir.mkdir_p(dir)

  File.write(File.join(dir, "gem"), <<-'SH')
    #!/bin/sh
    case "$1" in
      --version) echo "3.3.26"; exit 0;;
      list) exit 0;;
      install)
        printf 'ERROR:  Error installing public_suffix:\n\tpublic_suffix-7.0.5 requires Ruby version >= 3.2. The current ruby version is 3.0.2.107.\n' >&2
        exit 1
        ;;
    esac
    exit 0
    SH
  File.chmod(File.join(dir, "gem"), 0o755)

  begin
    yield File.join(dir, "gem")
  ensure
    FileUtils.rm_r(dir) if File.exists?(dir)
  end
end

describe "gem install failure shape (issue 788)" do
  it "carries run_command's failure payload: msg is rstripped stderr with cmd/rc/stdout/stderr/lines" do
    with_failing_gem_shim do |shim|
      result = PluginSpecHelper.run("gem", {
        "name"       => "public_suffix",
        "executable" => shim,
      })

      result["failed"].as_bool.must_equal(true)
      # No "Failed to install gem:" wrapper, trailing newline stripped -
      # msg is exactly what basic.py's check_rc failure puts there.
      result["msg"].as_s.must_equal(
        "ERROR:  Error installing public_suffix:\n\tpublic_suffix-7.0.5 requires Ruby version >= 3.2. The current ruby version is 3.0.2.107."
      )
      result["cmd"].as_s.must_equal(
        "#{shim} install --norc --user-install --no-document public_suffix"
      )
      result["rc"].as_i.must_equal(1)
      result["stdout"].as_s.must_equal("")
      result["stderr"].as_s.must_equal(
        "ERROR:  Error installing public_suffix:\n\tpublic_suffix-7.0.5 requires Ruby version >= 3.2. The current ruby version is 3.0.2.107.\n"
      )
      result["stdout_lines"].as_a.size.must_equal(0)
      result["stderr_lines"].as_a.size.must_equal(2)
    end
  end
end
