require "json"
require "colorize"
require "../host"

module CrystalPlay
  # ResultDisplay - Handles displaying task results and diffs
  module ResultDisplay
      # Display task result with appropriate formatting.
      # item_label is set for looped tasks, rendering `ok: [host] => (item=x)`
      # to match how Ansible annotates per-iteration output.
      def self.display_result(host : Host, result : JSON::Any, diff_mode : Bool, item_label : String? = nil)
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

        # Show connection host (IP) if different from inventory name
        connection_host = host.vars["ansible_host"]?.try(&.as_s?) || host.name

        suffix = item_label ? " => (item=#{item_label})" : ""
        puts "#{status}: [#{connection_host}]#{suffix}"
        
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
        end
        
        # Display diff if present and diff_mode enabled
        if diff_mode && result["diff"]?
          display_diff(result["diff"])
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
      
      # Update stats based on task result
      def self.update_stats(stats : Hash(String, Int32), result : JSON::Any)
        changed = result["changed"]?.try(&.as_bool) || false
        failed = result["failed"]?.try(&.as_bool) || false
        
        if failed
          stats["failed"] += 1
        elsif changed
          stats["changed"] += 1
        else
          stats["ok"] += 1
        end
      end
      
      # Show recap of all host results
      def self.show_recap(hosts : Array(Host), results : Hash(String, Hash(String, Int32)))
        hosts.each do |host|
          stats = results[host.name]
          
          status_parts = [] of String
          
          # OK count (green)
          status_parts << "ok=#{stats["ok"]}".colorize(:green).to_s
          
          # Changed count (yellow if any)
          if stats["changed"] > 0
            status_parts << "changed=#{stats["changed"]}".colorize(:yellow).to_s
          else
            status_parts << "changed=#{stats["changed"]}".colorize(:green).to_s
          end
          
          # Failed count (red if any)
          if stats["failed"] > 0
            status_parts << "failed=#{stats["failed"]}".colorize(:red).to_s
          else
            status_parts << "failed=#{stats["failed"]}".colorize(:green).to_s
          end
          
          # Skipped count (cyan if any)
          if stats["skipped"]? && stats["skipped"] > 0
            status_parts << "skipped=#{stats["skipped"]}".colorize(:cyan).to_s
          end
          
          puts "#{host.name.ljust(20)} : #{status_parts.join("  ")}"
        end
      end
  end
end
