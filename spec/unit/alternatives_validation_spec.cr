require "../spec_helper"
require "file_utils"

# community.general.alternatives argument-validation and install-guard
# regressions (found against real ansible-playbook via the podman-diff
# harness): real AnsibleModule validates name/state/required_one_of
# BEFORE the module resolves update-alternatives, and install() fails a
# nonexistent --path with "Specified path ... does not exist" instead of
# registering an alternative that points at a missing binary. Check mode
# claims the change but must not run any update-alternatives mutation.
private def with_temp_dir(&)
  dir = File.tempname("alternatives-spec")
  Dir.mkdir_p(dir)
  begin
    yield dir
  ensure
    FileUtils.rm_rf(dir)
  end
end

describe "alternatives argument validation" do
  it "fails with the required-arguments message when name is missing" do
    result = PluginSpecHelper.run("alternatives", {"path" => "/bin/sh"})
    result["failed"].as_bool.should be_true
    result["msg"].as_s.should eq("missing required arguments: name")
  end

  it "fails with the choices message for an invalid state, before the binary check" do
    result = PluginSpecHelper.run("alternatives", {
      "name"  => "krikri-spec-alt",
      "path"  => "/bin/sh",
      "state" => "krikri_state",
    })
    result["failed"].as_bool.should be_true
    result["msg"].as_s.should eq("value of state must be one of: present, selected, absent, auto, got: krikri_state")
  end

  it "fails with the required_one_of message when neither path nor family is given" do
    result = PluginSpecHelper.run("alternatives", {"name" => "krikri-spec-alt"})
    result["failed"].as_bool.should be_true
    result["msg"].as_s.should eq("one of the following is required: path, family")
  end
end

describe "alternatives install guard" do
  it "fails a nonexistent path without registering anything" do
    result = PluginSpecHelper.run("alternatives", {
      "name" => "krikri-spec-alt",
      "path" => "/krikri/does-not-exist",
      "link" => "/tmp/krikri-spec-alt/krikri-sh",
    })
    result["failed"].as_bool.should be_true
    result["msg"].as_s.should eq("Specified path /krikri/does-not-exist does not exist")
    result["changed"].as_bool.should be_false

    query = Process.run("update-alternatives", ["--query", "krikri-spec-alt"],
      output: Process::Redirect::Close, error: Process::Redirect::Close)
    query.exit_code.should_not eq(0)
  end

  it "check mode claims the install but runs no update-alternatives mutation" do
    with_temp_dir do |dir|
      link = File.join(dir, "krikri-sh")
      result = PluginSpecHelper.run("alternatives", {
        "name"       => "krikri-spec-alt-check",
        "path"       => "/bin/sh",
        "link"       => link,
        "_ansible_check_mode" => "true",
      })
      result["changed"].as_bool.should be_true
      result["failed"]?.should be_nil
      result["msg"].as_s.should contain("Install alternative '/bin/sh' for 'krikri-spec-alt-check'.")

      File.exists?(link).should be_false
      query = Process.run("update-alternatives", ["--query", "krikri-spec-alt-check"],
        output: Process::Redirect::Close, error: Process::Redirect::Close)
      query.exit_code.should_not eq(0)
    end
  end
end

describe "dnf_versionlock validation order" do
  it "fails with the choices message for an invalid state, before the dnf binary check" do
    result = PluginSpecHelper.run("dnf_versionlock", {
      "name"  => "bash",
      "state" => "krikri_state",
    })
    result["failed"].as_bool.should be_true
    result["msg"].as_s.should eq("value of state must be one of: present, absent, excluded, clean, got: krikri_state")
  end

  it "still fails on the missing dnf binary for a valid state" do
    result = PluginSpecHelper.run("dnf_versionlock", {"name" => "bash"})
    result["failed"].as_bool.should be_true
    result["msg"].as_s.should contain("dnf")
  end
end
