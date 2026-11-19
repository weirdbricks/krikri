require "../minitest_helper"
require "../../src/krikri/divergence_transcript"

# The divergence corpus compares whole transcripts, so the one piece of
# post-processing both sides share - normalize the scratch path, concatenate
# stdout then stderr, report the first diverging line - is what these specs
# pin. If the capture tool and the replay spec ever normalized differently,
# every case would fail (or worse, pass for the wrong reason).
describe "divergence transcript" do
  it "rewrites the scratch directory to <WORK>, everywhere it appears" do
    text = "Origin: /tmp/case/roles/r/tasks/main.yml:3:1\n" \
           "included: /tmp/case/roles/r/tasks/x.yml for localhost\n"
    Krikri::DivergenceTranscript
      .normalize(text, "/tmp/case")
      .must_equal("Origin: <WORK>/roles/r/tasks/main.yml:3:1\n" \
                  "included: <WORK>/roles/r/tasks/x.yml for localhost\n")
  end

  it "leaves every other path in the transcript alone" do
    text = "Origin: /tmp/other/case/playbook.yml:8:13\n" \
           "and /tmp/case-lookalike/playbook.yml\n"
    # Only the exact scratch path is normalized: a different directory that
    # merely shares a prefix must keep its own spelling, or two engines'
    # transcripts could be forced equal by an over-broad replacement.
    Krikri::DivergenceTranscript
      .normalize(text, "/tmp/case")
      .must_equal("Origin: /tmp/other/case/playbook.yml:8:13\n" \
                  "and /tmp/case-lookalike/playbook.yml\n")
  end

  it "returns the text unchanged for an empty work directory" do
    text = "PLAY RECAP\nlocalhost : ok=1\n"
    Krikri::DivergenceTranscript.normalize(text, "").must_equal(text)
  end

  it "concatenates stdout then stderr and normalizes both" do
    stdout = "PLAY [/tmp/case/play.yml] ***\nok: [localhost]\n"
    stderr = "[WARNING]: /tmp/case/roles/r/defaults/main.yml:2:22\n"
    Krikri::DivergenceTranscript
      .combine(stdout, stderr, "/tmp/case")
      .must_equal("PLAY [<WORK>/play.yml] ***\nok: [localhost]\n" \
                  "[WARNING]: <WORK>/roles/r/defaults/main.yml:2:22\n")
  end

  it "keeps stderr after stdout even when stderr came first chronologically" do
    # Real ansible block-buffers stdout when redirected, so its stderr lands
    # after the whole of stdout; krikri line-buffers and interleaves. The
    # combine step is what makes the two comparable, so the order is
    # stdout-then-stderr by definition, never by arrival time.
    combined = Krikri::DivergenceTranscript.combine("out\n", "err\n", "/tmp/case")
    combined.must_equal("out\nerr\n")
  end

  it "reports nothing when the transcripts are identical" do
    Krikri::DivergenceTranscript.report("a\nb\n", "a\nb\n").must_equal("")
  end

  it "reports the first diverging line with context and both sizes" do
    expected = "1\n2\n3\n4\n5\n6\n7\n8\n"
    actual = "1\n2\n3\n4\nCHANGED\n6\n7\n8\n"
    report = Krikri::DivergenceTranscript.report(expected, actual)

    report.must_include("transcript diverges at line 5")
    report.must_include("- 5\n")
    report.must_include("+ CHANGED\n")
    report.must_include("  2\n")
    report.must_include("  7\n")
    report.must_include("expected #{expected.bytesize} bytes, got #{actual.bytesize} bytes")
  end

  it "reports a transcript that stops early" do
    report = Krikri::DivergenceTranscript.report("a\nb\n", "a\n")
    report.must_include("transcript diverges at line 2")
    report.must_include("- b\n")
    # An extra blank line real printed and krikri did not is a divergence in
    # its own right (the transcript is exact), so the missing side shows as
    # an empty `+` line rather than being smoothed over.
    Krikri::DivergenceTranscript.report("a\n", "a\n\n").must_include("- \n")
  end
end

describe "divergence case invocation" do
  it "reads flags.txt as one CLI argument per line, ignoring blanks" do
    dir = PluginSpecHelper.tmp_path("divergence-case-flags-#{Random::Secure.hex(4)}")
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, "flags.txt"), "--check\n\n  -e  \nsudo_pair_unpack_directory=x\n")
    Krikri::DivergenceCase.flags(dir).must_equal(["--check", "-e", "sudo_pair_unpack_directory=x"])
  end

  it "uses no flags for a case without flags.txt" do
    dir = PluginSpecHelper.tmp_path("divergence-case-noflags-#{Random::Secure.hex(4)}")
    FileUtils.mkdir_p(dir)
    Krikri::DivergenceCase.flags(dir).must_equal([] of String)
  end

  it "prefers a case's own inventory over the implicit localhost" do
    dir = PluginSpecHelper.tmp_path("divergence-case-inv-#{Random::Secure.hex(4)}")
    FileUtils.mkdir_p(dir)
    Krikri::DivergenceCase.inventory_args(dir).must_equal(["-i", "localhost,"])
    File.write(File.join(dir, "inventory.ini"), "[local]\nlocalhost ansible_connection=local\n")
    Krikri::DivergenceCase.inventory_args(dir).must_equal(["-i", "inventory.ini"])
  end

  it "builds inventory, connection, flags and the playbook in that order" do
    dir = PluginSpecHelper.tmp_path("divergence-case-args-#{Random::Secure.hex(4)}")
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, "flags.txt"), "--check\n")
    File.write(File.join(dir, "inventory.ini"), "[local]\nlocalhost ansible_connection=local\n")
    Krikri::DivergenceCase.run_args(dir).must_equal(
      ["-i", "inventory.ini", "-c", "local", "--check", "playbook.yml"])
  end

  it "pins the environment and clears the fact-gathering variables" do
    env = Krikri::DivergenceCase.env("/tmp/case/home")
    env["ANSIBLE_NOCOLOR"].must_equal("1")
    env["HOME"].must_equal("/tmp/case/home")
    # nil removes the variable: this box exports these, and either one changes
    # the task list or the facts a case runs against.
    env["ANSIBLE_GATHERING"]?.must_be_nil
    env["ANSIBLE_CACHE_PLUGIN"]?.must_be_nil
    env["ANSIBLE_CACHE_PLUGIN_CONNECTION"]?.must_be_nil
    env.has_key?("ANSIBLE_GATHERING").must_equal(true)
  end

  it "treats expected.out and NOTES.md as recorded results, not input" do
    Krikri::DivergenceCase::RECORDED.includes?("expected.out").must_equal(true)
    Krikri::DivergenceCase::RECORDED.includes?("NOTES.md").must_equal(true)
    Krikri::DivergenceCase::RECORDED.includes?("playbook.yml").must_equal(false)
  end
end
