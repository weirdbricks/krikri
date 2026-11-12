require "../minitest_helper"
require "../../src/krikri/playbook_parser"
require "../../src/krikri/plugin_manager"

# Pins plugins/podman_container.cr's ported surface (issue #1156,
# thulium_drake.gitea_runner's state=quadlet task) against real
# containers.podman 1.17.0's podman_container: AnsibleModule's
# argument validation, main()'s present/created-without-image check,
# and PodmanManager.__init__'s get_bin_path(executable, required=True)
# probe - the probe runs for EVERY state before any container/quadlet
# work, check mode or not, so a host without podman fails the task
# there in real. That failure is the whole observable surface the
# engine used to answer with a graceful unavailable-module
# "skipping:" plus the end-of-run engine-limit exit 4.
#
# The executable in the probe-failure specs is a name nothing ships,
# so the specs are host-independent: real fails identically on a host
# that has podman (get_bin_path is asked for the TASK's executable,
# not always "podman").
describe "podman_container plugin argument validation" do
  it "fails without name" do
    result = PluginSpecHelper.run("podman_container", {} of String => String)

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal("missing required arguments: name")
  end

  it "fails an invalid state choice" do
    result = PluginSpecHelper.run("podman_container", {"name" => "krikri", "state" => "banana"})

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal(
      "value of state must be one of: absent, present, stopped, started, created, quadlet, got: banana")
  end

  it "rejects an unknown parameter with the spec-keys-then-aliases wording" do
    result = PluginSpecHelper.run("podman_container", {"name" => "krikri", "container_name" => "krikri"})

    result["failed"].as_bool.must_equal(true)
    str_starts_with?(result["msg"].as_s,
      "Unsupported parameters for (containers.podman.podman_container) module: container_name. " \
      "Supported parameters include: ").must_equal(true)
  end

  it "fails a non-boolean privileged with parameters.py wording" do
    result = PluginSpecHelper.run("podman_container", {"name" => "krikri", "privileged" => "banana"})

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_include(
      "argument 'privileged' is of type <class 'str'> and we were unable to convert to bool: " \
      "The value 'banana' is not a valid boolean. Valid booleans include: ")
  end

  it "fails a non-integer retry with parameters.py wording" do
    result = PluginSpecHelper.run("podman_container", {"name" => "krikri", "retry" => "banana"})

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal(
      "argument 'retry' is of type <class 'str'> and we were unable to convert to int: " \
      "<class 'str'> cannot be converted to an int")
  end

  it "fails no_hosts + etc_hosts (mutually exclusive)" do
    result = PluginSpecHelper.run("podman_container", {
      "name"      => "krikri",
      "no_hosts"  => "true",
      "etc_hosts" => "{}",
    })

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal("parameters are mutually exclusive: no_hosts|etc_hosts")
  end

  it "fails state present without an image before the executable probe" do
    # main()'s check runs before PodmanManager.__init__, so it fires
    # even when the executable is missing too - order pinned here via
    # a nonexistent executable that never gets probed.
    result = PluginSpecHelper.run("podman_container", {
      "name"       => "krikri",
      "state"      => "present",
      "executable" => "krikri-no-such-podman-binary",
    })

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal("State 'present' required image to be configured!")
  end

  it "fails the task with get_bin_path's message when the executable is missing (issue #1156)" do
    result = PluginSpecHelper.run("podman_container", {
      "name"       => "krikri",
      "image"      => "docker.io/gitea/act_runner:latest",
      "state"      => "quadlet",
      "executable" => "krikri-no-such-podman-binary",
    })

    result["failed"].as_bool.must_equal(true)
    result["changed"].as_bool.must_equal(false)
    str_starts_with?(result["msg"].as_s,
      "Failed to find required executable \"krikri-no-such-podman-binary\" in paths: ").must_equal(true)
  end

  it "accepts the gitea_runner task's own parameter set (aliases included)" do
    # The role's task passes rm through its auto_remove alias and
    # volume through volumes - real converts both. With a deliberately
    # unresolvable executable the failure must be the get_bin_path
    # probe (which runs AFTER all validation in real), proving every
    # aliased parameter passed the spec - host-independent, since the
    # probe target is the task's own executable, not "podman".
    result = PluginSpecHelper.run("podman_container", {
      "name"            => "krikri",
      "image"           => "docker.io/gitea/act_runner:latest",
      "state"           => "quadlet",
      "auto_remove"     => "True",
      "privileged"      => "False",
      "volumes"         => "/tmp/krikri:/data",
      "quadlet_options" => "AutoUpdate=registry",
      "env"             => "{}",
      "executable"      => "krikri-no-such-podman-binary",
    })

    result["failed"].as_bool.must_equal(true)
    str_starts_with?(result["msg"].as_s,
      "Failed to find required executable \"krikri-no-such-podman-binary\" in paths: ").must_equal(true)
  end

  it "carries the installed payload's module_utils import deprecations on the failing result" do
    # Real records the module_utils import deprecations while LOADING the
    # payload's import chain - podman_container.py itself imports nothing
    # deprecated, its module_utils/podman/podman_container_lib.py opens
    # with the to_bytes/to_native pair - and a fail_json exit carries
    # them too. That pair was the whole remaining trailer of issue
    # #1156's compare. Fixture-scoped so it pins the payload shape on
    # every controller; a collection release that migrated the import
    # (containers.podman 1.21.x) warns nothing, which the scanner tests
    # in module_utils_import_deprecation_test.cr pin.
    root = PluginSpecHelper.tmp_path("podman-container-deprecation-fixture")
    base = File.join(root, "ansible_collections", "containers", "podman", "plugins")
    FileUtils.mkdir_p(File.join(base, "modules"))
    FileUtils.mkdir_p(File.join(base, "module_utils", "podman"))
    File.write(File.join(base, "modules", "podman_container.py"),
      "from ..module_utils.podman.podman_container_lib import PodmanManager\n")
    File.write(File.join(base, "module_utils", "podman", "podman_container_lib.py"),
      "from ansible.module_utils._text import to_bytes, to_native  # noqa: F402\n")

    result = PluginSpecHelper.run("podman_container", {
      # The executor's own wire field: the plugin's payload lookup is
      # keyed by the task's module spelling, and only the FQCN resolves
      # to the installed collection payload (a bare podman_container is
      # no builtin redirect).
      "_module_name" => "containers.podman.podman_container",
      "name"         => "krikri",
      "image"        => "docker.io/gitea/act_runner:latest",
      "state"        => "quadlet",
      "executable"   => "krikri-no-such-podman-binary",
    }, env: {"ANSIBLE_COLLECTIONS_PATH" => root})

    result["failed"].as_bool.must_equal(true)
    result["_ansible_core_deprecations"].as_a.map(&.as_s).must_equal([
      "Importing 'to_bytes' from 'ansible.module_utils._text' is deprecated. " \
      "This feature will be removed from ansible-core version 2.24. " \
      "Use ansible.module_utils.common.text.converters instead.",
      "Importing 'to_native' from 'ansible.module_utils._text' is deprecated. " \
      "This feature will be removed from ansible-core version 2.24. " \
      "Use ansible.module_utils.common.text.converters instead.",
    ])
    result["deprecations"].as_a.map { |entry| entry["msg"].as_s }.must_equal([
      "Importing 'to_bytes' from 'ansible.module_utils._text' is deprecated.",
      "Importing 'to_native' from 'ansible.module_utils._text' is deprecated.",
    ])
  end
