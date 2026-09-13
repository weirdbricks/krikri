require "../spec_helper"
require "../../src/krikri/task_executor/result_display"

private def fresh_stats : Hash(String, Int32)
  {"ok" => 0, "changed" => 0, "failed" => 0, "skipped" => 0, "rescued" => 0, "ignored" => 0}
end

describe Krikri::ResultDisplay do
  describe ".update_stats" do
    # Real Ansible's own PLAY RECAP counters overlap rather than being
    # mutually exclusive: "ok" counts every successful task (changed or
    # not), and "changed" is a separate tally on top of that - verified
    # against a real ansible-playbook run (2 changed + 1 unchanged
    # successful task produced ok=3 changed=2, not ok=1 changed=2).
    it "counts a changed task toward both ok and changed" do
      stats = fresh_stats
      result = JSON.parse(%({"changed": true, "failed": false}))
      Krikri::ResultDisplay.update_stats(stats, result)
      stats["ok"].should eq(1)
      stats["changed"].should eq(1)
    end

    it "counts an unchanged successful task toward ok only" do
      stats = fresh_stats
      result = JSON.parse(%({"changed": false, "failed": false}))
      Krikri::ResultDisplay.update_stats(stats, result)
      stats["ok"].should eq(1)
      stats["changed"].should eq(0)
    end

    it "counts a failed task toward failed only, not ok or changed" do
      stats = fresh_stats
      result = JSON.parse(%({"changed": true, "failed": true}))
      Krikri::ResultDisplay.update_stats(stats, result)
      stats["failed"].should eq(1)
      stats["ok"].should eq(0)
      stats["changed"].should eq(0)
    end

    it "counts an ignored failure toward ok (and changed if set), not failed" do
      stats = fresh_stats
      result = JSON.parse(%({"changed": true, "failed": true}))
      Krikri::ResultDisplay.update_stats(stats, result, ignore_errors: true)
      stats["failed"].should eq(0)
      stats["ok"].should eq(1)
      stats["changed"].should eq(1)
      stats["ignored"].should eq(1)
    end

    it "accumulates ok and changed independently across several tasks" do
      stats = fresh_stats
      Krikri::ResultDisplay.update_stats(stats, JSON.parse(%({"changed": true, "failed": false})))
      Krikri::ResultDisplay.update_stats(stats, JSON.parse(%({"changed": false, "failed": false})))
      Krikri::ResultDisplay.update_stats(stats, JSON.parse(%({"changed": true, "failed": false})))
      stats["ok"].should eq(3)
      stats["changed"].should eq(2)
    end
  end

  describe ".adhoc_state_and_color" do
    # Codes must match ansible.constants' COLOR_CODES byte-for-byte
    # (verified against ansible-core 2.19.4): yellow=0;33, green=0;32,
    # red=0;31, and bright red=1;31 for unreachable - a distinct bold
    # variant, NOT plain red.
    it "maps unreachable to bright red 1;31, not plain red" do
      Krikri::ResultDisplay.adhoc_state_and_color(false, false, true).should eq({"UNREACHABLE!", "1;31"})
    end

    it "maps failed to red 0;31" do
      Krikri::ResultDisplay.adhoc_state_and_color(false, true, false).should eq({"FAILED!", "0;31"})
    end

    it "prefers unreachable over failed" do
      Krikri::ResultDisplay.adhoc_state_and_color(false, true, true).should eq({"UNREACHABLE!", "1;31"})
    end

    it "maps changed to yellow 0;33" do
      Krikri::ResultDisplay.adhoc_state_and_color(true, false, false).should eq({"CHANGED", "0;33"})
    end

    it "maps plain success to green 0;32" do
      Krikri::ResultDisplay.adhoc_state_and_color(false, false, false).should eq({"SUCCESS", "0;32"})
    end
  end
end
