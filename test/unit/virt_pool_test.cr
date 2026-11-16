require "../minitest_helper"
require "file_utils"
require "../../src/krikri/plugin_helpers/virsh_pool"
require "../../src/krikri/playbook_parser"
require "../../src/krikri/plugin_manager"

# Unit-tests the virsh output parsing against real
# community.libvirt.virt_pool's own behavior (read from its source) -
# the plugin's execution paths need a live libvirt daemon, the
# `virsh pool-info`/pool-dumpxml parsing doesn't.
describe Krikri::PluginHelpers::VirshPool do
  private def sample_info
    <<-INFO
      Name:           default
      UUID:           4b0a03a4-1a1a-4a2b-9d1c-0d0e0f101112
      State:          running
      Persistent:     yes
      Autostart:      no
      Capacity:       494000000000
      Allocation:     33000000000
      Available:      461000000000
      INFO
  end

  describe ".parse_pool_info" do
    it "parses the state, flag fields and --bytes sizes" do
      info = Krikri::PluginHelpers::VirshPool.parse_pool_info(sample_info)
      info.name.must_equal("default")
      info.uuid.must_equal("4b0a03a4-1a1a-4a2b-9d1c-0d0e0f101112")
      info.state.must_equal("running")
      info.persistent.must_equal(true)
      info.autostart.must_equal(false)
      info.capacity.must_equal(494_000_000_000_i64)
      info.allocation.must_equal(33_000_000_000_i64)
      info.available.must_equal(461_000_000_000_i64)
    end

    it "leaves human-unit sizes nil (no lossless byte count)" do
      info = Krikri::PluginHelpers::VirshPool.parse_pool_info(
        "Name: default\nState: inactive\nCapacity: 494.00 GiB\n")
      info.state.must_equal("inactive")
      info.capacity.must_be_nil
    end
  end

  describe ".parse_pool_names / .active_state? / .info_state" do
    it "splits pool-list --all --name output" do
      Krikri::PluginHelpers::VirshPool.parse_pool_names("default\nvms\n\n")
        .must_equal(["default", "vms"])
    end

    it "maps libvirt pool states like virStoragePoolIsActive/ENTRY_STATE_INFO_MAP" do
      Krikri::PluginHelpers::VirshPool.active_state?("running").must_equal(true)
      Krikri::PluginHelpers::VirshPool.active_state?("degraded").must_equal(true)
      Krikri::PluginHelpers::VirshPool.active_state?("inactive").must_equal(false)
      Krikri::PluginHelpers::VirshPool.active_state?(nil).must_equal(false)

      Krikri::PluginHelpers::VirshPool.info_state("inaccessible").must_equal("inaccessible")
      Krikri::PluginHelpers::VirshPool.info_state("krikri").must_equal("unknown")
      Krikri::PluginHelpers::VirshPool.info_state(nil).must_equal("unknown")
    end
  end

  describe ".parse_pool_type and the XML fact fields" do
    private def xml
      "<pool type='iscsi'><source><host name='iscsi.example.lan'/>" \
      "<device path='/dev/sda'/><device path='/dev/sdb'/><format type='qcow2'/>" \
      "</source><target><path>/var/lib/libvirt/images</path></target></pool>"
    end

    it "extracts the fields the Ansible module xpath-scans" do
      Krikri::PluginHelpers::VirshPool.parse_pool_type(xml).must_equal("iscsi")
      Krikri::PluginHelpers::VirshPool.parse_target_path(xml).must_equal("/var/lib/libvirt/images")
      Krikri::PluginHelpers::VirshPool.parse_source_host(xml).must_equal("iscsi.example.lan")
      Krikri::PluginHelpers::VirshPool.parse_source_format(xml).must_equal("qcow2")
      Krikri::PluginHelpers::VirshPool.parse_source_devices(xml).must_equal(["/dev/sda", "/dev/sdb"])
    end

    it "returns nil/empty when the element is absent" do
      dir_xml = "<pool type='dir'><source><dir path='/srv/vms'/></source><target><path>/srv/vms</path></target></pool>"
      Krikri::PluginHelpers::VirshPool.parse_source_host(dir_xml).must_be_nil
      Krikri::PluginHelpers::VirshPool.parse_source_devices(dir_xml).must_be_empty
      Krikri::PluginHelpers::VirshPool.parse_source_path(dir_xml).must_equal("/srv/vms")
      Krikri::PluginHelpers::VirshPool.parse_target_path("<pool/>").must_be_nil
    end
  end

  describe ".virsh / .build_command" do
    it "threads the connection URI before the subcommand" do
      Krikri::PluginHelpers::VirshPool.virsh("qemu:///system", "pool-start", "default")
        .must_equal(["virsh", "--connect", "qemu:///system", "pool-start", "default"])
    end

    it "maps the build modes virsh can express" do
      Krikri::PluginHelpers::VirshPool.build_command("qemu:///system", "default", nil)
        .must_equal(["virsh", "--connect", "qemu:///system", "pool-build", "default"])
      Krikri::PluginHelpers::VirshPool.build_command("qemu:///system", "default", "overwrite")
        .must_equal(["virsh", "--connect", "qemu:///system", "pool-build", "--overwrite", "default"])
      Krikri::PluginHelpers::VirshPool.build_command("qemu:///system", "default", "repair")
        .must_equal(["virsh", "--connect", "qemu:///system", "pool-build", "default"])
    end
  end
