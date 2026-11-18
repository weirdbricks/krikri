require "file_utils"
require "../minitest_helper"

# `serial:` batches a play: Ansible runs the WHOLE play against one
# batch of hosts at a time, which is what makes a rolling restart
# rolling. This engine ignored the keyword entirely, so `serial: 1` still
# hit every host simultaneously - the batching that exists to protect a
# fleet silently did nothing.
#
# Every expected ordering below is from an ansible-core 2.19.4 run of the
# same playbook over four hosts.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")

private def run_serial(serial : String?) : Array(String)
  dir = File.tempname("serial")
  Dir.mkdir_p(dir)
  File.write(File.join(dir, "inv.ini"),
    "[g]\nh1 ansible_connection=local\nh2 ansible_connection=local\n" \
    "h3 ansible_connection=local\nh4 ansible_connection=local\n")
  serial_line = serial ? "  serial: #{serial}\n" : ""
  File.write(File.join(dir, "pb.yml"), <<-YAML)
    - hosts: all
      gather_facts: false
    #{serial_line.rstrip}
      tasks:
        - name: a
          ansible.builtin.debug: {msg: "A-{{ inventory_hostname }}"}
        - name: b
          ansible.builtin.debug: {msg: "B-{{ inventory_hostname }}"}
    YAML

  stdout_io = IO::Memory.new
  Process.run(BINARY, ["-i", "inv.ini", "pb.yml"], output: stdout_io, error: stdout_io, chdir: dir)
  stdout_io.to_s.scan(/^\s{4}"msg": "([AB]-h\d)"$/m).map { |mat| mat[1] }
ensure
  FileUtils.rm_rf(dir) if dir && Dir.exists?(dir)
end

# Same playbook, but keeping the streams apart and the exit code: real
# ansible-playbook DIES on an unconvertible `serial:` token before it ever
# prints a play, and an engine that merely falls back to "one batch of
# every host" instead runs the whole play the reference host aborted.
private def run_serial_streams(serial : String, env : Hash(String, String | Nil)? = nil) : {Int32, String, String}
  dir = File.tempname("serial")
  Dir.mkdir_p(dir)
  File.write(File.join(dir, "inv.ini"),
    "[g]\nh1 ansible_connection=local\nh2 ansible_connection=local\n" \
    "h3 ansible_connection=local\nh4 ansible_connection=local\n")
  File.write(File.join(dir, "pb.yml"), <<-YAML)
    - hosts: all
      gather_facts: false
      serial: #{serial}
      tasks:
        - name: a
          ansible.builtin.debug: {msg: "A-{{ inventory_hostname }}"}
    YAML

  stdout_io = IO::Memory.new
  stderr_io = IO::Memory.new
  status = Process.run(BINARY, ["-i", "inv.ini", "pb.yml"], output: stdout_io, error: stderr_io, chdir: dir, env: env)
  {status.exit_code, stdout_io.to_s, stderr_io.to_s}
ensure
  FileUtils.rm_rf(dir) if dir && Dir.exists?(dir)
end

