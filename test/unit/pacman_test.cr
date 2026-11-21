require "../minitest_helper"
require "../../src/krikri/playbook_parser"
require "../../src/krikri/plugin_manager"

# Pins plugins/pacman.cr's ported surface (issue #1583,
# jpedrodelacerda.yay on Ubuntu) against real community.general.pacman:
# AnsibleModule's argument validation (setup_module's argument_spec,
# required_one_of, mutually_exclusive) and Pacman.__init__'s
# get_bin_path(executable, required=True) probe, which real runs before
# any package work, check mode included. That failure is the whole
# observable surface the engine used to answer with a graceful
# unavailable-module "skipping:" plus the end-of-run engine-limit exit 4,
# which let the play run on past the point real stopped.
#
# The probe-failure specs pass an executable nothing ships, so they are
# host-independent: real fails identically on an Arch host (get_bin_path
# is asked for the TASK's executable, not always "pacman").
describe "pacman plugin argument validation" do
  it "fails without any of name/update_cache/upgrade" do
    result = PluginSpecHelper.run("pacman", {} of String => String)

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal("one of the following is required: name, update_cache, upgrade")
  end

  it "fails name + upgrade (mutually exclusive)" do
    result = PluginSpecHelper.run("pacman", {"name" => "git", "upgrade" => "true"})

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal("parameters are mutually exclusive: name|upgrade")
  end

  it "treats name's package alias as name for the mutual exclusion" do
    # Ansible resolves aliases before validation, so `package:` collides
    # with upgrade: exactly like `name:` does.
    result = PluginSpecHelper.run("pacman", {"package" => "git", "upgrade" => "true"})

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal("parameters are mutually exclusive: name|upgrade")
  end

  it "fails an invalid state choice in declaration order" do
    result = PluginSpecHelper.run("pacman", {"name" => "git", "state" => "banana"})

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal("value of state must be one of: present, installed, latest, absent, removed, got: banana")
  end

  it "fails an invalid reason choice" do
    result = PluginSpecHelper.run("pacman", {"name" => "git", "reason" => "banana"})

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal("value of reason must be one of: explicit, dependency, got: banana")
  end

  it "fails an invalid reason_for choice" do
    result = PluginSpecHelper.run("pacman", {"name" => "git", "reason_for" => "banana"})

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal("value of reason_for must be one of: new, all, got: banana")
  end

  it "rejects an unknown parameter with the spec-keys-then-aliases wording" do
    result = PluginSpecHelper.run("pacman", {"name" => "git", "banana" => "x"})

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal(
      "Unsupported parameters for (pacman) module: banana. Supported parameters include: " \
      "executable, extra_args, force, name, reason, reason_for, remove_nosave, state, " \
      "update_cache, update_cache_extra_args, upgrade, upgrade_extra_args (package, pkg).")
  end

  it "fails the task with get_bin_path's message when the executable is missing (issue #1583)" do
    result = PluginSpecHelper.run("pacman", {
      "name"       => "git",
      "state"      => "present",
      "executable" => "krikri-no-such-pacman-binary",
    })

    result["failed"].as_bool.must_equal(true)
    result["changed"].as_bool.must_equal(false)
    str_starts_with?(result["msg"].as_s,
      "Failed to find required executable \"krikri-no-such-pacman-binary\" in paths: ").must_equal(true)
  end

  it "names an unconvertible bool's type the way ansible-core 2.21.6 does (issue #1661)" do
    # parameters.py builds the "is of type" slot from native_type_name(value),
    # the class's bare __name__; the "<class 'str'>" repr belongs to an older
    # core. The tail is convert_bool's frozenset repr: 1/1.0/True collapse to
    # one member and 0/0.0/False to another, so real lists 14 entries. Only
    # errors[0] surfaces, so the message names remove_nosave even though
    # update_cache is invalid too.
    result = PluginSpecHelper.run("pacman", {
      "remove_nosave" => "wwxxse",
      "update_cache"  => "pklpcv",
    })

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal(
      "argument 'remove_nosave' is of type str and we were unable to convert to bool: " \
      "The value 'wwxxse' is not a valid boolean. " \
      "Valid booleans include: 'y', 'yes', 'on', '1', 'true', 't', 1, 'n', 'no', 'off', '0', 'false', 'f', 0")
  end

  it "accepts the role's own task shape (state present through the package alias)" do
    # jpedrodelacerda.yay passes name + state present; the alias and the
    # bool params must all clear validation so the probe (which real runs
    # AFTER all of it) is the failure - host-independent since the probe
    # targets the task's own executable.
    result = PluginSpecHelper.run("pacman", {
      "package"       => "base-devel",
      "state"         => "present",
      "force"         => "yes",
      "remove_nosave" => "no",
      "executable"    => "krikri-no-such-pacman-binary",
    })

    result["failed"].as_bool.must_equal(true)
    str_starts_with?(result["msg"].as_s,
      "Failed to find required executable \"krikri-no-such-pacman-binary\" in paths: ").must_equal(true)
  end
end

# Real resolves all three spellings onto community.general.pacman (the
# bare and builtin ones through collection search and ansible-core's own
# builtin runtime redirect respectively) and RUNS the module - a missing
# registry entry here would drop the task as an unavailable module and
# skip it, which is the divergence #1583 records.
describe "pacman module resolution" do
  {% for spelling in ["pacman", "community.general.pacman", "ansible.builtin.pacman"] %}
    it "resolves {{ spelling.id }}: to the pacman plugin, not an unavailable module" do
      playbook = Krikri::PlaybookParser.parse_string(<<-YAML)
        - name: play
          hosts: all
          tasks:
            - name: Check for base-devel packages
              {{ spelling.id }}:
                name: base-devel
                state: present
        YAML
      task = playbook.plays[0].tasks[0]
      task.unavailable_module.must_be_nil
      Krikri::PluginManager.simple_plugin_name(task.module_name).must_equal("pacman")
    end
  {% end %}
end
