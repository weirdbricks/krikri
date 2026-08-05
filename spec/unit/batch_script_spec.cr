require "../spec_helper"
require "../../src/crystal_play/batch_script"

# Runs a generated batch script for real via `bash` (not SSH - no network
# involved, this is exercising the script's own logic: base64 framing,
# fail-fast, ignore_errors:, halting), the same way BATCH_DESIGN.md's own
# manual verification did before this was wired into TaskExecutor.
private def run_script(script : String) : String
  process = Process.new("bash", input: Process::Redirect::Pipe, output: Process::Redirect::Pipe, error: Process::Redirect::Pipe)
  process.input.print(script)
  process.input.close
  output = process.output.gets_to_end
  process.wait
  output
end

describe CrystalPlay::BatchScript do
  it "round-trips a step's config through /bin/cat and parses the result back" do
    steps = [
      CrystalPlay::BatchScript::Step.new("/bin/cat", %({"changed":false,"failed":false,"msg":"hi"}), false),
    ]

    script = CrystalPlay::BatchScript.build("t1", steps)
    results = CrystalPlay::BatchScript.parse(run_script(script))

    results[0]?.should_not be_nil
    r = results[0]
    r.exit_code.should eq(0)
    r.stdout.should eq(%({"changed":false,"failed":false,"msg":"hi"}))
  end

  it "preserves embedded newlines in stdout (base64 framing, not a text delimiter)" do
    payload = %({"changed":false,"failed":false,"msg":"line one\\nline two\\nline three"})
    steps = [CrystalPlay::BatchScript::Step.new("/bin/cat", payload, false)]

    results = CrystalPlay::BatchScript.parse(run_script(CrystalPlay::BatchScript.build("t2", steps)))

    results[0].stdout.should eq(payload)
  end

  it "runs every step when none fail" do
    steps = (1..3).map { |i| CrystalPlay::BatchScript::Step.new("/bin/cat", %({"changed":false,"failed":false,"msg":"#{i}"}), false) }

    results = CrystalPlay::BatchScript.parse(run_script(CrystalPlay::BatchScript.build("t3", steps)))

    results.size.should eq(3)
    results[2].stdout.should eq(%({"changed":false,"failed":false,"msg":"3"}))
  end

  it "halts before a step after one that self-reports failed:true (no ignore_errors)" do
    steps = [
      CrystalPlay::BatchScript::Step.new("/bin/cat", %({"changed":false,"failed":false,"msg":"ok"}), false),
      CrystalPlay::BatchScript::Step.new("/bin/cat", %({"changed":false,"failed":true,"msg":"boom"}), false),
      CrystalPlay::BatchScript::Step.new("/bin/cat", %({"changed":false,"failed":false,"msg":"never runs"}), false),
    ]

    results = CrystalPlay::BatchScript.parse(run_script(CrystalPlay::BatchScript.build("t4", steps)))

    results[0]?.should_not be_nil
    results[1]?.should_not be_nil
    results[2]?.should be_nil
  end

  it "continues past a failed:true step when that step has ignore_errors: true" do
    steps = [
      CrystalPlay::BatchScript::Step.new("/bin/cat", %({"changed":false,"failed":true,"msg":"boom"}), true),
      CrystalPlay::BatchScript::Step.new("/bin/cat", %({"changed":false,"failed":false,"msg":"still runs"}), false),
    ]

    results = CrystalPlay::BatchScript.parse(run_script(CrystalPlay::BatchScript.build("t5", steps)))

    results[0]?.should_not be_nil
    results[1]?.should_not be_nil
    results[1].stdout.should eq(%({"changed":false,"failed":false,"msg":"still runs"}))
  end

  it "halts on a nonzero exit code even when the (nonexistent) plugin never produces JSON at all" do
    steps = [
      CrystalPlay::BatchScript::Step.new("/bin/false", "", false),
      CrystalPlay::BatchScript::Step.new("/bin/cat", %({"changed":false,"failed":false,"msg":"never runs"}), false),
    ]

    results = CrystalPlay::BatchScript.parse(run_script(CrystalPlay::BatchScript.build("t6", steps)))

    results[0]?.should_not be_nil
    results[0].exit_code.should_not eq(0)
    results[1]?.should be_nil
  end

  it "cleans up its remote working directory after a normal finish" do
    steps = [CrystalPlay::BatchScript::Step.new("/bin/cat", %({"changed":false,"failed":false,"msg":"x"}), false)]
    script = CrystalPlay::BatchScript.build("t7-cleanup-check", steps)

    # Append a check for the directory's absence after the script's own
    # dump/cleanup runs, reusing the exact same $D the generated script
    # computed - proves `rm -rf "$D"` really ran, not just that the
    # script didn't error.
    script += "\n[ -d \"$D\" ] && echo STILL_EXISTS || echo GONE\n"

    output = run_script(script)
    output.should contain("GONE")
    output.should_not contain("STILL_EXISTS")
  end

  it "returns no entry at all for a step index that was never sent" do
    results = CrystalPlay::BatchScript.parse("OUT 0 0 aGk=\n")
    results[5]?.should be_nil
  end
end
