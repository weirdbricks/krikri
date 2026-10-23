require "../minitest_helper"
require "file_utils"

# basic.py's AnsibleModule init (ansible-core 2.19.11) runs _set_cwd before
# any module code: os.access(os.getcwd(), F_OK|R_OK), and when the process
# cwd is not accessible to the process user - a `become_user:` module run
# via sudo from the connecting user's mode-700 login dir - it falls back to
# the tmpdir property, which expands remote_tmp (the ansible_remote_tmp var
# if the task set one, else the ~/.ansible/tmp default) against the process
# HOME and, when that directory does not exist, creates it with mode 0700
# and self.warn()s. The warning rides the module result's `warnings` on
# every fail_json exit too (init precedes validation), prints as a
# [WARNING] line on stderr (after the PLAY RECAP in the role-tester's
# stdout+stderr capture), and is cold-run only because the directory
# persists. Found via HUIT-AcademicTechnology-Ops.ansible-role-splunk-
# universal-forwarder's "accept license and start splunk" shell task with
# become_user: splunk run from /root (issue #251).
#
# Driven through the real plugin binaries: the cwd/remote_tmp check lives
# in the plugin process, so that is the boundary that has to be proven.
# The unreadable cwd is a chmod-311 directory (searchable, not readable; a
# fully 000 cwd crashes the Crystal runtime at startup) the spec process owns, with
# the child chdir'd into it BEFORE the chmod - a running process keeps the
# cwd it entered, exactly how the sudo'd module process keeps /root.
describe "module remote_tmp init fallback warning" do
  it "warns with the created 0700 dir path when the cwd is inaccessible (cold run)" do
    skip "root bypasses the cwd permissions the fallback needs" if PluginSpecHelper.running_as_root?

    locked = PluginSpecHelper.tmp_path("locked-cwd")
    home = PluginSpecHelper.tmp_path("fake-home")
    FileUtils.mkdir_p(locked)
    FileUtils.mkdir_p(home)
    begin
      result = PluginSpecHelper.run("ping", {} of String => String, chdir: locked,
        before_input: -> { File.chmod(locked, 0o311); nil },
        env: {"HOME" => home})

      tmpdir = File.join(home, ".ansible/tmp")
      result["warnings"]?.try(&.as_a?).try(&.map(&.as_s)).must_equal([
        "Module remote_tmp #{tmpdir} did not exist and was created with a mode of 0700, this may cause issues when running as another user. To avoid this, create the remote_tmp dir with the correct permissions manually",
      ])
      File.info?(tmpdir).try(&.permissions.value.to_s(8)).must_equal("700")
    ensure
      File.chmod(locked, 0o755)
      FileUtils.rm_rf(locked)
      FileUtils.rm_rf(home)
    end
  end

  it "stays silent on a warm rerun once the remote_tmp dir persists" do
    skip "root bypasses the cwd permissions the fallback needs" if PluginSpecHelper.running_as_root?

    locked = PluginSpecHelper.tmp_path("locked-cwd")
    home = PluginSpecHelper.tmp_path("fake-home")
    FileUtils.mkdir_p(locked)
    FileUtils.mkdir_p(home)
    begin
      cold = PluginSpecHelper.run("ping", {} of String => String, chdir: locked,
        before_input: -> { File.chmod(locked, 0o311); nil },
        env: {"HOME" => home})
      (cold["warnings"]?.try(&.as_a?) || [] of JSON::Any).size.must_equal(1)

      warm = PluginSpecHelper.run("ping", {} of String => String, chdir: locked,
        before_input: -> { File.chmod(locked, 0o311); nil },
        env: {"HOME" => home})
      warm["warnings"]?.must_be_nil
    ensure
      File.chmod(locked, 0o755)
      FileUtils.rm_rf(locked)
      FileUtils.rm_rf(home)
    end
  end

  it "does not warn or create anything when the cwd is readable" do
    home = PluginSpecHelper.tmp_path("fake-home")
    FileUtils.mkdir_p(home)
    begin
      result = PluginSpecHelper.run("ping", {} of String => String, env: {"HOME" => home})

      result["warnings"]?.must_be_nil
      File.exists?(File.join(home, ".ansible")).must_equal(false)
    ensure
      FileUtils.rm_rf(home)
    end
  end

  it "expands a task-set ansible_remote_tmp var for the created dir path" do
    skip "root bypasses the cwd permissions the fallback needs" if PluginSpecHelper.running_as_root?

    locked = PluginSpecHelper.tmp_path("locked-cwd")
    home = PluginSpecHelper.tmp_path("fake-home")
    FileUtils.mkdir_p(locked)
    FileUtils.mkdir_p(home)
    begin
      result = PluginSpecHelper.run("ping", {} of String => String, vars: {"ansible_remote_tmp" => "~/custom-remote-tmp"},
        chdir: locked,
        before_input: -> { File.chmod(locked, 0o311); nil },
        env: {"HOME" => home})

      basedir = File.join(home, "custom-remote-tmp")
      result["warnings"]?.try(&.as_a?).try(&.map(&.as_s)).must_equal([
        "Module remote_tmp #{basedir} did not exist and was created with a mode of 0700, this may cause issues when running as another user. To avoid this, create the remote_tmp dir with the correct permissions manually",
      ])
      File.info?(basedir).try(&.permissions.value.to_s(8)).must_equal("700")
    ensure
      File.chmod(locked, 0o755)
      FileUtils.rm_rf(locked)
      FileUtils.rm_rf(home)
    end
  end

  it "rides a failing module result too (init precedes any fail_json)" do
    skip "root bypasses the cwd permissions the fallback needs" if PluginSpecHelper.running_as_root?

    locked = PluginSpecHelper.tmp_path("locked-cwd")
    home = PluginSpecHelper.tmp_path("fake-home")
    FileUtils.mkdir_p(locked)
    FileUtils.mkdir_p(home)
    begin
      result = PluginSpecHelper.run("fail", {"msg" => "boom"}, chdir: locked,
        before_input: -> { File.chmod(locked, 0o311); nil },
        env: {"HOME" => home})

      result["failed"].as_bool.must_equal(true)
      tmpdir = File.join(home, ".ansible/tmp")
      result["warnings"]?.try(&.as_a?).try(&.map(&.as_s)).must_equal([
        "Module remote_tmp #{tmpdir} did not exist and was created with a mode of 0700, this may cause issues when running as another user. To avoid this, create the remote_tmp dir with the correct permissions manually",
      ])
    ensure
      File.chmod(locked, 0o755)
      FileUtils.rm_rf(locked)
      FileUtils.rm_rf(home)
    end
  end
end
