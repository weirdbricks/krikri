require "./src/krikri/divergence_transcript"
require "file_utils"
require "random/secure"

# Capture one divergence corpus case's `expected.out` from REAL ansible.
#
#   bin/krikri-capture-case test/fixtures/divergence/<issue>-<slug>
#
# See test/fixtures/divergence/README.md for the rules this implements. The
# short version:
#
#   * the transcript must come from ansible-core 2.21.6, the pinned parity
#     target - never from krikri-playbook, whose output would enshrine the bug
#     being pinned. This tool therefore only ever spawns the ansible binary.
#   * the case runs in a scratch copy with HOME pointed at that copy, so a
#     `~/...` path in a case can never touch the developer's real home.
#   * the transcript is stdout followed by stderr (see
#     Krikri::DivergenceTranscript.combine for why a 2>&1 capture is not
#     reproducible) with the scratch directory normalized to `<WORK>`.
#   * the case's own flags.txt/inventory.ini decide the invocation, through
#     Krikri::DivergenceCase - the same module the replay spec uses.
#
# This is a build.sh-built binary rather than a script that compiles itself:
# a per-call `crystal build` would be slow and would take the host compile
# lock while a round is running.

CAPTURE_TARGET_VERSION = "2.21.6"
CAPTURE_USAGE          = [
  "usage: krikri-capture-case <case-dir>",
  "",
  "Captures <case-dir>/expected.out by running REAL ansible-playbook over a",
  "scratch copy of <case-dir>, for the divergence regression corpus replayed by",
  "test/integration/divergence_corpus_test.cr.",
  "",
  "environment:",
  "  ANSIBLE_PLAYBOOK_BIN      ansible-playbook to run (default /usr/bin/ansible-playbook)",
  "  ANSIBLE_SITE_PACKAGES     package tree to put on PYTHONPATH (default: discovered",
  "                            from the invoking shell's python3)",
  "",
  "The case runs with HOME set to its scratch copy, ANSIBLE_NOCOLOR=1 and the",
  "fact-gathering env vars unset (see Krikri::DivergenceCase.env). A case that",
  "executes modules must ship an inventory.ini pinning the interpreter on a",
  "[local] host; see the corpus README.",
].join("\n")

# The ansible-playbook this case is captured from. Overridable so a future box
# with a different layout does not need a code change, but never defaulted to
# krikri-playbook.
def capture_ansible_bin : String
  ENV["ANSIBLE_PLAYBOOK_BIN"]? || "/usr/bin/ansible-playbook"
end

# The site-packages tree holding the pinned ansible. This box carries
# ansible-core 2.21.6 in the invoking user's site-packages while /usr/bin has an
# older 2.19.11, and every case runs with HOME pointed at its scratch copy -
# which hides that user site-packages. Pinning the tree on PYTHONPATH is what
# keeps the capture on 2.21.6.
def capture_ansible_site : String
  if override = ENV["ANSIBLE_SITE_PACKAGES"]?
    return override
  end
  output = IO::Memory.new
  status = Process.run("python3",
    ["-c", "import ansible, os; print(os.path.dirname(os.path.dirname(ansible.__file__)))"],
    output: output, error: Process::Redirect::Close)
  unless status.success?
    STDERR.puts "error: could not locate the ansible package tree with python3; " \
                "set ANSIBLE_SITE_PACKAGES to the directory containing ansible/"
    exit 2
  end
  output.to_s.strip
end

def capture_scratch_dir : String
  dir = File.join(Dir.tempdir, "krikri-divergence-capture-#{Random::Secure.hex(6)}")
  Dir.mkdir_p(dir)
  dir
end

# Copy the case's INPUT into the scratch tree. expected.out/NOTES.md are the
# case's recorded result, not part of what it runs.
def capture_copy_case(case_dir : String, work_dir : String) : Nil
  Dir.children(case_dir).each do |entry|
    next if Krikri::DivergenceCase::RECORDED.includes?(entry)
    FileUtils.cp_r(File.join(case_dir, entry), File.join(work_dir, entry))
  end
  Dir.mkdir_p(File.join(work_dir, "home"))
end

# Run the ansible binary in the scratch copy and return its streams plus exit
# status. `env` carries the scratch HOME, the cleared fact-gathering variables
# and the PYTHONPATH pin.
def capture_run(work_dir : String, args : Array(String), env : Hash(String, String?)) : {String, String, Int32}
  stdout = IO::Memory.new
  stderr = IO::Memory.new
  status = Process.run(capture_ansible_bin, args,
    output: stdout, error: stderr, chdir: work_dir, env: env)
  {stdout.to_s, stderr.to_s, status.exit_code}
rescue ex : File::NotFoundError | File::Error
  STDERR.puts "error: cannot run #{capture_ansible_bin} (#{ex.message})"
  exit 2
end

case_dir = ARGV.first?
if case_dir.nil? || case_dir == "--help" || case_dir == "-h"
  STDOUT.puts CAPTURE_USAGE
  exit(case_dir.nil? ? 2 : 0)
end

case_dir = File.expand_path(case_dir)
unless File.exists?(File.join(case_dir, Krikri::DivergenceCase::PLAYBOOK))
  STDERR.puts "error: #{case_dir}/#{Krikri::DivergenceCase::PLAYBOOK} not found"
  exit 2
end

ansible_site = capture_ansible_site
unless Dir.exists?(File.join(ansible_site, "ansible"))
  STDERR.puts "error: no ansible package tree under #{ansible_site}; " \
              "set ANSIBLE_SITE_PACKAGES to the directory containing ansible/"
  exit 2
end

scratch = capture_scratch_dir
begin
  work = File.join(scratch, "case")
  Dir.mkdir_p(work)
  capture_copy_case(case_dir, work)

  env = Krikri::DivergenceCase.env(File.join(work, "home"), work)
  env["PYTHONPATH"] = ansible_site

  # Refuse to capture from anything but the pinned parity target: a transcript
  # recorded from a different ansible-core release pins that release's warning
  # text and doclinks, and the case would be wrong from the day it landed.
  version_stdout, version_stderr, _version_rc = capture_run(work, ["--version"], env)
  first_line = (version_stdout + version_stderr).lines.first? || ""
  unless first_line.includes?("core #{CAPTURE_TARGET_VERSION}")
    STDERR.puts "error: expected ansible-core #{CAPTURE_TARGET_VERSION} (the pinned parity " \
                "target), got: #{first_line}"
    exit 2
  end

  stdout, stderr, rc = capture_run(work, Krikri::DivergenceCase.run_args(work), env)
  transcript = Krikri::DivergenceTranscript.combine(stdout, stderr, work)
  expected_path = File.join(case_dir, "expected.out")
  File.write(expected_path, transcript)
  STDOUT.puts "captured #{expected_path} (ansible exit #{rc}, #{transcript.bytesize} bytes)"
ensure
  FileUtils.rm_rf(scratch)
end