describe "serial:" do
  # One host at a time: the whole play (both tasks) finishes for h1
  # before h2 starts.
  it "runs the whole play per host for serial: 1" do
    run_serial("1").must_equal(%w[A-h1 B-h1 A-h2 B-h2 A-h3 B-h3 A-h4 B-h4])
  end

  it "batches two at a time for serial: 2" do
    run_serial("2").must_equal(%w[A-h1 A-h2 B-h1 B-h2 A-h3 A-h4 B-h3 B-h4])
  end

  # A percentage is of the TOTAL host count, rounded up.
  it "accepts a percentage" do
    run_serial(%("50%")).must_equal(%w[A-h1 A-h2 B-h1 B-h2 A-h3 A-h4 B-h3 B-h4])
  end

  # pct_to_int strips EVERY '%' before int()ing the rest, not just the
  # trailing one: "50%%" is int("50"), i.e. 50% of the hosts
  # (live-verified vs 2.21.6).
  it "strips every percent sign like ansible" do
    run_serial(%("50%%")).must_equal(%w[A-h1 A-h2 B-h1 B-h2 A-h3 A-h4 B-h3 B-h4])
  end

  # A list sizes successive batches, and the LAST entry sizes every
  # remaining batch - so [1, 2] over four hosts is 1, then 2, then the
  # one host left.
  it "accepts a list of batch sizes" do
    run_serial("[1, 2]").must_equal(%w[A-h1 B-h1 A-h2 A-h3 B-h2 B-h3 A-h4 B-h4])
  end

  it "handles a batch larger than the remainder" do
    run_serial("3").must_equal(%w[A-h1 A-h2 A-h3 B-h1 B-h2 B-h3 A-h4 B-h4])
  end

  it "treats 100% as a single batch" do
    run_serial(%("100%")).must_equal(%w[A-h1 A-h2 A-h3 A-h4 B-h1 B-h2 B-h3 B-h4])
  end

  # Guard: without serial: the play still runs every host at once.
  it "is a no-op when absent" do
    run_serial(nil).must_equal(%w[A-h1 A-h2 A-h3 A-h4 B-h1 B-h2 B-h3 B-h4])
  end

  # Real's PlaybookExecutor._get_serialized_batches runs helpers.pct_to_int
  # over the play's serial tokens right before the play starts, and int()
  # raises an uncaught ValueError for a non-numeric token, so the whole run
  # dies with this stderr block and rc=250, before any play output
  # (live-verified vs ansible-core 2.21.6, issue #1446 - kpg's
  # `serial: kpg-many`).
  it "dies on a non-integer serial token like ansible" do
    code, stdout, stderr = run_serial_streams("kpg-many")
    code.must_equal 250
    stdout.must_be_empty
    stderr.must_include "[ERROR]: Unexpected Exception, this is probably a bug: " \
                        "invalid literal for int() with base 10: 'kpg-many'"
    stderr.must_include "line 32, in pct_to_int"
    stderr.must_include "    return int(value)"
    stderr.must_include "ansible.errors.AnsibleError: Unexpected Exception, " \
                        "this is probably a bug: invalid literal for int() with base 10: 'kpg-many'"
    stderr.wont_include "PLAY RECAP"
  end

  # The install path the frames spell, and the PEP 657 caret runs under
  # them, belong to the ansible-core that would have printed the block on
  # this host: a root pip install lives under /usr/local/lib/python3.X,
  # a `pip install --user` one under ~/.local, and Python 3.13 stops
  # printing the carets for a frame whose failing instruction is a plain
  # call statement - every frame here - while 3.11/3.12 print one under
  # each (live-verified vs ansible-core 2.21.6, issue #1540). The fixture
  # installs are the assertions' paths, so neither depends on which
  # ansible the test machine happens to carry.
  it "spells the traceback with the host ansible install's path and carets" do
    home = File.tempname("serial-home")
    begin
      install = File.join(home, ".local", "lib", "python3.12", "site-packages", "ansible")
      Dir.mkdir_p(File.join(install, "utils"))
      File.write(File.join(install, "utils", "helpers.py"), "")
      _code, _stdout, stderr = run_serial_streams("kpg-many", env: {"HOME" => home})
      stderr.must_include "  File \"#{install}/cli/__init__.py\", line 663, in cli_executor\n" \
                          "    exit_code = cli.run()\n" \
                          "                ^^^^^^^^^\n"
      stderr.must_include "  File \"#{install}/utils/helpers.py\", line 32, in pct_to_int\n" \
                          "    return int(value)\n" \
                          "           ^^^^^^^^^^\n"

      FileUtils.mv(File.join(home, ".local", "lib", "python3.12"),
        File.join(home, ".local", "lib", "python3.13"))
      install = File.join(home, ".local", "lib", "python3.13", "site-packages", "ansible")
      _code, _stdout, stderr = run_serial_streams("kpg-many", env: {"HOME" => home})
      stderr.must_include "  File \"#{install}/utils/helpers.py\", line 32, in pct_to_int\n" \
                          "    return int(value)\n" \
                          "ValueError:"
      stderr.wont_include "^^^^^^^^^"
    ensure
      FileUtils.rm_rf(home)
    end
  end

  # The percentage branch int()s the text before the '%', so a fractional
  # or non-numeric percentage dies in that same first traceback frame -
  # a different helpers.py line from the plain branch above
  # (live-verified vs 2.21.6).
  it "dies when a serial percentage prefix is not an integer" do
    code, stdout, stderr = run_serial_streams(%("abc%"))
    code.must_equal 250
    stdout.must_be_empty
    stderr.must_include "invalid literal for int() with base 10: 'abc'"
    stderr.must_include "line 29, in pct_to_int"
    stderr.must_include "    value_pct = int(value.replace(\"%\", \"\"))"
  end

  # int() accepts a non-integer YAML literal: int(2.5) is 2 and int(True)
  # is 1 (live-verified vs 2.21.6), so those literals batch instead of
  # being read as one batch of every host.
  it "truncates a float serial literal" do
    run_serial("2.5").must_equal(%w[A-h1 A-h2 B-h1 B-h2 A-h3 A-h4 B-h3 B-h4])
  end

  it "treats a boolean serial literal as one" do
    run_serial("true").must_equal(%w[A-h1 B-h1 A-h2 B-h2 A-h3 B-h3 A-h4 B-h4])
  end

  # Only the tokens real actually reaches are converted: [4, kpg-many]
  # over four hosts eats every host in its first batch, so the bad second
  # entry is never looked at (live-verified vs 2.21.6).
  it "does not convert serial entries past the last batch" do
    run_serial("[4, kpg-many]").must_equal(%w[A-h1 A-h2 A-h3 A-h4 B-h1 B-h2 B-h3 B-h4])
  end
end
