require "../spec_helper"
require "../../src/crystal_play/batch_script"

# OPUS_PERFORMANCE_IMPROVEMENTS.md item 3 - the controller-side half.
#
# A daemon is a single resident process running as ONE user, so the
# eligibility rule for sending a batch group over one is that every step
# agrees on become_user. `TaskExecutor#try_daemon_batch` is private and
# needs a live host to exercise, so what is pinned here is the data that
# rule reads: `Step` has to carry the module name and the become_user
# separately from the script transport's `sudo`-prefixed target string,
# and `nil` (no become) has to stay distinct from `"root"` - they are
# different daemons.
describe CrystalPlay::BatchScript::Step do
  it "carries the daemon's dispatch name and user alongside the script target" do
    step = CrystalPlay::BatchScript::Step.new(
      "sudo -n -u deploy -- /var/tmp/.crystal-play/plugins/copy",
      %({"params":{}}), false, "copy", "deploy")

    step.module_name.should eq("copy")
    step.become_user.should eq("deploy")
    step.plugin_target.should contain("sudo -n -u deploy")
  end

  it "keeps no-become distinct from become_user root" do
    # These select DIFFERENT daemons, so conflating them would send a
    # task to a process running as the wrong user.
    unprivileged = CrystalPlay::BatchScript::Step.new("/p/command", "{}", false, "command", nil)
    as_root = CrystalPlay::BatchScript::Step.new("sudo -n -u root -- /p/command", "{}", false, "command", "root")

    unprivileged.become_user.should be_nil
    as_root.become_user.should eq("root")
    (unprivileged.become_user == as_root.become_user).should be_false
  end

  it "defaults the daemon fields so the script transport is unaffected" do
    # The looped path and any other constructor call site that only
    # cares about the script transport still works unchanged.
    step = CrystalPlay::BatchScript::Step.new("/p/command", "{}", true)

    step.module_name.should eq("")
    step.become_user.should be_nil
    step.ignore_errors?.should be_true
  end

  it "still builds an identical script from a step carrying daemon fields" do
    # The daemon fields are additive: a step that has them must produce
    # byte-identical script output to one that does not, or the fallback
    # transport would diverge from what it sent before item 3.
    plain = CrystalPlay::BatchScript::Step.new("/p/command", %({"a":1}), false)
    enriched = CrystalPlay::BatchScript::Step.new("/p/command", %({"a":1}), false, "command", nil)

    CrystalPlay::BatchScript.build("fixed", [plain])
      .should eq(CrystalPlay::BatchScript.build("fixed", [enriched]))
  end

  it "reports a step that never ran as absent, not as a failure" do
    # Both transports share this contract - the daemon omits steps after
    # a fail-fast stop, and the script's dump only emits .rc files that
    # exist. execute_batch_group relies on it to tell "never ran" from
    # "ran and failed".
    parsed = CrystalPlay::BatchScript.parse("OUT 0 0 #{Base64.strict_encode(%({"failed":false}))}\n")

    parsed.has_key?(0).should be_true
    parsed.has_key?(1).should be_false
  end
end
