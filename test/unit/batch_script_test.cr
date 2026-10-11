require "../minitest_helper"
require "../../src/krikri/batch_script"

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

# The generated script's owner checks compare the directory's uid against
# the uid the script actually runs as, so a per-uid tag keeps consecutive
# spec runs by different accounts off each other's batch parent (the
# second run would otherwise fail closed on a foreign-owned parent).
private SPEC_USER = "spec-uid-#{LibC.getuid}"

private def build(batch_id : String, steps : Array(Krikri::BatchScript::Step)) : String
  Krikri::BatchScript.build(batch_id, steps, SPEC_USER)
end

describe Krikri::BatchScript do
  it "round-trips a step's config through /bin/cat and parses the result back" do
    steps = [
      Krikri::BatchScript::Step.new("/bin/cat", %({"changed":false,"failed":false,"msg":"hi"}), false),
    ]

    script = build("t1", steps)
    results = Krikri::BatchScript.parse(run_script(script))

    results[0]?.wont_be_nil
    r = results[0]
    r.exit_code.must_equal(0)
    r.stdout.must_equal(%({"changed":false,"failed":false,"msg":"hi"}))
  end

  it "preserves embedded newlines in stdout (base64 framing, not a text delimiter)" do
    payload = %({"changed":false,"failed":false,"msg":"line one\\nline two\\nline three"})
    steps = [Krikri::BatchScript::Step.new("/bin/cat", payload, false)]

    results = Krikri::BatchScript.parse(run_script(build("t2", steps)))

    results[0].stdout.must_equal(payload)
  end

  it "runs every step when none fail" do
    steps = (1..3).map { |i| Krikri::BatchScript::Step.new("/bin/cat", %({"changed":false,"failed":false,"msg":"#{i}"}), false) }

    results = Krikri::BatchScript.parse(run_script(build("t3", steps)))

    results.size.must_equal(3)
    results[2].stdout.must_equal(%({"changed":false,"failed":false,"msg":"3"}))
  end

  it "halts before a step after one that self-reports failed:true (no ignore_errors)" do
    steps = [
      Krikri::BatchScript::Step.new("/bin/cat", %({"changed":false,"failed":false,"msg":"ok"}), false),
      Krikri::BatchScript::Step.new("/bin/cat", %({"changed":false,"failed":true,"msg":"boom"}), false),
      Krikri::BatchScript::Step.new("/bin/cat", %({"changed":false,"failed":false,"msg":"never runs"}), false),
    ]

    results = Krikri::BatchScript.parse(run_script(build("t4", steps)))

    results[0]?.wont_be_nil
    results[1]?.wont_be_nil
    results[2]?.must_be_nil
  end

  it "continues past a failed:true step when that step has ignore_errors: true" do
    steps = [
      Krikri::BatchScript::Step.new("/bin/cat", %({"changed":false,"failed":true,"msg":"boom"}), true),
      Krikri::BatchScript::Step.new("/bin/cat", %({"changed":false,"failed":false,"msg":"still runs"}), false),
    ]

    results = Krikri::BatchScript.parse(run_script(build("t5", steps)))

    results[0]?.wont_be_nil
    results[1]?.wont_be_nil
    results[1].stdout.must_equal(%({"changed":false,"failed":false,"msg":"still runs"}))
  end

  it "continues past a NESTED failed:true key inside a successful result (uri-style body)" do
    # Regression for the grep-based fail check: uri: embeds a parsed JSON
    # response body at result.json, so an API answering {"failed": true}
    # with a 200 put the literal byte sequence `"failed":true` into a
    # SUCCESSFUL step's stdout - the old whole-file grep treated that as
    # a failure and aborted every remaining batch step. The generated
    # script now runs a depth-aware scan that only trips on the TOP-LEVEL
    # "failed" key.
    steps = [
      Krikri::BatchScript::Step.new("/bin/cat", %({"changed":false,"json":{"failed":true,"reason":"api says no"}}), false),
      Krikri::BatchScript::Step.new("/bin/cat", %({"changed":false,"failed":false,"msg":"still runs"}), false),
    ]

    results = Krikri::BatchScript.parse(run_script(build("t-nested-failed", steps)))

    results[0]?.wont_be_nil
    results[1]?.wont_be_nil
    results[1].stdout.must_equal(%({"changed":false,"failed":false,"msg":"still runs"}))
  end

  it "does not trip on an escaped failed:true copy inside a string value" do
    steps = [
      # /bin/cat echoes this config verbatim, so the step's stdout is a
      # result whose string field carries the literal text
      # `echo "failed":true ran` - with the quotes escaped in the JSON
      # serialization, exactly the shape a shell command's captured
      # output produces.
      Krikri::BatchScript::Step.new("/bin/cat", %({"changed":false,"stdout":"echo "failed":true ran"}), false),
      Krikri::BatchScript::Step.new("/bin/cat", %({"changed":false,"failed":false,"msg":"still runs"}), false),
    ]

    results = Krikri::BatchScript.parse(run_script(build("t-escaped-failed", steps)))

    results[0]?.wont_be_nil
    results[1]?.wont_be_nil
  end

  it "halts on a nonzero exit code even when the (nonexistent) plugin never produces JSON at all" do
    steps = [
      Krikri::BatchScript::Step.new("/bin/false", "", false),
      Krikri::BatchScript::Step.new("/bin/cat", %({"changed":false,"failed":false,"msg":"never runs"}), false),
    ]

    results = Krikri::BatchScript.parse(run_script(build("t6", steps)))

    results[0]?.wont_be_nil
    results[0].exit_code.wont_equal(0)
    results[1]?.must_be_nil
  end

  it "cleans up its remote working directory after a normal finish" do
    steps = [Krikri::BatchScript::Step.new("/bin/cat", %({"changed":false,"failed":false,"msg":"x"}), false)]
    script = build("t7-cleanup-check", steps)

    # Append a check for the directory's absence after the script's own
    # dump/cleanup runs, reusing the exact same $D the generated script
    # computed - proves `rm -rf "$D"` really ran, not just that the
    # script didn't error.
    script += "\n[ -d \"$D\" ] && echo STILL_EXISTS || echo GONE\n"

    output = run_script(script)
    output.must_include("GONE")
    output.wont_include("STILL_EXISTS")
  end

  it "returns no entry at all for a step index that was never sent" do
    results = Krikri::BatchScript.parse("OUT 0 0 aGk=\n")
    results[5]?.must_be_nil
  end

  it "streams each step's result to stdout before the next step starts" do
    # Regression for losing completed steps when the SSH transport dies
    # mid-script (live-verified on Atlantic.net, probe role
    # kop_sshd_batch vs ansible-core 2.19.11, 2026-10-08: real books the
    # pre-death task ok because each of its tasks is its own ssh round
    # trip; end-of-script-only dumping destroyed this engine's completed
    # step with the dead transport and recapped ok=1 vs real's ok=2).
    # Step 1's plugin kills the whole script process group mid-run,
    # simulating the transport death; with streaming, step 0's result is
    # already in the captured stdout. setsid gives the script its own
    # process group, so the group-kill cannot reach the test process.
    steps = [
      Krikri::BatchScript::Step.new("/bin/cat", %({"changed":false,"failed":false,"msg":"survives"}), false),
      Krikri::BatchScript::Step.new("/bin/bash", "kill -9 0", false),
    ]
    script = build("t-stream-death", steps)

    process = Process.new("setsid", ["bash"], input: Process::Redirect::Pipe, output: Process::Redirect::Pipe, error: Process::Redirect::Pipe)
    process.input.print(script)
    process.input.close
    output = process.output.gets_to_end
    process.wait

    output.must_include("OUT 0 ")
    results = Krikri::BatchScript.parse(output)
    results[0]?.wont_be_nil
    results[0].stdout.must_equal(%({"changed":false,"failed":false,"msg":"survives"}))
    # The killed script never produced step 1's result - run_batch_script
    # stamps that absence as unreachable (see stamp_missing_on_transport_
    # death); parse itself must not invent one.
    results[1]?.must_be_nil
  end

  it "emits a dump_one call per step in the generated script" do
    steps = [
      Krikri::BatchScript::Step.new("/bin/cat", %({"changed":false,"failed":false,"msg":"a"}), false),
      Krikri::BatchScript::Step.new("/bin/cat", %({"changed":false,"failed":false,"msg":"b"}), false),
    ]
    script = build("t-dump-one-structure", steps)
    script.must_include("dump_one 0\n")
    script.must_include("dump_one 1\n")
  end

  it "parse skips a truncated mid-stream base64 payload instead of crashing" do
    # A transport death can cut the FINAL streamed line mid-base64; the
    # partial bytes are not a step result (the step's outcome is unknown
    # and run_batch_script stamps it unreachable), so parse must leave
    # the step missing rather than raise on the decode.
    good = Base64.strict_encode(%({"changed":false,"failed":false,"msg":"hi"}))
    results = Krikri::BatchScript.parse("OUT 0 0 #{good}\nERR 0 0\nOUT 1 0 #{good[0..0]}\n")
    results[0]?.wont_be_nil
    results[1]?.must_be_nil
  end

  it "stamp_missing_on_transport_death stamps only steps whose results never arrived" do
    good = Base64.strict_encode(%({"changed":false,"failed":false,"msg":"hi"}))
    parsed = Krikri::BatchScript.parse("OUT 0 0 #{good}\nERR 0 0\n")
    result = Krikri::BatchScript.stamp_missing_on_transport_death(parsed, 255, "Shared connection to 10.0.0.1 closed.", 2)

    result[0].exit_code.must_equal(0)
    result[0].stdout.must_equal(%({"changed":false,"failed":false,"msg":"hi"}))
    result[1].exit_code.must_equal(255)
    result[1].stdout.must_equal("")
    result[1].stderr.must_equal("Shared connection to 10.0.0.1 closed.")
  end

  it "stamp_missing_on_transport_death leaves a healthy (exit 0) parse untouched" do
    parsed = Krikri::BatchScript.parse("")
    result = Krikri::BatchScript.stamp_missing_on_transport_death(parsed, 0, "", 2)
    result.size.must_equal(0)
  end

  it "names the batch parent after the per-connecting-user staging tag, not a shared path" do
    # Regression for the shared /var/tmp/.krikri-playbook/batch- parent:
    # two krikri users on one host used to share one entirely predictable
    # parent (sticky-world /var/tmp, CVE-2014-3498 class). The parent must
    # now carry the same <user>-<hash> tag the plugin staging dir uses,
    # and distinct users must map to distinct parents.
    steps = [Krikri::BatchScript::Step.new("/bin/cat", "{}", false)]

    deploy_script = Krikri::BatchScript.build("t8", steps, "deploy")
    deploy_tag = Krikri::PluginManager.staging_dir_tag("deploy")
    deploy_script.must_include("/var/tmp/.krikri-playbook-#{deploy_tag}/batch/batch-t8")

    root_script = Krikri::BatchScript.build("t8", steps, nil)
    root_script.must_include("/var/tmp/.krikri-playbook-#{Krikri::PluginManager.staging_dir_tag("root")}/batch/batch-t8")

    other_script = Krikri::BatchScript.build("t8", steps, "otheruser")
    other_tag = Krikri::PluginManager.staging_dir_tag("otheruser")
    other_script.wont_include(deploy_tag)
    deploy_script.wont_include(other_tag)
  end

  it "fails closed on the parent (no swallowed chmod) and owner-checks the batch dir too" do
    steps = [Krikri::BatchScript::Step.new("/bin/cat", "{}", false)]
    script = build("t9-checks", steps)

    # The old `chmod 700 "$P" 2>/dev/null || true` silently ignored a
    # failed chmod (the tell-tale sign someone else owns the dir); the
    # generated script must attempt it bare and let the owner check that
    # follows abort the run.
    script.must_include("chmod 700 \"$P\"\n")
    script.wont_include("chmod 700 \"$P\" 2>/dev/null || true")

    # The per-batch dir gets the same owner+symlink check the parent has
    # (the old asymmetry: parent verified, child blindly trusted).
    script.must_include(%(if [ -L "$D" ] || [ "$(stat -c %u "$D" 2>/dev/null)" != "$(id -u)" ]))
    # ...as does the per-user base the parent now lives under.
    script.must_include(%(if [ -L "$B" ] || { [ -e "$B" ] && [ "$(stat -c %u "$B" 2>/dev/null)" != "$(id -u)" ]; }))
  end
end
