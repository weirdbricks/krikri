require "../minitest_helper"
require "../../src/krikri/variable_substitutor"

# GitHub issue #5: a genuinely mutually-templated variable pair
# (`a: "{{ b }}"` / `b: "{{ a }}"`) hung the outer re-pass render loop
# forever. The per-name cycle detection added in 0.9.1622 only brackets
# JinjaRenderer.prepare_var (it leniently hands back the raw value at a
# repeating name), and the old Rerender depth guard's raise-then-never-
# increment order let every caller's matching exit decrement a level that
# was never entered - the counter oscillated just under the cap, each
# level re-ran the whole cycle, and the error never surfaced (observed:
# the guard tripped 1138 times in five seconds with the process pegged).
# Real ansible-core fails the task with "recursive loop detected in
# template string"; krikri now raises TemplateRecursionError the same
# way, unwrapped back through the krikri-jinja TemplateError boundary and
# past the evaluators' unknown-construct fallback rescues, while a
# legitimate multi-level chain still renders to full depth.
#
# A CPU-bound hang in one fiber blocks the whole cooperative scheduler,
# so an in-process timeout could never fire. Instead, each dangerous case
# runs in a CHILD minitest process (same binary, `-n` filtered to the one
# test, re-entered via KRIKRI_CYCLE_CASE): the parent waits with a
# wall-clock timeout and kills the child, so a regression FAILS the test
# rather than hanging the suite.

private RECURSION_SUBPROCESS_TIMEOUT = 60.seconds
private CYCLE_CASE_ENV               = "KRIKRI_CYCLE_CASE"

private def cycle_vars(pairs : Array(Tuple(String, String))) : Hash(String, JSON::Any)
  vars = Hash(String, JSON::Any).new
  pairs.each { |(name, value)| vars[name] = JSON.parse(%("#{value}")) }
  vars
end

