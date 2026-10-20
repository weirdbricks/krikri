require "../minitest_helper"

# Broken stdio pipes must surface as IO::Error, not kill the process.
# The entrypoints guarantee that (krikri-playbook.cr and base_plugin.cr
# for the plugin binaries): Crystal 1.22 moved the stdlib's default
# signal handlers (Signal::PIPE.ignore included) inside
# Crystal::System::Signal.setup_default_handlers instead of guaranteeing
# them before user code, AND made the stdio streams call LibC.exit(141)
# themselves on an EPIPE write (IO::FileDescriptor's exit_on_broken_pipe,
# set by from_stdio) - the latter is what made `krikri-playbook ... |
# head -N` die silently with 141 on 1.22. The entrypoints ignore SIGPIPE
# explicitly and turn the stdio self-exit off, restoring the pre-1.22
# behavior where the EPIPE raises and (with nothing rescuing it) used to
# dump a full Crystal stack trace and exit 1.
#
# ansible-playbook is silent and exits 0 in the same situation
# (verified directly against ansible-playbook/ansible: `--help | head -1`
# and `--version | head -1` each produce no stderr and PIPESTATUS[0]=0).
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "test", "fixtures", "inventory-explicit-localhost.ini")

# Runs *shell_command* and returns {exit status of the FIRST pipeline
# element, stderr}. PIPESTATUS[0] is what matters here - the pipeline's
# own status belongs to the reader (head), not to us.
private def run_pipeline(shell_command : String)
  err = IO::Memory.new
  stdout_io = IO::Memory.new
  status = Process.run("bash", ["-c", "#{shell_command}; echo \"RC=${PIPESTATUS[0]}\" >&2"],
    output: stdout_io, error: err)
  {status, err.to_s}
end

describe "broken pipe (reader exits early)" do
  it "exits quietly with status 0 when --help output is truncated by head" do
    _, stderr = run_pipeline("#{BINARY} --help | head -1 > /dev/null")

    stderr.wont_include("Unhandled exception")
    stderr.wont_include("Broken pipe")
    stderr.must_include("RC=0")
  end

  it "exits quietly with status 0 when --version output is truncated by head" do
    _, stderr = run_pipeline("#{BINARY} --version | head -1 > /dev/null")

    stderr.wont_include("Unhandled exception")
    stderr.wont_include("Broken pipe")
    stderr.must_include("RC=0")
  end

  it "exits quietly when a real playbook run's output is truncated by head" do
    playbook = File.tempname("broken-pipe", ".yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: lots of output
            ansible.builtin.debug:
              msg: "line {{ item }}"
            loop: "{{ range(1, 400) | list }}"
      YAML

    begin
      _, stderr = run_pipeline("#{BINARY} -i #{INVENTORY} #{playbook} | head -2 > /dev/null")

      stderr.wont_include("Unhandled exception")
      stderr.wont_include("Broken pipe")
      stderr.must_include("RC=0")
    ensure
      File.delete(playbook) if File.exists?(playbook)
    end
  end

  # Guards the fix against over-reach: a reader that stays open must
  # still get the COMPLETE output, and the real exit status must survive.
  it "still delivers complete output and the real exit status to a reader that stays open" do
    playbook = File.tempname("broken-pipe-full", ".yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: lots of output
            ansible.builtin.debug:
              msg: "line {{ item }}"
            loop: "{{ range(1, 400) | list }}"
          - name: boom
            ansible.builtin.command: /bin/false
      YAML

    begin
      stdout_io = IO::Memory.new
      err = IO::Memory.new
      status = Process.run("bash",
        ["-c", "#{BINARY} -i #{INVENTORY} #{playbook} 2>/dev/null | cat; echo \"RC=${PIPESTATUS[0]}\""],
        output: stdout_io, error: err)
      status.success?.must_equal(true)

      combined = stdout_io.to_s
      # Every loop item made it through - the fix must not truncate.
      combined.scan(/^\s{4}"msg": "line \d+"$/m).size.must_equal(399)
      # And the failing task's real exit code (2) is preserved, not
      # replaced by the broken-pipe path's 0.
      combined.must_include("RC=2")
    ensure
      File.delete(playbook) if File.exists?(playbook)
    end
  end
end
