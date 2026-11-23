require "../minitest_helper"
require "../../src/krikri/ssh_manager"

# Issue #1705: exec_script writes the plugin script to ssh's own stdin, and
# a dead endpoint's ssh exits before reading it. The resulting EPIPE used to
# replace ssh's own stderr with "SSH execution failed: write ... Broken
# pipe", intermittently depending on which side won the race - which is what
# made the #1687/#1704 corpus replays and ssh_255_unreachable_test's
# plain-task spec flaky under full-suite load.
describe "Krikri::SSHManager.exec_script (ssh_script_stdin_race_test.cr)" do
  it "keeps ssh's own stderr when the endpoint exits before reading the script" do
    dir = PluginSpecHelper.tmp_path("ssh-stdin-race-#{Random::Secure.hex(4)}")
    FileUtils.mkdir_p(dir)
    stub = File.join(dir, "dead-endpoint")
    File.write(stub, "#!/bin/sh\n" \
                     "echo \"Connection to 192.0.2.1 closed by remote host.\" >&2\n" \
                     "exit 255\n")
    File.chmod(stub, 0o755)

    # Larger than a pipe buffer, so the write cannot complete before the
    # dead endpoint has exited: without the guard this is a guaranteed EPIPE
    # rather than a scheduling race.
    script = "x" * (1 << 20)
    result = Krikri::SSHManager.exec_script(
      "192.0.2.1", "root", script,
      timeout: 10, ssh_executable: stub
    )

    result[:exit_code].must_equal(255)
    result[:stderr].must_equal("Connection to 192.0.2.1 closed by remote host.\n")
  end
end