end

describe "virt_pool registration" do
  it "resolves the bare and FQCN spellings onto the virt_pool plugin" do
    Krikri::PlaybookParser.resolve_module_name("virt_pool").must_equal("virt_pool")
    Krikri::PlaybookParser.resolve_module_name("community.libvirt.virt_pool").must_equal("virt_pool")
    Krikri::PluginManager.simple_plugin_name("virt_pool").must_equal("virt_pool")
  end
end

# A `virsh` stand-in answering the storage-pool calls virt_pool makes,
# with one active, autostarted pool named "default" (the ghyde.libvirt
# shape). PATH is handed to the plugin CHILD only - never mutated in the
# suite process.
private def with_virsh_pool_shim(&)
  dir = PluginSpecHelper.tmp_path("fake-virsh-pool")
  FileUtils.rm_r(dir) if File.exists?(dir)
  Dir.mkdir_p(dir)

  File.write(File.join(dir, "virsh"), <<-'SH')
    #!/bin/sh
    shift 2
    cmd="$1"
    shift
    case "$cmd" in
      pool-list)
        printf 'default\n'
        ;;
      pool-info)
        [ "$1" = "--bytes" ] && shift
        if [ "$1" = "default" ]; then
          printf 'Name:           default\nUUID:           4b0a03a4\nState:          running\nPersistent:     yes\nAutostart:      yes\nCapacity:       10\nAllocation:     4\nAvailable:      6\n'
          exit 0
        fi
        echo "error: failed to get pool '$1'" >&2
        exit 1
        ;;
      pool-dumpxml)
        if [ "$1" = "default" ]; then
          printf "<pool type='dir'><name>default</name><source></source><target><path>/var/lib/libvirt/images</path></target></pool>\n"
          exit 0
        fi
        echo "error: failed to get pool '$1'" >&2
        exit 1
        ;;
      *)
        exit 0
        ;;
    esac
    SH
  File.chmod(File.join(dir, "virsh"), 0o755)

  begin
    yield "#{dir}:/usr/bin:/bin"
  ensure
    FileUtils.rm_r(dir) if File.exists?(dir)
  end
end

