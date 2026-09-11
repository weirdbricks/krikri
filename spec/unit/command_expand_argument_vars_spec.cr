require "../spec_helper"
require "file_utils"

# Real Ansible's command module never runs anything through a shell, but
# its AnsibleModule.run_command (basic.py, expand_user_and_vars - driven by
# the module's expand_argument_vars, default true) expands BOTH `~` and
# `$VAR`/`${VAR}` on EVERY argv token, not just the executable: the command
# string is shlex-split first, then each token goes through
# `os.path.expanduser(os.path.expandvars(x))`. The tilde part supports the
# `~user` form via the passwd database, so `command: tar -xzf /tmp/x.tar.gz
# -C ~root/bin starship` runs at /root/bin - viasite-ansible.zsh's "Extract
# starship to ~root/bin" task (round 200970) failed here with
# "tar: ~root/bin: Cannot open: No such file or directory" where real
# ansible-playbook succeeded, because only the executable token was
# expanded and the `-C ~root/bin` argument reached tar literally.
#
# Driven through the real `command` plugin binary via PluginSpecHelper, the
# same convention as controlling_tty_spec - the parsing/expansion lives in
# the plugin process, so that is the boundary that has to be proven.
describe "command: per-token tilde and variable expansion" do
  current_home = File.expand_path("~")

  it "expands ~user in an argument token (the viasite-ansible.zsh shape)" do
    result = PluginSpecHelper.run("command", {
      "cmd" => "printf %s ~root/bin",
    })

    result["rc"].as_i.should eq(0)
    result["stdout"].as_s.should eq("/root/bin")
  end

  it "expands bare ~ from $HOME in an argument token" do
    pending! "no home directory for current user" unless current_home
    fake_home = File.tempname("krikri-cmd-expand")
    Dir.mkdir_p(fake_home)
    previous = ENV["HOME"]?
    begin
      ENV["HOME"] = fake_home
      result = PluginSpecHelper.run("command", {
        "cmd" => "printf %s ~/inside",
      })
    ensure
      previous ? (ENV["HOME"] = previous) : ENV.delete("HOME")
      FileUtils.rm_r(fake_home)
    end

    result["rc"].as_i.should eq(0)
    result["stdout"].as_s.should eq(File.join(fake_home, "inside"))
  end

  it "expands $VAR and ${VAR} from the task's environment in argument tokens" do
    result = PluginSpecHelper.run("command", {
      "cmd"          => "printf '%s %s' '$KRIKRI_SPEC_VAR' '${KRIKRI_SPEC_VAR}'",
      "_environment" => %({"KRIKRI_SPEC_VAR": "task-env-value"}),
    })

    result["rc"].as_i.should eq(0)
    result["stdout"].as_s.should eq("task-env-value task-env-value")
  end

  it "expands ~user in argv: elements too" do
    result = PluginSpecHelper.run("command", {
      "argv" => %(["/bin/echo", "~root/bin"]),
    })

    result["rc"].as_i.should eq(0)
    result["stdout"].as_s.should eq("/root/bin")
  end

  it "leaves an unset variable verbatim (os.path.expandvars semantics)" do
    result = PluginSpecHelper.run("command", {
      "cmd" => "printf %s '$KRIKRI_SPEC_UNSET_VAR_XYZ'",
    })

    result["rc"].as_i.should eq(0)
    result["stdout"].as_s.should eq("$KRIKRI_SPEC_UNSET_VAR_XYZ")
  end

  it "expands neither tilde nor variables when expand_argument_vars is false" do
    result = PluginSpecHelper.run("command", {
      "cmd"                  => "printf '%s %s' '~root/bin' '$KRIKRI_SPEC_UNSET_VAR_XYZ'",
      "expand_argument_vars" => "false",
    })

    result["rc"].as_i.should eq(0)
    result["stdout"].as_s.should eq("~root/bin $KRIKRI_SPEC_UNSET_VAR_XYZ")
  end
end
