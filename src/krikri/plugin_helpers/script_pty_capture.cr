# Pure shaping helpers for the remote script module run. Real ansible's
# script action plugin runs the staged script through
# _low_level_execute_command with in_data=nil, which the ssh connection
# plugin turns into `-tt`: the remote side gets a PTY (live-verified
# against ansible-core 2.19.11, issue #298). Two observable consequences
# no plain-pipe capture can reproduce on its own - both simulated here as
# output-shaping on what was actually captured locally on the target:
#
# - With a PTY, sshd gives the remote shell the SAME pty on stdout and
#   stderr, so the script's two streams arrive on ansible's stdout
#   MERGED, in true execution order, with the tty's ONLCR having turned
#   every \n into \r\n (only \n is affected; a script-embedded \r passes
#   through, matching the kernel driver). krikri instead runs the script
#   with `{ ...; } 2>&1` (one pipe, execution order preserved) and
#   re-serializes it with #pty_stdout.
# - With a PTY, openssh's own mux-client close notice
#   ("Shared connection to <addr> closed.\r\n") is the ONLY thing left on
#   the ssh client's stderr - everything remote-side already went onto
#   the pty. krikri synthesizes that exact line via #connection_closed_stderr
#   from the address ansible opened (ansible_host || inventory name),
#   which also keeps it true whatever local transport reuses may do.
module Krikri
  module PluginHelpers
    module ScriptPtyCapture
      # The captured run's output as the pty yields it to the module:
      # ONLCR turns every \n into \r\n. Embedded \r characters pass
      # through untouched, exactly like the pty's output-side
      # translation (it never looks at an already-\r byte).
      def self.pty_stdout(captured : String) : String
        captured.gsub("\n", "\r\n")
      end

      # The one line a `ssh -tt` mux-client session leaves on its own
      # stderr when the session closes (openssh's clientloop.c), which
      # under the pty merge becomes the whole module stderr.
      def self.connection_closed_stderr(addr : String) : String
        "Shared connection to #{addr} closed.\r\n"
      end
    end
  end
end
