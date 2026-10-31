require "../minitest_helper"
require "../../src/krikri/task_executor/result_display"
require "../../src/krikri/task_executor/output_routing"

private def fresh_stats : Hash(String, Int32)
  {"ok" => 0, "changed" => 0, "failed" => 0, "skipped" => 0, "rescued" => 0, "ignored" => 0}
end

private def capture_output(&)
  io = IO::Memory.new
  Krikri::OutputRouting.redirect_current_fiber_to(io)
  begin
    yield
  ensure
    Krikri::OutputRouting.clear_current_fiber_redirect
  end
  io.to_s
end

describe Krikri::ResultDisplay do
  describe ".update_stats" do
    # Ansible's own PLAY RECAP counters overlap rather than being
    # mutually exclusive: "ok" counts every successful task (changed or
    # not), and "changed" is a separate tally on top of that - verified
    # against a ansible-playbook run (2 changed + 1 unchanged
    # successful task produced ok=3 changed=2, not ok=1 changed=2).
    it "counts a changed task toward both ok and changed" do
      stats = fresh_stats
      result = JSON.parse(%({"changed": true, "failed": false}))
      Krikri::ResultDisplay.update_stats(stats, result)
      stats["ok"].must_equal(1)
      stats["changed"].must_equal(1)
    end

    it "counts an unchanged successful task toward ok only" do
      stats = fresh_stats
      result = JSON.parse(%({"changed": false, "failed": false}))
      Krikri::ResultDisplay.update_stats(stats, result)
      stats["ok"].must_equal(1)
      stats["changed"].must_equal(0)
    end

    it "counts a failed task toward failed only, not ok or changed" do
      stats = fresh_stats
      result = JSON.parse(%({"changed": true, "failed": true}))
      Krikri::ResultDisplay.update_stats(stats, result)
      stats["failed"].must_equal(1)
      stats["ok"].must_equal(0)
      stats["changed"].must_equal(0)
    end

    it "counts an ignored failure toward ok (and changed if set), not failed" do
      stats = fresh_stats
      result = JSON.parse(%({"changed": true, "failed": true}))
      Krikri::ResultDisplay.update_stats(stats, result, ignore_errors: true)
      stats["failed"].must_equal(0)
      stats["ok"].must_equal(1)
      stats["changed"].must_equal(1)
      stats["ignored"].must_equal(1)
    end

    it "accumulates ok and changed independently across several tasks" do
      stats = fresh_stats
      Krikri::ResultDisplay.update_stats(stats, JSON.parse(%({"changed": true, "failed": false})))
      Krikri::ResultDisplay.update_stats(stats, JSON.parse(%({"changed": false, "failed": false})))
      Krikri::ResultDisplay.update_stats(stats, JSON.parse(%({"changed": true, "failed": false})))
      stats["ok"].must_equal(3)
      stats["changed"].must_equal(2)
    end
  end

  describe ".adhoc_state_and_color" do
    # Codes must match ansible.constants' COLOR_CODES byte-for-byte
    # (verified against ansible-core 2.19.4): yellow=0;33, green=0;32,
    # red=0;31, and bright red=1;31 for unreachable - a distinct bold
    # variant, NOT plain red.
    it "maps unreachable to bright red 1;31, not plain red" do
      Krikri::ResultDisplay.adhoc_state_and_color(false, false, true).must_equal({"UNREACHABLE!", "1;31"})
    end

    it "maps failed to red 0;31" do
      Krikri::ResultDisplay.adhoc_state_and_color(false, true, false).must_equal({"FAILED!", "0;31"})
    end

    it "prefers unreachable over failed" do
      Krikri::ResultDisplay.adhoc_state_and_color(false, true, true).must_equal({"UNREACHABLE!", "1;31"})
    end

    it "maps changed to yellow 0;33" do
      Krikri::ResultDisplay.adhoc_state_and_color(true, false, false).must_equal({"CHANGED", "0;33"})
    end

    it "maps plain success to green 0;32" do
      Krikri::ResultDisplay.adhoc_state_and_color(false, false, false).must_equal({"SUCCESS", "0;32"})
    end
  end

  describe ".display_diff" do
    # lineinfile's no-change wire result (state=absent with no match,
    # or an idempotent re-run) carries a diff LIST whose content entry
    # has headers but empty before/after text. Ansible's callback takes
    # the ---/+++ headers from difflib's unified_diff, which yields
    # nothing when both sides are identical, so it prints no diff block
    # at all - krikri used to print the bare header pair (issue #691).
    it "prints nothing for an empty content diff with headers" do
      diff = JSON.parse(%([{"before": "", "after": "", "before_header": "/tmp/conf (content)", "after_header": "/tmp/conf (content)"}, {"before_header": "/tmp/conf (file attributes)", "after_header": "/tmp/conf (file attributes)"}]))
      out = capture_output { Krikri::ResultDisplay.display_diff(diff) }
      out.must_equal("")
    end

    it "still prints the header pair and body for a real content diff" do
      diff = JSON.parse(%({"before": "old\\n", "after": "new\\n", "before_header": "/tmp/conf (content)", "after_header": "/tmp/conf (content)"}))
      out = capture_output { Krikri::ResultDisplay.display_diff(diff) }
      out.must_include("--- /tmp/conf (content)")
      out.must_include("+++ /tmp/conf (content)")
      out.must_include("-old")
      out.must_include("+new")
    end
  end

  describe ".display_diff attribute diffs" do
    # Ansible serializes dict diffs with a trailing "\n" appended to each
    # side (callback __init__.py _serialize_diff), so the unified differ
    # never sees a final line lacking a terminator and never emits a
    # "\ No newline at end of file" marker - which the system `diff -u`
    # krikri shells out to used to add on every file-attribute diff
    # (issue #687).
    it "renders a file-attribute diff without a no-newline marker" do
      diff = JSON.parse(%({"before": {"path": "/tmp/f", "mode": "0664"}, "after": {"path": "/tmp/f", "mode": "0640"}}))
      out = capture_output { Krikri::ResultDisplay.display_diff(diff) }
      out.must_include("-    \"mode\": \"0664\"")
      out.must_include("+    \"mode\": \"0640\"")
      out.wont_include("No newline at end of file")
    end

    # difflib's unified_diff yields no lines when the two sides are
    # identical and the callback prints only when it produced at least
    # one - so a dict diff whose entries all cancelled out prints
    # nothing, ---/+++ headers included.
    it "prints nothing for an attribute diff with identical sides" do
      diff = JSON.parse(%({"before": {"path": "/tmp/f"}, "after": {"path": "/tmp/f"}}))
      out = capture_output { Krikri::ResultDisplay.display_diff(diff) }
      out.must_equal("")
    end
  end
end
