require "file_utils"
require "../spec_helper"

# parted/lvg/snap/deploy_helper parameter-validation paths - exercised
# before any state-mutating command, so they need none of parted/LVM/
# snapd/a deploy tree. Anything past validation needs real block
# devices, a volume group, snapd, or a deployed tree and belongs to the
# live benchmark rounds, not this suite.
describe "parted plugin" do
  it "fails when device is missing" do
    result = PluginSpecHelper.run("parted", {"number" => "1"})

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should contain("device")
  end

  it "fails on an invalid state" do
    result = PluginSpecHelper.run("parted", {"device" => "/dev/sdz99", "state" => "bogus"})

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should eq("value of state must be one of: present, absent, info, got: bogus")
  end

  it "fails on an invalid unit" do
    result = PluginSpecHelper.run("parted", {"device" => "/dev/sdz99", "unit" => "furlongs"})

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should contain("value of unit must be one of")
  end

  it "fails on a missing device before any mutation" do
    result = PluginSpecHelper.run("parted", {"device" => "/dev/krikri-no-such-disk"})

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should contain("Could not stat device")
  end
end

describe "lvg plugin" do
  it "fails when vg is missing" do
    result = PluginSpecHelper.run("lvg", {"pvs" => "/dev/sdz99"})

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should contain("missing required arguments: vg")
  end

  it "fails when pvs is missing for state=present" do
    result = PluginSpecHelper.run("lvg", {"vg" => "krikri-nosuch-vg"})

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should contain("state is present but all of the following are missing: pvs")
  end

  it "fails on an invalid state" do
    result = PluginSpecHelper.run("lvg", {"vg" => "vg0", "pvs" => "/dev/sdz99", "state" => "bogus"})

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should eq("value of state must be one of: present, absent, got: bogus")
  end

  it "rejects unsupported parameters like real AnsibleModule" do
    result = PluginSpecHelper.run("lvg", {"vg" => "vg0", "pvs" => "/dev/sdz99", "bogus_param" => "1"})

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should contain("Unsupported parameters for (community.general.lvg) module: bogus_param")
  end
end

describe "snap plugin" do
  it "fails when name is missing" do
    result = PluginSpecHelper.run("snap", {"state" => "present"})

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should contain("missing required arguments: name")
  end

  it "fails on an invalid state" do
    result = PluginSpecHelper.run("snap", {"name" => "hello-world", "state" => "bogus"})

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should eq("value of state must be one of: present, absent, enabled, disabled, got: bogus")
  end

  it "fails when the snap binary is missing" do
    result = PluginSpecHelper.run("snap", {"name" => "hello-world"})

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should contain("Failed to find required executable \"snap\"")
  end
end

describe "deploy_helper plugin" do
  it "fails when path is missing" do
    result = PluginSpecHelper.run("deploy_helper", {"state" => "present"})

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should contain("missing required arguments: path")
  end

  it "fails on an invalid state" do
    result = PluginSpecHelper.run("deploy_helper", {"path" => "/tmp/krikri-deploy-test", "state" => "bogus"})

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should eq("value of state must be one of: finalize, absent, clean, present, query, unfinished, got: bogus")
  end

  it "fails when release is missing for state=unfinished" do
    result = PluginSpecHelper.run("deploy_helper", {"path" => "/tmp/krikri-deploy-test", "state" => "unfinished"})

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should contain("state is unfinished but all of the following are missing: release")
  end

  it "query returns an empty release list for a nonexistent tree" do
    result = PluginSpecHelper.run("deploy_helper",
      {"path" => "/tmp/krikri-deploy-nosuch", "state" => "query"})

    result["failed"]?.should be_nil
    result["releases"].as_a.size.should eq(0)
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

        result["failed"]?.should be_nil
        facts = result["ansible_facts"]["deploy_helper"]
        facts["project_path"].as_s.should eq(root)
        facts["releases_path"].as_s.should eq("#{root}/releases")
        facts["current_path"].as_s.should eq("#{root}/current")
        facts["shared_path"].as_s.should eq("#{root}/shared")
        facts["new_release"].as_s.should eq("20260919000001")
        facts["new_release_path"].as_s.should eq("#{root}/releases/20260919000001")
        facts["unfinished_filename"].as_s.should eq("DEPLOY_UNFINISHED")
        facts["previous_release"].raw.should be_nil
        facts["previous_release_path"].raw.should be_nil
        Dir.exists?(facts["new_release_path"].as_s).should be_true
      ensure
        FileUtils.rm_rf(root)
      end
    end

    it "state=query also carries the deploy_helper fact dict" do
      result = PluginSpecHelper.run("deploy_helper",
        {"path" => "/tmp/krikri-deploy-facts-query", "state" => "query",
         "release" => "20260919000002"})

      result["failed"]?.should be_nil
      facts = result["ansible_facts"]["deploy_helper"]
      facts["project_path"].as_s.should eq("/tmp/krikri-deploy-facts-query")
      facts["new_release"].as_s.should eq("20260919000002")
      facts["new_release_path"].as_s.should eq("/tmp/krikri-deploy-facts-query/releases/20260919000002")
    end

    it "state=absent destroys the facts as an empty list" do
      result = PluginSpecHelper.run("deploy_helper",
        {"path" => "/tmp/krikri-deploy-facts-absent", "state" => "absent"})

      result["failed"]?.should be_nil
      result["ansible_facts"]["deploy_helper"].as_a.size.should eq(0)
    end

    it "state=finalize and state=clean publish no ansible_facts" do
      finalize = PluginSpecHelper.run("deploy_helper",
        {"path" => "/tmp/krikri-deploy-facts-finalize", "state" => "finalize",
         "release" => "20260919000003"})
      clean = PluginSpecHelper.run("deploy_helper",
        {"path" => "/tmp/krikri-deploy-facts-clean", "state" => "clean"})

      finalize["ansible_facts"]?.should be_nil
      clean["ansible_facts"]?.should be_nil
    end
  end
end
