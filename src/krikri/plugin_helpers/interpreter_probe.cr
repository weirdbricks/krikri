# Pure helpers for TaskExecutor#remote_interpreter_probe: the one-shot
# ssh script that decides whether a host's resolved module interpreter
# exists there, and the parser for its answer.
#
# Real ansible runs every module payload under that interpreter, so a
# path that is absent on the target dies with rc 127 and a non-JSON
# stdout - reported as the module-interpreter-not-found action failure
# (issue #374 for a connection: local task, issue #1646 for the same
# shape over ssh). krikri's own modules are compiled binaries that never
# run python, so the check has to ask the target. The answer also carries
# which shell words the miss: dash says "/bin/sh: 1: X: not found" while
# bash says "/bin/sh: line 1: X: No such file or directory", and real
# prints whichever the target's own /bin/sh produced.
module Krikri
  module PluginHelpers
    module InterpreterProbe
      PRESENT = "krikri-interpreter-present"
      MISSING = "krikri-interpreter-missing"

      # A path (anything with a "/") is checked the way the shell's own
      # exec would see it; a bare name is looked up on PATH, which is
      # where real's `python3`-style pins resolve. The resolved /bin/sh
      # only travels on the MISSING branch - `readlink -f` is coreutils,
      # so a host without it falls back to the unresolved path.
      def self.script(interpreter : String) : String
        if interpreter.includes?('/')
          found = "test -x #{quote(interpreter)}"
        else
          found = "command -v #{quote(interpreter)} >/dev/null 2>&1"
        end
        "if #{found}; then echo #{PRESENT}; else echo #{MISSING}; " \
        "readlink -f /bin/sh 2>/dev/null || readlink /bin/sh 2>/dev/null || echo /bin/sh; fi"
      end

      # {missing, target's /bin/sh is dash}. A transcript without the
      # MISSING marker - a probe that never answered, a truncated read -
      # reports PRESENT, so a broken probe can never invent real's
      # failure.
      def self.parse(stdout : String) : {Bool, Bool}
        lines = stdout.lines.map(&.strip)
        return {false, true} unless lines.first? == MISSING
        {true, (lines[1]?.presence || "/bin/sh").ends_with?("/dash")}
      end

      private def self.quote(value : String) : String
        "'" + value.gsub("'", "'\\''") + "'"
      end
    end
  end
end
