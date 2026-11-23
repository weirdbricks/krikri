require "../minitest_helper"
require "../../src/krikri/divergence_transcript"

# One `it` per case, in its own file: a branch capturing a case adds a file
# instead of editing this one, so concurrent branches never conflict here.
require "./divergence_cases/*"

# The divergence regression corpus: one `it` per case under
# test/fixtures/divergence/<issue>-<slug>/, each asserting that
# krikri-playbook's FULL transcript (stdout followed by stderr, after the
# scratch directory is normalized to <WORK>) equals the transcript real
# ansible-playbook 2.21.6 prints for the same role YAML.
#
# This is deliberately the opposite of the old hand-written regression tests'
# `must_include` assertions: those could only catch MISSING output, so a fix
# that started printing an extra warning block still passed. A corpus case's
# expected.out is captured from real ansible (bin/krikri-capture-case, rules in
# test/fixtures/divergence/README.md) and never from krikri's own output, which
# would enshrine the bug. Normalization, the stdout-then-stderr ordering and the
# failure report come from Krikri::DivergenceTranscript, the same module the
# capture tool writes through.
#
# The suite runs krikri-playbook as a subprocess, exactly like
# inject_facts_deprecation_test.cr.
#
# Cases that cannot run in-process (real package/service/crontab/pip mutation)
# are listed in test/fixtures/divergence/live/cases.txt for a real-host round
# instead, and are not replayed here.
private DIVERGENCE_ROOT   = File.expand_path("../fixtures/divergence", __DIR__)
private DIVERGENCE_BINARY = File.expand_path("../../bin/krikri-playbook", __DIR__)

# Every corpus case, derived from the fixtures themselves: a `<issue>-<slug>`
# directory with a playbook.yml under test/fixtures/divergence/ is a case, and
# a directory without one is not. This used to be a hand-kept list, so every
# fix branch that captured a case appended to this same array and to an `it`
# below it: branches landing together then conflicted on this file at rebase
# time and their fixes were lost (issue #1726, #1727, #1738, #1733 in one
# night). The directory is the listing; the guard below still refuses a
# directory that is not named like a case.
private DIVERGENCE_CASES = Dir.children(DIVERGENCE_ROOT)
  .select { |entry| File.directory?(File.join(DIVERGENCE_ROOT, entry)) }
  .reject { |entry| entry == "live" }
  .select { |entry| File.exists?(File.join(DIVERGENCE_ROOT, entry, "playbook.yml")) }
  .map do |entry|
    issue, slug = entry.split('-', 2)
    {issue: issue.to_i, slug: slug}
  end
  .sort_by { |kase| {kase[:issue], kase[:slug]} }

private def divergence_case_dir(issue : Int32, slug : String) : String
  "#{issue}-#{slug}"
end

# Run krikri-playbook over a copy of the case in private scratch space, the
# way the suite runs every playbook, and return its normalized transcript.
private def replay_divergence_case(issue : Int32, slug : String) : String
  name = divergence_case_dir(issue, slug)
  source = File.join(DIVERGENCE_ROOT, name)
  dir = PluginSpecHelper.tmp_path("divergence-#{name}-#{Random::Secure.hex(4)}")
  FileUtils.mkdir_p(File.join(dir, "home"))
  Dir.children(source).each do |entry|
    # expected.out/NOTES.md are the case's recorded result, not its input.
    next if Krikri::DivergenceCase::RECORDED.includes?(entry)
    FileUtils.cp_r(File.join(source, entry), File.join(dir, entry))
  end

  stdout = IO::Memory.new
  stderr = IO::Memory.new
  # The invocation and environment are Krikri::DivergenceCase's: the case's
  # optional flags.txt/inventory.ini decide the argv, HOME is the case's own
  # scratch dir (a `~/...` path must never reach the developer's real home),
  # an optional env.txt may move the case's own environment, and the
  # fact-gathering env vars are cleared.
  Process.run(
    DIVERGENCE_BINARY,
    Krikri::DivergenceCase.run_args(dir),
    output: stdout,
    error: stderr,
    chdir: dir,
    env: Krikri::DivergenceCase.env(File.join(dir, "home"), dir),
  )

  # stdout then stderr, normalized to <WORK>: the same combine the capture tool
  # writes expected.out with.
  Krikri::DivergenceTranscript.combine(stdout.to_s, stderr.to_s, dir)
end

# The whole point of the corpus: the FULL transcript must equal real ansible's,
# so an extra warning block fails exactly like a missing one. Returns the
# recorded and replayed transcripts plus the failure report, which each `it`
# hands to assert_equal (minitest's assertions are only available inside a
# spec).
# Public because each case's `it` lives in its own required file, and a
# private top-level def is only visible in the file that defines it.
def divergence_transcripts(issue : Int32, slug : String) : {String, String, String}
  name = divergence_case_dir(issue, slug)
  expected = File.read(File.join(DIVERGENCE_ROOT, name, "expected.out"))
  actual = replay_divergence_case(issue, slug)
  {expected, actual, "#{name}: #{Krikri::DivergenceTranscript.report(expected, actual)}"}
end

describe "divergence corpus" do
  it "replays every case directory exactly once" do
    replayed = Dir.children(File.join(__DIR__, "divergence_cases"))
      .select { |entry| entry.ends_with?(".cr") }
      .map { |entry| entry.rchop(".cr") }
    expected = DIVERGENCE_CASES.map { |kase| divergence_case_dir(kase[:issue], kase[:slug]) }
    replayed.sort.must_equal(expected.sort)
    # The file name alone is not enough: the gate selects a case by its test
    # method name, and a replay run that matches no test exits 0 - a hand-written
    # file with a misspelled `it` would pass the gate without replaying anything.
    replayed.each do |name|
      body = File.read(File.join(__DIR__, "divergence_cases", "#{name}.cr"))
      body.scan(/it "replays [^"]+"/).size.must_equal(1, "divergence_cases/#{name}.cr must declare exactly one replay")
      body.must_include(%(it "replays #{name}" do))
    end
    # Two slugs that fold to the same minitest method would silently drop one.
    methods = replayed.map { |name| name.strip.gsub(/[^\p{L}\p{N}]+/, "_") }
    methods.uniq.size.must_equal(methods.size, "two cases fold to the same test method name")
  end

  it "names every case directory <issue>-<slug> and ships its playbook" do
    Dir.children(DIVERGENCE_ROOT)
      .select { |entry| File.directory?(File.join(DIVERGENCE_ROOT, entry)) }
      .reject { |entry| entry == "live" }
      .each do |entry|
        entry.matches?(/\A\d+-\S+\z/).must_equal(true, "#{entry} is not named <issue>-<slug>")
        File.exists?(File.join(DIVERGENCE_ROOT, entry, "playbook.yml"))
          .must_equal(true, "#{entry} has no playbook.yml, so the corpus would silently skip it")
      end
  end
end