describe "mutually-templated variable cycle" do
  serial!

  # Runs this same test file in a child process, filtered to the single
  # test whose sanitized method name contains *case_name*, with the case
  # name passed through the environment so the child takes the direct
  # (in-process) branch. Fails with a clear message if the child exceeds
  # the timeout - that is the hang regression, not a normal failure.
  private def run_cycle_case_subprocess(case_name : String) : Nil
    binary = Process.executable_path
    unless binary && File.exists?(binary)
      raise Minitest::Assertion.new("cannot determine the minitest binary path for the subprocess guard")
    end

    child = Process.new(
      binary,
      args: ["-n", "/#{case_name}/"],
      env: {CYCLE_CASE_ENV => case_name},
      output: Process::Redirect::Pipe,
      error: Process::Redirect::Pipe
    )
    output_done = Channel(String).new
    spawn do
      begin
        output_done.send(child.output.gets_to_end)
      rescue
        output_done.send("")
      end
    end

    timed_out = false
    output = ""
    select
    when out = output_done.receive
      output = out
    when timeout RECURSION_SUBPROCESS_TIMEOUT
      timed_out = true
    end
    if timed_out
      child.signal(Signal::KILL) unless child.terminated?
      output_done.receive? # drain to EOF so the child can be reaped
    end
    status = child.wait

    if timed_out
      raise Minitest::Assertion.new(
        "case '#{case_name}': child did not finish within " +
        "#{RECURSION_SUBPROCESS_TIMEOUT.total_seconds}s - the mutual-template " +
        "cycle is hanging again (issue #5 regression)"
      )
    end
    assert status.success?, "case '#{case_name}': child minitest run failed:\n#{output}"
  end

  # In-process execution of one cycle case (only reached in the child,
  # selected by KRIKRI_CYCLE_CASE).
  private def run_cycle_case_direct(case_name : String) : Nil
    case case_name
    when "strict_two_var_cycle"
      sub = Krikri::VarSubstitutor.new(vars: cycle_vars([{"a", "{{ b }}"}, {"b", "{{ a }}"}]))
      e = assert_raises(Krikri::VariableSubstitutor::TemplateRecursionError) { sub.substitute("{{ a }}", strict: true) }
      assert_includes e.message || "", "Recursive loop detected in template"
    when "lenient_two_var_cycle"
      sub = Krikri::VarSubstitutor.new(vars: cycle_vars([{"a", "{{ b }}"}, {"b", "{{ a }}"}]))
      e = assert_raises(Krikri::VariableSubstitutor::TemplateRecursionError) { sub.substitute("{{ a }}") }
      assert_includes e.message || "", "Recursive loop detected in template"
    when "self_referential_cycle"
      sub = Krikri::VarSubstitutor.new(vars: cycle_vars([{"a", "{{ a }}"}]))
      e = assert_raises(Krikri::VariableSubstitutor::TemplateRecursionError) { sub.substitute("{{ a }}", strict: true) }
      assert_includes e.message || "", "Recursive loop detected in template"
    when "three_var_cycle"
      sub = Krikri::VarSubstitutor.new(vars: cycle_vars([{"a", "{{ b }}"}, {"b", "{{ c }}"}, {"c", "{{ a }}"}]))
      e = assert_raises(Krikri::VariableSubstitutor::TemplateRecursionError) { sub.substitute("{{ a }}", strict: true) }
      assert_includes e.message || "", "Recursive loop detected in template"
    when "engine_render_cycle"
      renderer = Krikri::VariableSubstitutor::JinjaRenderer.new(
        cycle_vars([{"a", "{{ b }}"}, {"b", "{{ a }}"}]))
      e = assert_raises(Krikri::VariableSubstitutor::TemplateRecursionError) { renderer.render("{{ a }}") }
      assert_includes e.message || "", "Recursive loop detected in template"
    when "legitimate_chain_still_works"
      vars = cycle_vars([{"a", "{{ b }}"}, {"b", "{{ c }}"}, {"c", "final"}])
      sub = Krikri::VarSubstitutor.new(vars: vars)
      assert_equal "final", sub.substitute("{{ a }}", strict: true)
      assert_equal "final", sub.substitute("{{ a }}")
      renderer = Krikri::VariableSubstitutor::JinjaRenderer.new(vars)
      assert_equal "final", renderer.render("{{ a }}")
    else
      raise Minitest::Assertion.new("unknown cycle case '#{case_name}'")
    end
  end

  it "strict two var cycle fails fast with ansible's recursive-loop error" do
    if ENV[CYCLE_CASE_ENV]? == "strict_two_var_cycle"
      run_cycle_case_direct("strict_two_var_cycle")
    else
      run_cycle_case_subprocess("strict_two_var_cycle")
    end
  end

  it "lenient two var cycle fails fast with the same recursive-loop error" do
    if ENV[CYCLE_CASE_ENV]? == "lenient_two_var_cycle"
      run_cycle_case_direct("lenient_two_var_cycle")
    else
      run_cycle_case_subprocess("lenient_two_var_cycle")
    end
  end

  it "self referential cycle fails fast instead of spinning the re-pass" do
    if ENV[CYCLE_CASE_ENV]? == "self_referential_cycle"
      run_cycle_case_direct("self_referential_cycle")
    else
      run_cycle_case_subprocess("self_referential_cycle")
    end
  end

  it "three var cycle fails fast through both evaluators" do
    if ENV[CYCLE_CASE_ENV]? == "three_var_cycle"
      run_cycle_case_direct("three_var_cycle")
    else
      run_cycle_case_subprocess("three_var_cycle")
    end
  end

  it "engine render path fails fast on the cycle" do
    if ENV[CYCLE_CASE_ENV]? == "engine_render_cycle"
      run_cycle_case_direct("engine_render_cycle")
    else
      run_cycle_case_subprocess("engine_render_cycle")
    end
  end

  it "legitimate chain still renders to full depth after the cycle fix" do
    if ENV[CYCLE_CASE_ENV]? == "legitimate_chain_still_works"
      run_cycle_case_direct("legitimate_chain_still_works")
    else
      run_cycle_case_subprocess("legitimate_chain_still_works")
    end
  end
end
