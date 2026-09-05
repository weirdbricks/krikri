require "base64"

require "./shell"

module Krikri
  # Wire protocol for task batching (on by default; --no-batching
  # disables it): builds the bash script
  # that runs several plugin invocations in one SSH round trip, and parses
  # the results back out.
  #
  # Both directions use base64 framing, never marker strings mixed into a
  # plugin's own stdout/stderr - a shell/command task's captured output
  # could in principle contain anything, including a string that collides
  # with a hand-picked delimiter. Base64's own alphabet structurally can't
  # produce that collision, so this is immune to it rather than merely
  # unlikely to hit it.
  #
  # The generated script is meant to be piped via a single `ssh ... bash
  # -s` invocation's stdin. Each step's config is embedded in the script
  # itself (also base64) rather than streamed separately over that same
  # stdin - interleaving "script source" and "step data" on one stdin
  # stream is a well-known footgun (bash's own script-reading can read
  # ahead in blocks, not strictly line-by-line, corrupting the boundary
  # between where the script ends and data begins). A single
  # self-contained script sidesteps that entirely.
  #
  # Assumes GNU coreutils `base64` (supports `-w0`, no line wrapping) on
  # the target - consistent with this project's existing assumption of a
  # Debian/RHEL-family Linux target elsewhere (dpkg/rpm detection, etc.).
  module BatchScript
    # `/var/tmp`, not `/tmp` - see PluginManager::REMOTE_PLUGIN_DIR for
    # why (some hardening roles remount `/tmp` as a fresh, empty tmpfs
    # mid-play, which would silently wipe this batch's own per-step
    # output files out from under it).
    REMOTE_DIR_PREFIX = "/var/tmp/.krikri-playbook/batch-"

    # awk program (POSIX awk, run against one step's stdout file) that
    # answers "does this result JSON have a TOP-LEVEL \"failed\": true?"
    # - exits 0 when it does. Tracks JSON string/escape state and brace
    # depth so "failed" keys nested inside result values (uri:'s parsed
    # response body, string-valued fields carrying escaped copies) never
    # trip it. The result is always a single-line compact JSON object,
    # so per-line state resets are harmless.
    TOP_LEVEL_FAILED_AWK = <<-AWK
      {
        line = $0
        depth = 0
        in_str = 0
        prev = ""
        failed = 0
        bs_run = 0
        n = length(line)
        q = sprintf("%c", 34)
        bs = sprintf("%c", 92)
        key = q "failed" q ":"
        for (i = 1; i <= n; i++) {
          c = substr(line, i, 1)
          if (in_str) {
            if (c == bs) {
              bs_run++
            } else {
              # a quote closes the string only when the run of
              # immediately-preceding backslashes is even (an odd run
              # escapes it: "x" ends with an escaped backslash, so the
              # quote is the real terminator)
              if (c == q && bs_run % 2 == 0) in_str = 0
              bs_run = 0
            }
          } else if (depth == 1 && substr(line, i, 9) == key && substr(line, i + 9) ~ /^ *true/) {
            failed = 1
          } else if (c == q) {
            in_str = 1
          } else if (c == "{" || c == "[") {
            depth++
          } else if (c == "}" || c == "]") {
            depth--
          }
          prev = c
        }
        exit (failed ? 0 : 1)
      }
      AWK

    # One step to run remotely as part of a batch.
    struct Step
      # Already resolved via PluginManager.remote_plugin_target - the
      # bare plugin path, or `sudo -n -u <user> -- <path>` if become:.
      # Used only by the bash-script transport below; the daemon
      # transport (perf item 3) dispatches
      # by module NAME inside an already-running process instead, and
      # gets its privilege from which daemon it is sent to.
      getter plugin_target : String
      # This step's full config, exactly what would be piped via stdin
      # in the non-batched path (PluginManager#execute_remote_plugin).
      getter config_json : String
      getter? ignore_errors : Bool
      # Simple (non-FQCN) module name, for the daemon transport's own
      # dispatch table.
      getter module_name : String
      # The become_user this step must run as, or nil for none. This is
      # the daemon KEY: a daemon is one resident process running as one
      # fixed user, so only steps agreeing on this value can share one
      # daemon batch request - see TaskExecutor#run_batch_steps.
      getter become_user : String?

      def initialize(@plugin_target : String, @config_json : String, @ignore_errors : Bool,
                     @module_name : String = "", @become_user : String? = nil)
      end
    end

    struct StepResult
      getter exit_code : Int32
      getter stdout : String
      getter stderr : String

      def initialize(@exit_code : Int32, @stdout : String, @stderr : String)
      end
    end

    # Builds the full script for one batch. *batch_id* should be unique
    # per invocation (avoids any risk of colliding with a leftover
    # directory from an earlier batch against the same host).
    def self.build(batch_id : String, steps : Array(Step)) : String
      dir = "#{REMOTE_DIR_PREFIX}#{batch_id}"
      s = String.build do |io|
        io << "#!/bin/bash\n"
        io << "set -u\n"
        io << "D=" << dir << "\n"
        io << "mkdir -p \"$D\"\n"
        io << dump_function << "\n"

        steps.each_with_index do |step, idx|
          encoded = Base64.strict_encode(step.config_json)
          io << "echo " << shell_single_quote(encoded) << " | base64 -d | " << step.plugin_target
          io << " > \"$D/#{idx}.out\" 2> \"$D/#{idx}.err\"\n"
          io << "echo $? > \"$D/#{idx}.rc\"\n"

          unless step.ignore_errors?
            io << "rc=$(cat \"$D/#{idx}.rc\")\n"
            # Failed-detection: a depth-aware awk scan, not a naive grep.
            # The old `grep -q '"failed":true'` matched the byte sequence
            # ANYWHERE in the step's stdout - but a plugin's result JSON
            # can legitimately CONTAIN that sequence without having
            # failed: uri: embeds a parsed JSON response body at
            # result.json (an API answering {"failed": true} with a 200
            # is the canonical case), and any string-valued field can
            # carry escaped copies. The awk tracks JSON string/escape
            # state and brace depth and only trips on the TOP-LEVEL
            # "failed" key - the same question the daemon transport's
            # JSON parse answers, so both transports now agree on what
            # "failed" means.
            io << "if [ \"$rc\" != \"0\" ] || awk '"
            io << TOP_LEVEL_FAILED_AWK
            io << "' \"$D/#{idx}.out\" 2>/dev/null; then\n"
            io << "  dump\n"
            io << "  exit 0\n"
            io << "fi\n"
          end
        end

        io << "dump\n"
      end
      s
    end

    private def self.dump_function : String
      <<-BASH
      dump() {
        for f in "$D"/*.rc; do
          [ -e "$f" ] || continue
          n=$(basename "$f" .rc)
          rc=$(cat "$f")
          printf 'OUT %s %s ' "$n" "$rc"
          base64 -w0 "$D/$n.out"
          printf '\\n'
          printf 'ERR %s ' "$n"
          base64 -w0 "$D/$n.err"
          printf '\\n'
        done
        rm -rf "$D"
      }
      BASH
    end

    # Single-quotes *str* for shell embedding - shared implementation in
    # ./shell.cr (was its own copy, drift risk for a security-relevant
    # primitive).
    private def self.shell_single_quote(str : String) : String
      Shell.single_quote(str)
    end

    # Parses a batch script's stdout (as captured from the single SSH
    # invocation that ran it) back into per-step results, keyed by the
    # step's original index. A step whose index is missing never ran (the
    # script halted before reaching it, or the whole batch never started)
    # - callers must not treat a missing entry as an error on its own.
    def self.parse(raw_stdout : String) : Hash(Int32, StepResult)
      outs = {} of Int32 => {Int32, String}
      errs = {} of Int32 => String

      raw_stdout.each_line do |line|
        if m = line.match(/\AOUT (\d+) (-?\d+) (.*)\z/)
          outs[m[1].to_i] = {m[2].to_i, Base64.decode_string(m[3])}
        elsif m = line.match(/\AERR (\d+) (.*)\z/)
          errs[m[1].to_i] = Base64.decode_string(m[2])
        end
      end

      results = {} of Int32 => StepResult
      outs.each do |step_index, (rc, stdout)|
        results[step_index] = StepResult.new(rc, stdout, errs[step_index]? || "")
      end
      results
    end
  end
end
