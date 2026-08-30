require "../spec_helper"

# hostname plugin (ansible.builtin.hostname) integration tests.
#
# Safety: this must never actually change the live system hostname. So:
# - The "no change" case feeds the *current* hostname (read-only).
# - The "would change" case uses check_mode (no hostnamectl/hostname call).
# - We only ever assert against facts derived from `hostname`(1) / `System.hostname`
#   or the static input, never by mutating state the host didn't already have.

describe "hostname plugin" do
  it "fails with a clear message when name is missing" do
    result = PluginSpecHelper.run("hostname", {} of String => String)

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should contain("missing required argument: name")
  end

  it "reports no change when name already equals the current hostname (read-only)" do
    current = `hostname`.strip
    result = PluginSpecHelper.run("hostname", {"name" => current})

    result["changed"].as_bool.should be_false
    result["failed"]?.try(&.as_bool).should be_falsey
    result["msg"].as_s.should contain("already #{current}")
    # Facts come back at the result top level, matching real Ansible.
    result["ansible_facts"]["ansible_hostname"].as_s.should eq(current)
    result["ansible_facts"]["ansible_nodename"].as_s.should eq(current)
  end

  it "reports it would change the hostname in check_mode, without touching the live hostname" do
    target = "krikri-playbook-hostname-spec-target"
    before = `hostname`.strip

    result = PluginSpecHelper.run("hostname", {"name" => target, "check_mode" => "true"})

    result["changed"].as_bool.should be_true
    result["failed"]?.try(&.as_bool).should be_falsey
    result["msg"].as_s.should contain("would change hostname from #{before} to #{target}")
    result["ansible_facts"]["ansible_hostname"].as_s.should eq(target)
    result["ansible_facts"]["ansible_nodename"].as_s.should eq(target)
    # Live hostname is untouched in check_mode.
    `hostname`.strip.should eq(before)
  end

  it "does not touch the live hostname when the name differs but check_mode is off AND it's already set (still read-only)" do
    # Belt-and-braces: re-run the no-change path with check_mode explicitly
    # off to ensure even the non-check path is a no-op when nothing differs.
    current = `hostname`.strip
    result = PluginSpecHelper.run("hostname", {"name" => current, "check_mode" => "false"})

    result["changed"].as_bool.should be_false
    result["failed"]?.try(&.as_bool).should be_falsey
    `hostname`.strip.should eq(current)
  end
end
