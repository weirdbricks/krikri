require "../spec_helper"

# Crystal sets SIGPIPE to ignore, so writing to a pipe whose reader has
# already exited surfaces as an IO::Error rather than killing the
# process. With nothing rescuing it, `krikri-playbook ... | head -N`
# dumped a full Crystal stack trace to stderr and exited 1.
#
# Real ansible-playbook is silent and exits 0 in the same situation
# (verified directly against ansible-playbook/ansible: `--help | head -1`
# and `--version | head -1` each produce no stderr and PIPESTATUS[0]=0).
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "spec", "fixtures", "inventory-explicit-localhost.ini")

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

    stderr.should_not contain("Unhandled exception")
    stderr.should_not contain("Broken pipe")
    stderr.should contain("RC=0")
  end

  it "exits quietly with status 0 when --version output is truncated by head" do
    _, stderr = run_pipeline("#{BINARY} --version | head -1 > /dev/null")

    stderr.should_not contain("Unhandled exception")
    stderr.should_not contain("Broken pipe")
    stderr.should contain("RC=0")
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

      stderr.should_not contain("Unhandled exception")
      stderr.should_not contain("Broken pipe")
      stderr.should contain("RC=0")
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
      status.success?.should be_true

      combined = stdout_io.to_s
      # Every loop item made it through - the fix must not truncate.
      combined.scan(/^  line \d+$/m).size.should eq(399)
      # And the failing task's real exit code (2) is preserved, not
      # replaced by the broken-pipe path's 0.
      combined.should contain("RC=2")
    ensure
      File.delete(playbook) if File.exists?(playbook)
    end
  end
end
