require "../spec_helper"
require "../../src/crystal_play/task_executor/result_display"

private def fresh_stats : Hash(String, Int32)
  {"ok" => 0, "changed" => 0, "failed" => 0, "skipped" => 0, "rescued" => 0, "ignored" => 0}
end

describe CrystalPlay::ResultDisplay do
  describe ".update_stats" do
    # Real Ansible's own PLAY RECAP counters overlap rather than being
    # mutually exclusive: "ok" counts every successful task (changed or
    # not), and "changed" is a separate tally on top of that - verified
    # against a real ansible-playbook run (2 changed + 1 unchanged
    # successful task produced ok=3 changed=2, not ok=1 changed=2).
    it "counts a changed task toward both ok and changed" do
      stats = fresh_stats
      result = JSON.parse(%({"changed": true, "failed": false}))
      CrystalPlay::ResultDisplay.update_stats(stats, result)
      stats["ok"].should eq(1)
      stats["changed"].should eq(1)
    end

    it "counts an unchanged successful task toward ok only" do
      stats = fresh_stats
      result = JSON.parse(%({"changed": false, "failed": false}))
      CrystalPlay::ResultDisplay.update_stats(stats, result)
      stats["ok"].should eq(1)
      stats["changed"].should eq(0)
    end

    it "counts a failed task toward failed only, not ok or changed" do
      stats = fresh_stats
      result = JSON.parse(%({"changed": true, "failed": true}))
      CrystalPlay::ResultDisplay.update_stats(stats, result)
      stats["failed"].should eq(1)
      stats["ok"].should eq(0)
      stats["changed"].should eq(0)
    end

    it "counts an ignored failure toward ok (and changed if set), not failed" do
      stats = fresh_stats
      result = JSON.parse(%({"changed": true, "failed": true}))
      CrystalPlay::ResultDisplay.update_stats(stats, result, ignore_errors: true)
      stats["failed"].should eq(0)
      stats["ok"].should eq(1)
      stats["changed"].should eq(1)
      stats["ignored"].should eq(1)
    end

    it "accumulates ok and changed independently across several tasks" do
      stats = fresh_stats
      CrystalPlay::ResultDisplay.update_stats(stats, JSON.parse(%({"changed": true, "failed": false})))
      CrystalPlay::ResultDisplay.update_stats(stats, JSON.parse(%({"changed": false, "failed": false})))
      CrystalPlay::ResultDisplay.update_stats(stats, JSON.parse(%({"changed": true, "failed": false})))
      stats["ok"].should eq(3)
      stats["changed"].should eq(2)
    end
  end
end
