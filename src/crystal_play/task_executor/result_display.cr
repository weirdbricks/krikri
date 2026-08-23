require "json"
require "colorize"
require "../host"

module CrystalPlay
  # ResultDisplay - Handles displaying task results and diffs
  module ResultDisplay
    # Display task result with appropriate formatting.
    # item_label is set for looped tasks, rendering `ok: [host] => (item=x)`
    # to match how Ansible annotates per-iteration output.
    def self.display_result(host : Host, result : JSON::Any, diff_mode : Bool, item_label : String? = nil, ignore_errors : Bool = false)
      changed = result["changed"]?.try(&.as_bool) || false
      failed = result["failed"]?.try(&.as_bool) || false
      msg = result["msg"]?.try(&.as_s) || ""

      # Status indicator
      status = if failed
                 "failed".colorize(:red).bold
               elsif changed
                 "changed".colorize(:yellow)
               else
                 "ok".colorize(:green)
               end

      suffix = item_label ? " => (item=#{item_label})" : ""
      puts "#{status}: [#{host.connection_host}]#{suffix}"

      # Show message for successful tasks if msg is present and meaningful
      # This allows debug plugin output to be visible
      if !failed && msg && !msg.empty? && !["ok", "Command executed successfully", "File already exists with identical content"].includes?(msg)
        # Format multi-line messages nicely
        if msg.includes?("\n")
          puts msg.split("\n").map { |line| "  #{line}" }.join("\n")
        else
          puts "  #{msg}".colorize(:white)
        end
      end

      # If failed, show additional error details
      if failed
        # Show error message
        if msg && !msg.empty?
          puts "  Message: #{msg}".colorize(:red)
        end

        # Show stderr if available
        if stderr = result["stderr"]?.try(&.as_s)
          if !stderr.empty?
            puts "  Error output:".colorize(:red)
            stderr.lines.each do |line|
              puts "    #{line}".colorize(:red)
            end
          end
        end

        # Show stdout if available (might have partial output)
        if stdout = result["stdout"]?.try(&.as_s)
          if !stdout.empty?
            puts "  Output:".colorize(:yellow)
            stdout.lines.each do |line|
              puts "    #{line}".colorize(:yellow)
            end
          end
        end

        # Show exit code if available
        if rc = result["rc"]?.try(&.as_i)
          puts "  Exit code: #{rc}".colorize(:red)
        end

        # Real ansible-playbook always prints a bare "...ignoring" line
        # right after a failed task's own output when ignore_errors:
        # caught it - verified directly against a real ansible-playbook
        # run. This was previously never printed at all for a normal
        # ignored failure (only added, narrowly, for the when:-raises-
        # an-exception case - see WhenEvaluationError's own history);
        # fixed here so every ignored failure gets it, matching real
        # Ansible regardless of why the task failed.
        puts "...ignoring".colorize(:red) if ignore_errors
      end

      # Display diff if present and diff_mode enabled
      if diff_mode && result["diff"]?
        display_diff(result["diff"])
      end
    end

    # Display an ad-hoc `ansible` command's result, matching real
    # ansible's own default ("minimal") callback: `host | STATUS | rc=N >>`
    # followed by raw stdout for command-shaped modules (rc + stdout
    # present - command/shell/script/raw), or `host | STATUS => {...}`
    # pretty-printed JSON for every other module. Deliberately NOT
    # ResultDisplay.display_result - that one renders ansible-playbook's
    # own "ok: [host]" TASK-recap style, a different output convention
    # ansible's ad-hoc CLI has never used.
    def self.display_adhoc_result(host : Host, result : JSON::Any)
      changed = result["changed"]?.try(&.as_bool) || false
      failed = result["failed"]?.try(&.as_bool) || false
      unreachable = result["unreachable"]?.try(&.as_bool) || false

      status = if unreachable
                 "UNREACHABLE!".colorize(:red).bold
               elsif failed
                 "FAILED!".colorize(:red).bold
               elsif changed
                 "CHANGED".colorize(:yellow)
               else
                 "SUCCESS".colorize(:green)
               end

      connection_host = host.vars["ansible_host"]?.try(&.as_s?) || host.name

      rc = result["rc"]?.try(&.as_i?)
      stdout = result["stdout"]?.try(&.as_s?)
      if rc && stdout
        puts "#{connection_host} | #{status} | rc=#{rc} >>"
        puts stdout
        if (stderr = result["stderr"]?.try(&.as_s?)) && !stderr.empty?
          puts stderr.colorize(:red)
        end
      else
        puts "#{connection_host} | #{status} => #{result.to_pretty_json}"
      end
    end

    # Display diff (delegates to specific diff types)
    def self.display_diff(diff : JSON::Any)
      puts ""

      # Content diff (copy, template)
      if diff["before"]? && diff["after"]? && diff["before"].as_s? && diff["after"].as_s?
        display_content_diff(diff)
        # Attribute diff (file)
      elsif diff["before"]?.try(&.as_h?) && diff["after"]?.try(&.as_h?)
        display_attribute_diff(diff)
      end
    end

    # Display content diff (for file content changes)
    def self.display_content_diff(diff : JSON::Any)
      before = diff["before"].as_s
      after = diff["after"].as_s
      before_header = diff["before_header"]?.try(&.as_s) || "before"
      after_header = diff["after_header"]?.try(&.as_s) || "after"

      puts "--- #{before_header}".colorize(:red).bold
      puts "+++ #{after_header}".colorize(:green).bold

      show_unified_diff(before, after)
      puts ""
    end

    # Display attribute diff (for file attributes like mode, owner)
    def self.display_attribute_diff(diff : JSON::Any)
      before = diff["before"].as_h
      after = diff["after"].as_h

      puts "--- before".colorize(:red).bold
      puts "+++ after".colorize(:green).bold

      # Show changes
      all_keys = (before.keys + after.keys).uniq.sort
      all_keys.each do |key|
        before_val = before[key]?
        after_val = after[key]?

        if before_val && after_val && before_val.to_s != after_val.to_s
          puts "-  #{key}: \"#{before_val}\"".colorize(:red)
          puts "+  #{key}: \"#{after_val}\"".colorize(:green)
        elsif before_val && !after_val
          puts "-  #{key}: \"#{before_val}\"".colorize(:red)
        elsif after_val && !before_val
          puts "+  #{key}: \"#{after_val}\"".colorize(:green)
        end
      end
      puts ""
    end

    # Show unified diff using system diff command
    def self.show_unified_diff(before : String, after : String)
      # Create temp files for diff
      before_file = "/tmp/crystal-play-before-#{Random::Secure.hex(4)}"
      after_file = "/tmp/crystal-play-after-#{Random::Secure.hex(4)}"

      File.write(before_file, before)
      File.write(after_file, after)

      # Run diff command
      diff_output = `diff -u #{before_file} #{after_file} 2>/dev/null`

      # Cleanup
      File.delete(before_file) if File.exists?(before_file)
      File.delete(after_file) if File.exists?(after_file)

      # Skip first two lines (--- and +++ headers, we show our own)
      lines = diff_output.lines
      return if lines.size < 3

      # Colorize and display
      lines[2..-1].each do |line|
        colored = case line[0]?
                  when '-'
                    line.colorize(:red)
                  when '+'
                    line.colorize(:green)
                  when '@'
                    line.colorize(:cyan).bold
                  else
                    line
                  end
        puts colored
      end
    end

    # Update stats based on task result. A failure with ignore_errors: yes
    # still displays as failed (see display_result) but doesn't count
    # toward the host's failure tally - matching Ansible, where an
    # ignored failure doesn't fail the play or the process exit code.
    def self.update_stats(stats : Hash(String, Int32), result : JSON::Any, ignore_errors : Bool = false)
      changed = result["changed"]?.try(&.as_bool) || false
      failed = result["failed"]?.try(&.as_bool) || false

      if failed && !ignore_errors
        stats["failed"] += 1
      else
        # Real Ansible's own recap counters overlap, not mutually
        # exclusive: "ok" counts every successful task (changed or not),
        # and "changed" is a separate tally on top of that - verified
        # against a real ansible-playbook run (ok=3, changed=2 for 2
        # changed + 1 unchanged successful tasks), not assumed.
        stats["ok"] += 1
        stats["changed"] += 1 if changed

        # A task that failed but was caught by ignore_errors: still
        # increments "ok" (and "changed") above - real Ansible's own
        # strategy/__init__.py does the exact same `increment('ok', ...)`
        # + `increment('ignored', ...)` pair for this case (verified
        # against its source, not assumed) - but it ALSO increments a
        # separate "ignored" counter alongside, which this recap had no
        # key for at all until now.
        stats["ignored"] += 1 if failed && ignore_errors
      end
    end

    # Show recap of all host results
    def self.show_recap(hosts : Array(Host), results : Hash(String, Hash(String, Int32)))
      hosts.each do |host|
        # A host can reach the recap with no results at all: crystal-play.cr
        # adds every play's hosts to the recap list *before* deciding
        # whether the play has any tasks to run, so a playbook whose plays
        # are all skipped (no tasks, or none matching --tags) used to crash
        # here with `Missing hash key`. Zeroes are the honest recap for a
        # host nothing ran on, and match what real ansible-playbook prints.
        stats = results[host.name]? || {
          "ok" => 0, "changed" => 0, "unreachable" => 0, "failed" => 0, "skipped" => 0, "rescued" => 0, "ignored" => 0,
        }

        status_parts = [] of String

        # Real ansible-playbook's own recap ALWAYS prints all 7 counters,
        # in this exact order, even when a given counter is 0 - never
        # conditionally omitted. Verified directly against a real
        # ansible-playbook run: `ok=44   changed=6    unreachable=0
        # failed=0    skipped=5    rescued=0    ignored=0`. This recap
        # used to omit `skipped=`/`rescued=`/`ignored=` entirely whenever
        # they were 0, and never printed `unreachable=` at all (no key
        # for it existed in the stats hash) - a purely cosmetic
        # difference (the underlying pass/fail/skip behavior always
        # matched), but one that made an otherwise byte-identical recap
        # diff from real Ansible on every single run. Found repeatedly
        # across benchmark rounds (buluma.openssl, geerlingguy.helm,
        # robertdebock.types) and never fixed in one place before.

        # OK count (green)
        status_parts << "ok=#{stats["ok"]}".colorize(:green).to_s

        # Changed count (yellow if any)
        if stats["changed"] > 0
          status_parts << "changed=#{stats["changed"]}".colorize(:yellow).to_s
        else
          status_parts << "changed=#{stats["changed"]}".colorize(:green).to_s
        end

        # Unreachable count (red if any) - always printed; this engine
        # doesn't yet distinguish a genuinely unreachable host from an
        # ordinary task failure (see KNOWN_MISSING.md), so this is
        # currently always 0, matching what's actually true today.
        unreachable = stats["unreachable"]? || 0
        if unreachable > 0
          status_parts << "unreachable=#{unreachable}".colorize(:red).to_s
        else
          status_parts << "unreachable=#{unreachable}".colorize(:green).to_s
        end

        # Failed count (red if any)
        if stats["failed"] > 0
          status_parts << "failed=#{stats["failed"]}".colorize(:red).to_s
        else
          status_parts << "failed=#{stats["failed"]}".colorize(:green).to_s
        end

        # Skipped count (cyan if any, green at 0 - always printed)
        skipped = stats["skipped"]? || 0
        if skipped > 0
          status_parts << "skipped=#{skipped}".colorize(:cyan).to_s
        else
          status_parts << "skipped=#{skipped}".colorize(:green).to_s
        end

        # Rescued count (yellow if any, green at 0 - always printed) -
        # block: failures recovered by rescue:
        rescued = stats["rescued"]? || 0
        if rescued > 0
          status_parts << "rescued=#{rescued}".colorize(:yellow).to_s
        else
          status_parts << "rescued=#{rescued}".colorize(:green).to_s
        end

        # Ignored count (yellow if any, green at 0 - always printed) -
        # tasks that failed but were caught by ignore_errors:, matching
        # real ansible-playbook's own ignored=N field (see #update_stats
        # for the increment logic).
        ignored = stats["ignored"]? || 0
        if ignored > 0
          status_parts << "ignored=#{ignored}".colorize(:yellow).to_s
        else
          status_parts << "ignored=#{ignored}".colorize(:green).to_s
        end

        puts "#{host.name.ljust(20)} : #{status_parts.join("  ")}"
      end
    end
  end
end
