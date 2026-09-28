require "../minitest_helper"
require "../../src/krikri/base_plugin"
require "../../src/krikri/base_action_plugin"
require "../../src/krikri/plugin_manager"
require "../../src/krikri/task_executor/result_display"

# The reported bug this suite pins down: krikri's ad-hoc output used to
# diverge from real ansible's in the result-dict SHAPE - "failed": false
# and "msg": "" on every success (real Ansible's module protocol never
# emits those keys on a success path), and a 2-space JSON indent (real
# minimal callback dumps with indent=4, sort_keys=True).
#
# Wire vs internal vs display, matching real Ansible's exact layering:
# - module wire result (PluginResult#to_json): protocol shape - failed
#   only after a fail-style exit, msg only when actually passed.
# - engine ingestion (PluginManager.normalize_module_result): backfills
#   failed (rc-based) / changed if absent, like
#   task_executor._execute_internal - registered vars see them.
# - display copy (ResultDisplay.adhoc_result_json): strips
#   failed/skipped/_ansible_* again, sorts keys, indent=4.
describe "ad-hoc result-dict shape (real-Ansible parity)" do
  describe "PluginResult wire shape" do
    it "omits failed and msg on a successful module result (ping's shape)" do
      result = Krikri::PluginResult.new(changed: false, failed: false, msg: "", ping: "pong")
      JSON.parse(result.to_json).as_h.must_equal(JSON.parse(%({"changed": false, "ping": "pong"})).as_h)
    end

    it "keeps failed: true and msg on a failing module result" do
      result = Krikri::PluginResult.new(changed: false, failed: true, msg: "boom", ping: "crash")
      parsed = JSON.parse(result.to_json).as_h
      parsed["failed"].as_bool.must_equal(true)
      parsed["msg"].as_s.must_equal("boom")
      parsed["ping"].as_s.must_equal("crash")
    end

    it "keeps a module-passed non-empty msg on a success" do
      result = Krikri::PluginResult.new(changed: false, failed: false, msg: "All assertions passed")
      JSON.parse(result.to_json).as_h["msg"].as_s.must_equal("All assertions passed")
    end
  end

  describe "ActionResult.plugin_result_json" do
    # Controller-computed final results are already in the
    # post-normalization shape the registered var sees, so
    # failed/changed are always carried; only msg follows the
    # pass-it-or-don't rule.
    it "always carries changed and failed" do
      parsed = JSON.parse(Krikri::ActionResult.plugin_result_json(false, false, "").as_h.to_json).as_h
      parsed["changed"].as_bool.must_equal(false)
      expect(falsey?(parsed["failed"]?.try(&.as_bool))).must_equal(true)
    end

    it "omits msg when the action passed none (real set_fact's shape)" do
      JSON.parse(Krikri::ActionResult.plugin_result_json(false, false, "").as_h.to_json).as_h["msg"]?.must_be_nil
    end

    it "keeps a passed msg" do
      parsed = JSON.parse(Krikri::ActionResult.plugin_result_json(false, false, "All assertions passed").as_h.to_json).as_h
      parsed["msg"].as_s.must_equal("All assertions passed")
    end
  end

  describe "PluginManager.normalize_module_result" do
    it "backfills failed: false and keeps changed when the module omitted failed" do
      normalized = Krikri::PluginManager.normalize_module_result(JSON.parse(%({"changed": false, "ping": "pong"})))
      expect(falsey?(normalized["failed"]?.try(&.as_bool))).must_equal(true)
      normalized["ping"].as_s.must_equal("pong")
    end

    it "backfills failed: true from a nonzero rc" do
      normalized = Krikri::PluginManager.normalize_module_result(JSON.parse(%({"changed": true, "rc": 2})))
      normalized["failed"].as_bool.must_equal(true)
    end

    it "leaves an explicit failed: true untouched" do
      normalized = Krikri::PluginManager.normalize_module_result(JSON.parse(%({"changed": false, "failed": true, "msg": "boom"})))
      normalized["failed"].as_bool.must_equal(true)
      normalized["msg"].as_s.must_equal("boom")
    end

    it "backfills changed: false when the module omitted it" do
      normalized = Krikri::PluginManager.normalize_module_result(JSON.parse(%({"ping": "pong"})))
      normalized["changed"].as_bool.must_equal(false)
      expect(falsey?(normalized["failed"]?.try(&.as_bool))).must_equal(true)
    end
  end

  describe "ResultDisplay.adhoc_result_json" do
    it "dumps a ping success exactly like real ansible's minimal callback (indent=4, sorted, no failed/msg)" do
      result = JSON.parse(%({"changed": false, "failed": false, "ping": "pong"}))
      Krikri::ResultDisplay.adhoc_result_json(result, "ping").must_equal(%({\n    "changed": false,\n    "ping": "pong"\n}))
    end

    it "dumps a debug success as msg alone (real _clean_results pop)" do
      result = JSON.parse(%({"changed": false, "failed": false, "msg": "hello", "_ansible_verbose_always": true}))
      Krikri::ResultDisplay.adhoc_result_json(result, "debug").must_equal(%({\n    "msg": "hello"\n}))
    end

    it "keeps non-msg keys for a debug-looking success only when no msg is present" do
      result = JSON.parse(%({"changed": false, "failed": false}))
      Krikri::ResultDisplay.adhoc_result_json(result, "ansible.builtin.debug").must_equal(%({\n    "changed": false\n}))
    end

    it "dumps a FAILED! result without failed: true (2.19 strips it for every callback)" do
      result = JSON.parse(%({"assertion": "1==2", "changed": false, "evaluated_to": false, "failed": true, "msg": "Assertion failed"}))
      Krikri::ResultDisplay.adhoc_result_json(result, "assert").must_equal(%({\n    "assertion": "1==2",\n    "changed": false,\n    "evaluated_to": false,\n    "msg": "Assertion failed"\n}))
    end

    it "strips private _ansible_* keys from the dump" do
      result = JSON.parse(%({"changed": false, "failed": false, "_ansible_quiet": true, "_ansible_no_log": false, "ping": "pong"}))
      Krikri::ResultDisplay.adhoc_result_json(result, "ping").must_equal(%({\n    "changed": false,\n    "ping": "pong"\n}))
    end

    it "dumps oneline indent=0 with Python's separators (no space after commas)" do
      result = JSON.parse(%({"changed": false, "failed": false, "ping": "pong"}))
      Krikri::ResultDisplay.adhoc_result_json(result, "ping", oneline: true).must_equal(%({"changed": false,"ping": "pong"}))
    end

    it "dumps an oneline debug with its keys kept and indent-4-then-newline-stripped shape" do
      result = JSON.parse(%({"changed": false, "failed": false, "msg": "hello", "_ansible_verbose_always": true}))
      Krikri::ResultDisplay.adhoc_result_json(result, "debug", oneline: true).must_equal(%({    "changed": false,    "msg": "hello"}))
    end

    it "keeps the unreachable marker in the dump" do
      result = JSON.parse(%({"changed": false, "failed": true, "msg": "Failed to connect", "unreachable": true}))
      dumped = Krikri::ResultDisplay.adhoc_result_json(result, "ping")
      dumped.must_include(%("unreachable": true))
      dumped.wont_include("failed")
    end
  end
end