end

describe "podman_container resolution" do
  it "resolves the FQCN to a real plugin, not an unimplemented-module warning" do
    playbook = Krikri::PlaybookParser.parse_string(
      "- name: issue 1156 repro play\n" \
      "  hosts: all\n" \
      "  tasks:\n" \
      "    - name: t\n" \
      "      containers.podman.podman_container:\n" \
      "        name: krikri\n" \
      "        image: docker.io/library/alpine:latest\n"
    )
    task = playbook.plays[0].tasks[0]
    task.module_name.must_equal("containers.podman.podman_container")
    task.unavailable_module.must_equal(nil)
    # parse-time validate() is the source of the "uses unimplemented
    # plugin" console warning - a ported module must not appear there.
    Krikri::PlaybookParser.validate(playbook).must_equal([] of String)
  end
end

# End-to-end check-mode shape of the issue itself: the task FATALS with
# the module's own failure (rc=2), the play stops for the host right
# there, and the run carries none of the old unavailable-module
# machinery (no skipping line, no engine-limit exit 4, no
# unimplemented-plugin warning).
describe "podman_container check-mode fatal shape (issue #1156)" do
  PROJECT_ROOT = File.expand_path("../..", __DIR__)
  BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
  INVENTORY    = File.join(PROJECT_ROOT, "test", "fixtures", "inventory-explicit-localhost.ini")

  it "fatals on the missing executable, exits 2, and skips nothing" do
    playbook = File.tempname("podman-container-issue1156", ".yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: Ensure Podman container
            containers.podman.podman_container:
              name: gitea_runner
              image: docker.io/gitea/act_runner:latest
              state: quadlet
              executable: krikri-no-such-podman-binary
      YAML
    captured = IO::Memory.new
    status = Process.run(BINARY, ["--check", "-i", INVENTORY, playbook],
      output: captured, error: captured)
    output = captured.to_s

    status.success?.must_equal(false, output)
    status.exit_code.must_equal(2, output)
    output.must_include("TASK [Ensure Podman container]", output)
    output.must_include("Failed to find required executable", output)
    output.must_include("krikri-no-such-podman-binary", output)
    output.must_include("fatal: [localhost]: FAILED!", output)
    output.must_include("failed=1", output)
    output.must_include("skipped=0", output)
    output.wont_include("skipping: [localhost]", output)
    output.wont_include("uses unimplemented plugin", output)
    output.wont_include("unavailable modules", output)
  ensure
    File.delete(playbook) if playbook && File.exists?(playbook)
  end
end
