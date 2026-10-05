require "file_utils"
require "../minitest_helper"

# parted/lvg/snap/deploy_helper parameter-validation paths - exercised
# before any state-mutating command, so they need none of parted/LVM/
# snapd/a deploy tree. Anything past validation needs real block
# devices, a volume group, snapd, or a deployed tree and belongs to the
# live benchmark rounds, not this suite.
describe "parted plugin" do
  it "fails when device is missing" do
    result = PluginSpecHelper.run("parted", {"number" => "1"})

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_include("device")
  end

  it "fails on an invalid state" do
    result = PluginSpecHelper.run("parted", {"device" => "/dev/sdz99", "state" => "bogus"})

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal("value of state must be one of: absent, info, present, got: bogus")
  end

  it "fails on an invalid unit" do
    result = PluginSpecHelper.run("parted", {"device" => "/dev/sdz99", "unit" => "furlongs"})

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_include("value of unit must be one of")
  end

  it "fails on a missing device before any mutation" do
    result = PluginSpecHelper.run("parted", {"device" => "/dev/krikri-no-such-disk"})

    result["failed"].as_bool.must_equal(true)
    # Real parted.py has no separate stat check - get_device_info's
    # parted script fails and real surfaces the wrapper message
    # (plus rc/out/err), not the parted stderr itself (kpg34).
    result["msg"].as_s.must_include("Error while getting device information with parted script:")
    result["rc"].as_i64.must_equal(1)
  end
end

describe "lvg plugin" do
  it "fails when vg is missing" do
    result = PluginSpecHelper.run("lvg", {"pvs" => "/dev/sdz99"})

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_include("missing required arguments: vg")
  end

  it "fails when pvs is missing for a new volume group" do
    result = PluginSpecHelper.run("lvg", {"vg" => "krikri-nosuch-vg"})

    result["failed"].as_bool.must_equal(true)
    # Real lvg.py (7.1.0+): pvs_required = present-state AND vg missing
    # -> "No physical volumes given." - not a required_if error.
    result["msg"].as_s.must_include("No physical volumes given.")
  end

  it "fails on an invalid state" do
    result = PluginSpecHelper.run("lvg", {"vg" => "vg0", "pvs" => "/dev/sdz99", "state" => "bogus"})

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal("value of state must be one of: absent, present, active, inactive, got: bogus")
  end

  it "rejects unsupported parameters like AnsibleModule" do
    result = PluginSpecHelper.run("lvg", {"vg" => "vg0", "pvs" => "/dev/sdz99", "bogus_param" => "1"})

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_include("Unsupported parameters for (community.general.lvg) module: bogus_param")
  end
end

describe "snap plugin" do
  it "fails when name is missing" do
    result = PluginSpecHelper.run("snap", {"state" => "present"})

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_include("missing required arguments: name")
  end

  it "fails on an invalid state" do
    result = PluginSpecHelper.run("snap", {"name" => "hello-world", "state" => "bogus"})

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal("value of state must be one of: absent, present, enabled, disabled, got: bogus")
  end

  it "fails when the snap binary is missing" do
    result = PluginSpecHelper.run("snap", {"name" => "hello-world"})

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_include("Failed to find required executable \"snap\"")
  end
end

