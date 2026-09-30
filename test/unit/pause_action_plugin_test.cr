require "../minitest_helper"
require "../../src/krikri/inventory_parser"
require "../../src/krikri/action_plugin_manager"

# pause runs as a controller-side action plugin (no target module, same
# as debug/assert/fail/set_fact) - see PauseActionPlugin. These specs
# pin the param surface against real ansible.builtin.pause's
# argument_spec: echo (bool, default true), minutes (int, mutually
# exclusive with seconds), seconds (int), prompt (str). Real semantics
# ported from ansible-core 2.14's action/pause.py: type-int validation
# (floats truncate, non-numerics fail), a 1-second minimum duration,
# and stdout always "Paused for X <unit>" from elapsed wall-clock.
private def run_pause(params : Hash(String, String)) : Krikri::ActionResult
  caller_host = Krikri::Host.new("control1")
  plugin = Krikri::PauseActionPlugin.new(params, Hash(String, JSON::Any).new, caller_host)
  plugin.execute
end

private def final_json(result : Krikri::ActionResult) : JSON::Any
  json = result.final_result
  json.wont_be_nil
  json.as(JSON::Any)
end

describe "PauseActionPlugin" do
  it "fails minutes and seconds together with real Ansible's exact error text" do
    result = run_pause({"seconds" => "1", "minutes" => "1"})

    result.success?.must_equal(true)
    final = final_json(result)
    final.as_h["failed"].as_bool.must_equal(true)
    final.as_h["msg"].as_s.must_equal("parameters are mutually exclusive: minutes|seconds")
  end

  it "fails minutes and seconds together even when one is zero (verified against real ansible-playbook)" do
    result = run_pause({"seconds" => "0", "minutes" => "0"})

    final_json(result).as_h["failed"].as_bool.must_equal(true)
  end

  it "fails non-numeric seconds like real arg validation instead of crashing" do
    result = run_pause({"seconds" => "krikri-not-a-number"})

    final = final_json(result)
    final.as_h["failed"].as_bool.must_equal(true)
    final.as_h["changed"].as_bool.must_equal(false)
    final.as_h["msg"].as_s.must_include("seconds")
  end

  it "fails non-numeric minutes the same way" do
    result = run_pause({"minutes" => "krikri-not-a-number"})

    final = final_json(result)
    final.as_h["failed"].as_bool.must_equal(true)
    final.as_h["changed"].as_bool.must_equal(false)
  end

  it "truncates fractional seconds like real's int type validation" do
    result = run_pause({"seconds" => "1.5"})

    final = final_json(result)
    expect(falsey?(final.as_h["failed"]?.try(&.as_bool))).must_equal(true)
    final.as_h["stdout"].as_s.must_match(/^Paused for 1\.\d+ seconds$/)
  end

  it "reports elapsed-based stdout for a prompt-only pause (prompt text is display-only)" do
    result = run_pause({"prompt" => "Press Enter to continue"})

    result.success?.must_equal(true)
    final = final_json(result)
    expect(falsey?(final.as_h["failed"]?.try(&.as_bool))).must_equal(true)
    final.as_h["stdout"].as_s.must_equal("Paused for 0.0 minutes")
    final.as_h["delta"].as_i64.must_equal(0)
  end

  it "clamps a zero duration up to the 1-second minimum with seconds-unit stdout" do
    result = run_pause({"prompt" => "Waiting a bit", "seconds" => "0"})

    final = final_json(result)
    expect(falsey?(final.as_h["failed"]?.try(&.as_bool))).must_equal(true)
    final.as_h["stdout"].as_s.must_match(/^Paused for 1\.\d+ seconds$/)
  end

  it "clamps minutes 0 up to the 1-second minimum and reports minutes-unit stdout" do
    result = run_pause({"prompt" => "Waiting a bit", "minutes" => "0"})

    final = final_json(result)
    expect(falsey?(final.as_h["failed"]?.try(&.as_bool))).must_equal(true)
    final.as_h["stdout"].as_s.must_match(/^Paused for 0\.0[0-9]* minutes$/)
  end

  it "never reports changed" do
    result = run_pause({"seconds" => "0"})

    final_json(result).as_h["changed"].as_bool.must_equal(false)
  end

  it "defaults echo to true" do
    result = run_pause({"seconds" => "0"})

    final_json(result).as_h["echo"].as_bool.must_equal(true)
  end

  it "honors echo: false" do
    result = run_pause({"seconds" => "0", "echo" => "false"})

    final_json(result).as_h["echo"].as_bool.must_equal(false)
  end

  it "reports delta as integer elapsed seconds in the result" do
    result = run_pause({"seconds" => "0"})

    final = final_json(result)
    final.as_h["delta"].as_i64.must_equal(1)
    final.as_h["user_input"].as_s.must_equal("")
  end

  # The console lines below are real's OWN Display.display() writes from
  # action/pause.py's duration branch, captured byte for byte against
  # ansible-playbook 2.19.11 with stdin from /dev/null. They are carried
  # on the result under an engine-internal key (never registered, never
  # dumped) so ResultDisplay can put them immediately before the item's
  # status line - the place real's own write lands, once per loop item.
  it "announces the wait on the console when seconds are given" do
    result = run_pause({"seconds" => "1"})

    console_lines(result).must_equal(["Pausing for 1 seconds"])
  end

  it "announces the clamped second count, not the requested one" do
    console_lines(run_pause({"seconds" => "0"})).must_equal(["Pausing for 1 seconds"])
    console_lines(run_pause({"seconds" => "-5"})).must_equal(["Pausing for 1 seconds"])
    # minutes convert to a SECOND count before the announcement.
    console_lines(run_pause({"minutes" => "0"})).must_equal(["Pausing for 1 seconds"])
  end

  it "adds the ctrl+C hint only when a duration AND a prompt are both given" do
    hint = "(ctrl+C then 'C' = continue early, ctrl+C then 'A' = abort)\r"

    console_lines(run_pause({"prompt" => "kpg pause", "seconds" => "1"})).must_equal(["Pausing for 1 seconds", hint])
    # No prompt: real REPLACES the (unwritten) prompt with the hint.
    console_lines(run_pause({"seconds" => "1"})).must_equal(["Pausing for 1 seconds"])
    # No duration: the hint is not printed at all, only the non-interactive
    # stdin warning on stderr fires.
    console_lines(run_pause({"prompt" => "kpg pause"})).must_be_empty
  end

  it "notes hidden output on the console when echo is false" do
    console_lines(run_pause({"seconds" => "1", "echo" => "false"})).must_equal(["Pausing for 1 seconds (output is hidden)"])
  end

  it "treats a natively-typed bool duration as an int like real's int callable" do
    # int(True) == 1 and int(False) == 0, and 0 clamps up to the same
    # 1-second minimum - neither is a validation failure.
    truthy = run_pause({"seconds" => marked("true")})
    expect(falsey?(final_json(truthy).as_h["failed"]?.try(&.as_bool))).must_equal(true)
    console_lines(truthy).must_equal(["Pausing for 1 seconds"])

    falsy = run_pause({"seconds" => marked("false")})
    expect(falsey?(final_json(falsy).as_h["failed"]?.try(&.as_bool))).must_equal(true)
    console_lines(falsy).must_equal(["Pausing for 1 seconds"])
  end

  it "truncates a natively-typed float duration toward zero" do
    console_lines(run_pause({"seconds" => marked("1.9")})).must_equal(["Pausing for 1 seconds"])
  end

  it "keeps the console lines out of the result's real-shaped keys" do
    result = run_pause({"seconds" => "1"})

    final = final_json(result)
    expect(final.as_h.has_key?("_ansible_pause_console")).must_equal(true)
    # Everything real's own pause result carries is still there.
    %w(start stop delta stdout stderr rc echo user_input).each do |key|
      final.as_h.has_key?(key).must_equal(true)
    end
  end
end

# A non-string YAML literal as the parser hands it to the plugin: the
# native-typed marker plus the JSON encoding of the parsed scalar.
private def marked(text : String) : String
  "#{Krikri::NON_STRING_PARAM_PREFIX}#{text}"
end

private def console_lines(result : Krikri::ActionResult) : Array(String)
  (final_json(result).as_h["_ansible_pause_console"]?.try(&.as_a) || [] of JSON::Any).map(&.as_s)
end