# Issue #1360 (ghyde.libvirt): the role's "get available pools" task
# registers the list_pools command result and the next block's `when:`
# indexes it. Real runs the module under --check and answers ok; krikri
# dropped the task as unimplemented, so the registered skip dict made the
# block's conditional fail fatally (failed=1, exit 4) instead.
describe "virt_pool plugin - check mode (issue 1360)" do
  it "answers ok with the registered pool list in check mode" do
    with_virsh_pool_shim do |path|
      result = PluginSpecHelper.run("virt_pool", {
        "command"             => "list_pools",
        "_ansible_check_mode" => "true",
      }, env: {"PATH" => path})

      result["list_pools"].as_a.map(&.as_s).must_equal(["default"])
      result.as_h.has_key?("failed").must_equal(false)
      # core() returns {list_pools: [...]} through exit_json - no
      # changed key on the wire; the executor backfills it.
      result.as_h.has_key?("changed").must_equal(false)
    end
  end

  it "filters list_pools by state like v.list_pools(state=state)" do
    with_virsh_pool_shim do |path|
      active = PluginSpecHelper.run("virt_pool", {
        "command" => "list_pools",
        "state"   => "active",
      }, env: {"PATH" => path})
      active["list_pools"].as_a.map(&.as_s).must_equal(["default"])

      inactive = PluginSpecHelper.run("virt_pool", {
        "command" => "list_pools",
        "state"   => "inactive",
      }, env: {"PATH" => path})
      inactive["list_pools"].as_a.must_be_empty
    end
  end

  it "leaves an already-active pool untouched under --check" do
    with_virsh_pool_shim do |path|
      result = PluginSpecHelper.run("virt_pool", {
        "name"                => "default",
        "state"               => "active",
        "_ansible_check_mode" => "true",
      }, env: {"PATH" => path})

      result["changed"].as_bool.must_equal(false)
      result.as_h.has_key?("failed").must_equal(false)
    end
  end

  it "reports status without a changed key" do
    with_virsh_pool_shim do |path|
      result = PluginSpecHelper.run("virt_pool", {
        "name"    => "default",
        "command" => "status",
      }, env: {"PATH" => path})

      result["status"].as_s.must_equal("active")
      result.as_h.has_key?("changed").must_equal(false)
    end
  end

  it "answers unknown status for a missing pool under --check" do
    with_virsh_pool_shim do |path|
      result = PluginSpecHelper.run("virt_pool", {
        "name"                => "krikri-missing",
        "command"             => "status",
        "_ansible_check_mode" => "true",
      }, env: {"PATH" => path})

      result["status"].as_s.must_equal("unknown")
    end
  end

  it "reports a missing pool to a real (non-check) status call like EntryNotFound" do
    with_virsh_pool_shim do |path|
      result = PluginSpecHelper.run("virt_pool", {
        "name"    => "krikri-missing",
        "command" => "status",
      }, env: {"PATH" => path})

      result["failed"].as_bool.must_equal(true)
      result["msg"].as_s.must_equal("storage pool krikri-missing not found")
    end
  end

  it "reports an autostarted pool as unchanged when autostart is already yes" do
    with_virsh_pool_shim do |path|
      result = PluginSpecHelper.run("virt_pool", {
        "name"      => "default",
        "autostart" => "yes",
      }, env: {"PATH" => path})

      result["changed"].as_bool.must_equal(false)
    end
  end

  it "collects the facts fields the Ansible module gathers" do
    with_virsh_pool_shim do |path|
      result = PluginSpecHelper.run("virt_pool", {
        "command" => "info",
      }, env: {"PATH" => path})

      pool = result["pools"]["default"]
      pool["status"].as_s.must_equal("running")
      pool["state"].as_s.must_equal("active")
      pool["size_total"].as_s.must_equal("10")
      pool["type"].as_s.must_equal("dir")
      pool["path"].as_s.must_equal("/var/lib/libvirt/images")
      pool["volume_count"].as_i.must_equal(0)
    end
  end
end

describe "virt_pool plugin - argument validation before the HAS_VIRT probe" do
  # AnsibleModule construction (choices + the autostart bool type) fires
  # BEFORE the libvirt import probe, so a libvirt-less host still fails
  # invalid arguments with parameters.py's wording. These run the real
  # plugin binary and never reach the probe, so they're deterministic
  # with or without `virsh` installed.
  it "rejects an invalid state choice with parameters.py wording" do
    result = PluginSpecHelper.run("virt_pool", {
      "name"  => "krikri-pool",
      "state" => "krikri_bogus",
    })
    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal("value of state must be one of: active, inactive, present, absent, undefined, deleted, got: krikri_bogus")
  end

  it "rejects an invalid command choice with parameters.py wording" do
    result = PluginSpecHelper.run("virt_pool", {
      "name"    => "krikri-pool",
      "command" => "krikri_bogus",
    })
    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal("value of command must be one of: create, status, start, stop, build, delete, undefine, destroy, get_xml, define, refresh, list_pools, facts, info, got: krikri_bogus")
  end

  it "rejects an invalid mode choice with parameters.py wording" do
    result = PluginSpecHelper.run("virt_pool", {
      "name"    => "krikri-pool",
      "command" => "build",
      "mode"    => "krikri_bogus",
    })
    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal("value of mode must be one of: new, repair, resize, no_overwrite, overwrite, normal, zeroed, got: krikri_bogus")
  end

  it "validates the autostart bool before anything else" do
    result = PluginSpecHelper.run("virt_pool", {
      "name"      => "krikri-pool",
      "autostart" => "krikri_bogus",
    })
    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_match(/argument 'autostart'/)
    result["msg"].as_s.must_match(/is not a valid boolean/)
  end
end