describe "deploy_helper plugin" do
  it "fails when path is missing" do
    result = PluginSpecHelper.run("deploy_helper", {"state" => "present"})

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_include("missing required arguments: path")
  end

  it "fails on an invalid state" do
    result = PluginSpecHelper.run("deploy_helper", {"path" => "/tmp/krikri-deploy-test", "state" => "bogus"})

    result["failed"].as_bool.must_equal(true)
    # Real argument_spec order (live-verified against 2.19.11).
    result["msg"].as_s.must_equal("value of state must be one of: present, absent, clean, finalize, query, got: bogus")
  end

  it "rejects the unfinished state Ansible's choices check rejects" do
    result = PluginSpecHelper.run("deploy_helper", {"path" => "/tmp/krikri-deploy-test", "state" => "unfinished"})

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal("value of state must be one of: present, absent, clean, finalize, query, got: unfinished")
  end

  it "query publishes no top-level releases list for a nonexistent tree" do
    result = PluginSpecHelper.run("deploy_helper",
      {"path" => "/tmp/krikri-deploy-nosuch", "state" => "query"})

    result["failed"]?.must_be_nil
    result["releases"]?.must_be_nil
    result["ansible_facts"]["deploy_helper"]["new_release"].raw.wont_be_nil
  end

  # Real main() attaches result["ansible_facts"] = {"deploy_helper": facts}
  # for state present/query (round900881
  # mbaran0v.ansible_role_prometheus_rabbitmq_exporter: its follow-up
  # "create release directory" task reads deploy_helper.new_release_path,
  # which was undefined before this published anything).
  describe "ansible_facts publishing" do
    it "state=present carries the deploy_helper fact dict matching the created tree" do
      root = "/tmp/krikri-deploy-facts-present-#{Random.new.hex(4)}"
      begin
        result = PluginSpecHelper.run("deploy_helper",
          {"path" => root, "state" => "present", "release" => "20260919000001"})

        result["failed"]?.must_be_nil
        facts = result["ansible_facts"]["deploy_helper"]
        facts["project_path"].as_s.must_equal(root)
        facts["releases_path"].as_s.must_equal("#{root}/releases")
        facts["current_path"].as_s.must_equal("#{root}/current")
        facts["shared_path"].as_s.must_equal("#{root}/shared")
        facts["new_release"].as_s.must_equal("20260919000001")
        facts["new_release_path"].as_s.must_equal("#{root}/releases/20260919000001")
        facts["unfinished_filename"].as_s.must_equal("DEPLOY_UNFINISHED")
        facts["previous_release"].raw.must_be_nil
        facts["previous_release_path"].raw.must_be_nil
        # Real main() creates only the project/releases/shared dirs; the
        # new release dir and `current` do not exist after state=present.
        Dir.exists?(facts["new_release_path"].as_s).must_equal(false)
        Dir.exists?(facts["current_path"].as_s).must_equal(false)
        Dir.exists?(facts["releases_path"].as_s).must_equal(true)
        Dir.exists?(facts["shared_path"].as_s).must_equal(true)
      ensure
        FileUtils.rm_rf(root)
      end
    end

    it "state=present is idempotent (second call changed=false)" do
      root = "/tmp/krikri-deploy-idem-#{Random.new.hex(4)}"
      begin
        first = PluginSpecHelper.run("deploy_helper",
          {"path" => root, "state" => "present", "release" => "20260919000004"})
        first["changed"].as_bool.must_equal(true)

        second = PluginSpecHelper.run("deploy_helper",
          {"path" => root, "state" => "present", "release" => "20260919000005"})
        second["failed"]?.must_be_nil
        second["changed"].as_bool.must_equal(false)
      ensure
        FileUtils.rm_rf(root)
      end
    end

    it "state=present fails when current exists as a real directory (real check_link)" do
      root = "/tmp/krikri-deploy-notlink-#{Random.new.hex(4)}"
      begin
        Dir.mkdir_p(File.join(root, "current"))
        result = PluginSpecHelper.run("deploy_helper",
          {"path" => root, "state" => "present", "release" => "20260919000006"})

        result["failed"].as_bool.must_equal(true)
        result["msg"].as_s.must_include("exists but is not a symbolic link")
      ensure
        FileUtils.rm_rf(root)
      end
    end

    it "state=query also carries the deploy_helper fact dict" do
      result = PluginSpecHelper.run("deploy_helper",
        {"path" => "/tmp/krikri-deploy-facts-query", "state" => "query",
         "release" => "20260919000002"})

      result["failed"]?.must_be_nil
      facts = result["ansible_facts"]["deploy_helper"]
      facts["project_path"].as_s.must_equal("/tmp/krikri-deploy-facts-query")
      facts["new_release"].as_s.must_equal("20260919000002")
      facts["new_release_path"].as_s.must_equal("/tmp/krikri-deploy-facts-query/releases/20260919000002")
    end

    it "state=absent destroys the facts as an empty list" do
      result = PluginSpecHelper.run("deploy_helper",
        {"path" => "/tmp/krikri-deploy-facts-absent", "state" => "absent"})

      result["failed"]?.must_be_nil
      result["ansible_facts"]["deploy_helper"].as_a.size.must_equal(0)
    end

    it "state=finalize and state=clean publish no ansible_facts" do
      root = PluginSpecHelper.tmp_path("krikri-deploy-facts")
      Dir.mkdir_p(File.join(root, "releases", "r1"))

      finalize = PluginSpecHelper.run("deploy_helper",
        {"path" => root, "state" => "finalize", "release" => "r1"})
      clean = PluginSpecHelper.run("deploy_helper",
        {"path" => root, "state" => "clean"})

      finalize["ansible_facts"]?.must_be_nil
      clean["ansible_facts"]?.must_be_nil
    end
  end
end
