require "../minitest_helper"
require "file_utils"

# testing/lint/parity.py is Python, so these specs pin its two contracts with
# stub linters instead of needing ansible-lint itself in the fast suite: the
# argv it hands both tools (with no --enable-list an opt-in rule reports nothing
# and the run reads clean, issue #1926), and the rule-catalogue diff (a missing
# id stays invisible until a corpus file trips it, issue #1930).
describe "lint parity harness" do
  it "enables opt-in rules on both linters" do
    python = Process.find_executable("python3") || Process.find_executable("python")
    skip "no python on this host (the harness is a Python script)" unless python

    dir = PluginSpecHelper.tmp_path("parity-harness")
    FileUtils.mkdir_p(dir)
    target = File.join(dir, "pb.yml")
    File.write(target, "---\n- name: Play\n  hosts: all\n  tasks: []\n")

    krikri = write_parity_linter_stub(File.join(dir, "krikri-lint"), target, "no-same-owner")
    ansible = write_parity_linter_stub(File.join(dir, "ansible-lint"), target, "no-same-owner")

    output = IO::Memory.new
    status = Process.run(
      python,
      [File.join(PluginSpecHelper::PROJECT_ROOT, "testing", "lint", "parity.py"),
       "--krikri", krikri, "--ansible-lint", ansible, target],
      output: output,
      error: output
    )
    status.success?.must_equal(true)
    output.to_s.must_include("PARITY| files=1 matched=1 krikri_only=0 upstream_only=0 unimplemented=0")
    output.to_s.must_include("CATALOGUE| upstream=1 krikri=1 allowed=0 missing=0")
  end

  # The harness used to compare only triples, so a rule id krikri has no rule
  # for stayed invisible until a corpus file happened to trip it - and even
  # then its triples were bucketed as `unimplemented`, which did not touch the
  # exit code (issue #1930, where no-prompting was the id that hid). The
  # catalogue diff has to fail on such an id without any corpus file, and it
  # must not report the structural internals ansible-lint lists as rules
  # (parser-error here) as gaps.
  it "fails on an upstream rule neither implemented nor on the allowance list" do
    python = Process.find_executable("python3") || Process.find_executable("python")
    skip "no python on this host (the harness is a Python script)" unless python

    dir = PluginSpecHelper.tmp_path("parity-catalogue")
    FileUtils.mkdir_p(dir)
    target = File.join(dir, "pb.yml")
    File.write(target, "---\n- name: Play\n  hosts: all\n  tasks: []\n")

    krikri = write_rule_listing_stub(File.join(dir, "krikri-lint"), "--list-rules",
      ["name   MEDIUM   idiom"])
    ansible = write_rule_listing_stub(File.join(dir, "ansible-lint"), "-L",
      ["- name Name rule.", "- loop-var-prefix Role loop_var should use configured prefix.",
       "- parser-error ansible parser fails."])

    output = IO::Memory.new
    status = Process.run(
      python,
      [File.join(PluginSpecHelper::PROJECT_ROOT, "testing", "lint", "parity.py"),
       "--krikri", krikri, "--ansible-lint", ansible, target],
      output: output,
      error: output
    )
    status.success?.must_equal(false)
    output.to_s.must_include("CATALOGUE| upstream=3 krikri=1 allowed=1 missing=1")
    output.to_s.must_include("  missing: loop-var-prefix (not implemented and not in CATALOGUE_ALLOW)")
    output.to_s.wont_include("missing: name")
    output.to_s.wont_include("missing: parser-error")
  end
end

# A stub linter that advertises one opt-in rule for --list-rules and reports it
# only when --enable-list named it, the way both real linters behave.
private def write_parity_linter_stub(path : String, target : String, rule : String) : String
  File.write(path, <<-SH)
    #!/bin/sh
    for arg in "$@"; do
      if [ "$arg" = "--list-rules" ]; then
        echo "#{rule}"
        exit 0
      fi
      if [ "$arg" = "-L" ]; then
        echo "- #{rule} opt-in rule"
        exit 0
      fi
    done
    for arg in "$@"; do
      if [ "$arg" = "#{rule}" ]; then
        echo "#{target}:7: #{rule}: opt-in rule fired"
        exit 0
      fi
    done
    exit 0
    SH
  File.chmod(path, 0o755)
  path
end

# A stub linter with no triples at all: only its rule listing matters, which is
# what the catalogue diff reads (`ansible-lint -L` lines, `krikri-lint
# --list-rules` ids).
private def write_rule_listing_stub(path : String, flag : String, listing : Array(String)) : String
  File.write(path, String.build do |script|
    script << "#!/bin/sh\n"
    script << "for arg in \"$@\"; do\n"
    script << "  if [ \"$arg\" = #{flag.inspect} ]; then\n"
    listing.each { |line| script << "    echo #{line.inspect}\n" }
    script << "    exit 0\n"
    script << "  fi\n"
    script << "done\n"
    script << "exit 0\n"
  end)
  File.chmod(path, 0o755)
  path
end
