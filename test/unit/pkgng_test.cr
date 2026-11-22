require "../minitest_helper"
require "../../src/krikri/playbook_parser"
require "../../src/krikri/plugin_manager"

# Pins plugins/pkgng.cr's ported surface (issue #1679,
# onelove-roles.freebsd-consul-template on Ubuntu) against real
# community.general.pkgng 12.5.0: AnsibleModule's argument validation
# (main()'s argument_spec, mutually_exclusive) and the
# get_bin_path("pkg", required=True) probe main() runs before any
# package work, check mode included. That failure is the whole observable
# surface the engine used to answer with a graceful unavailable-module
# "skipping:" plus the end-of-run engine-limit exit 4, which let the play
# run on past the point real stopped.
describe "pkgng plugin argument validation" do
  it "fails without name" do
    result = PluginSpecHelper.run("pkgng", {} of String => String)

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal("missing required arguments: name")
  end

  it "fails any two of rootdir/chroot/jail (mutually exclusive)" do
    result = PluginSpecHelper.run("pkgng", {"name" => "consul-template", "rootdir" => "/mnt", "jail" => "j1"})

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal("parameters are mutually exclusive: rootdir|chroot|jail")
  end

  it "fails an invalid state choice in declaration order" do
    result = PluginSpecHelper.run("pkgng", {"name" => "consul-template", "state" => "banana"})

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal("value of state must be one of: present, latest, absent, got: banana")
  end

  it "rejects an unknown parameter with the spec-keys-then-aliases wording" do
    result = PluginSpecHelper.run("pkgng", {"name" => "consul-template", "banana" => "x"})

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal(
      "Unsupported parameters for (pkgng) module: banana. Supported parameters include: " \
      "annotation, autoremove, cached, chroot, ignore_osver, jail, name, pkgsite, " \
      "rootdir, state, use_globs (pkg).")
  end

  it "names an unconvertible bool's type the way ansible-core 2.21.6 does" do
    result = PluginSpecHelper.run("pkgng", {"name" => "consul-template", "cached" => "wwxxse"})

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal(
      "argument 'cached' is of type str and we were unable to convert to bool: " \
      "The value 'wwxxse' is not a valid boolean. " \
      "Valid booleans include: 'y', 'yes', 'on', '1', 'true', 't', 1, 'n', 'no', 'off', '0', 'false', 'f', 0")
  end

  it "fails the task with get_bin_path's message when pkg is missing (issue #1679)" do
    # The probe searches the shell's PATH (/usr/bin:/bin carry no pkg on
    # this box) and then appends the sbin dirs, exactly like real's
    # get_bin_path. /usr/bin is on the PATH so the probe's own `tr` works.
    result = PluginSpecHelper.run("pkgng", {"name" => "consul-template", "state" => "present"},
      env: {"PATH" => "/usr/bin:/bin"})

    result["failed"].as_bool.must_equal(true)
    result["changed"].as_bool.must_equal(false)
    str_starts_with?(result["msg"].as_s,
      "Failed to find required executable \"pkg\" in paths: /usr/bin:/bin:").must_equal(true)
  end

  it "accepts the role's own task shape through the pkg alias" do
    # onelove-roles.freebsd-consul-template passes pkg=..., state=present
    # (via name:); the probe, which real runs AFTER validation, is then
    # the failure.
    result = PluginSpecHelper.run("pkgng", {"pkg" => "consul-template", "state" => "present"},
      env: {"PATH" => "/usr/bin:/bin"})

    result["failed"].as_bool.must_equal(true)
    str_starts_with?(result["msg"].as_s,
      "Failed to find required executable \"pkg\" in paths: ").must_equal(true)
  end
end

# Real resolves all three spellings onto community.general.pkgng (the
# bare and builtin ones through collection search and ansible-core's own
# builtin runtime redirect respectively) and RUNS the module - a missing
# registry entry here would drop the task as an unavailable module and
# skip it, which is the divergence #1679 records.
describe "pkgng module resolution" do
  {% for spelling in ["pkgng", "community.general.pkgng", "ansible.builtin.pkgng"] %}
    it "resolves {{ spelling.id }}: to the pkgng plugin, not an unavailable module" do
      playbook = Krikri::PlaybookParser.parse_string(<<-YAML)
        - name: play
          hosts: all
          tasks:
            - name: install packages
              {{ spelling.id }}:
                name: consul-template
        YAML
      task = playbook.plays[0].tasks[0]
      task.unavailable_module.must_be_nil
      Krikri::PluginManager.simple_plugin_name(task.module_name).must_equal("pkgng")
    end
  {% end %}
end
