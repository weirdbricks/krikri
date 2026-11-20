require "json"

module Krikri
  module PluginHelpers
    # KernelBlacklistFile - pure line-editing logic for
    # community.general.kernel_blacklist (see plugins/kernel_blacklist.cr):
    # given the blacklist file's existing lines, computes what the file
    # should look like for the requested state. Pure functions so the
    # Ansible module's match semantics are unit-testable without a
    # modprobe.d directory to write to.
    #
    # The Ansible module (Blacklist in kernel_blacklist.py) matches with
    # `^blacklist\s+<re.escape(name)>$` against each line STRIPPED,
    # skipping lines whose stripped form starts with "#", and rewrites
    # the file as one entry per line (each newline-terminated).
    module KernelBlacklistFile
      def self.pattern(module_name : String) : Regex
        /^blacklist\s+#{Regex.escape(module_name)}$/
      end

      # Whether the module is blacklisted: any non-comment line whose
      # stripped form matches the pattern exactly.
      def self.blacklisted?(lines : Array(String), module_name : String) : Bool
        regex = pattern(module_name)
        lines.any? do |line|
          stripped = line.strip
          next false if stripped.empty? || stripped.starts_with?('#')
          regex.matches?(stripped)
        end
      end

      # Applies state to *lines*. Returns the (possibly new) line list
      # and whether anything changed - including the Ansible module's
      # quirk that creating a previously-missing file counts as a
      # change on its own (state=absent against a missing file still
      # reports changed=true in Ansible, because the file got
      # created).
      def self.apply(lines : Array(String)?, module_name : String, state : String) : {Array(String), Bool}
        file_created = lines.nil?
        current = lines || [] of String

        new_lines = current
        changed = file_created

        case state
        when "present"
          unless blacklisted?(current, module_name)
            new_lines = current + ["blacklist #{module_name}"]
            changed = true
          end
        when "absent"
          if blacklisted?(current, module_name)
            regex = pattern(module_name)
            new_lines = current.reject do |line|
              stripped = line.strip
              next false if stripped.starts_with?('#')
              regex.matches?(stripped)
            end
            changed = true
          end
        end

        {new_lines, changed}
      end

      # The module's --diff payload: module_helper's VarDict diff over the
      # variables flagged diff=True, of which this module has exactly one
      # (`lines`, the file content as read from disk and what the state
      # left it as). An unchanged `lines` still reports an EMPTY dict
      # rather than no diff at all (real 2.21.6 registers "diff": {} on an
      # unchanged rerun under --diff), while a run without --diff emits no
      # diff key whatsoever.
      def self.diff_payload(initial_lines : Array(String), final_lines : Array(String),
                            diff_mode : Bool) : JSON::Any?
        return nil unless diff_mode
        return JSON::Any.new({} of String => JSON::Any) if initial_lines == final_lines

        JSON::Any.new({
          "before" => lines_json(initial_lines),
          "after"  => lines_json(final_lines),
        })
      end

      private def self.lines_json(lines : Array(String)) : JSON::Any
        JSON::Any.new({"lines" => JSON::Any.new(lines.map { |line| JSON::Any.new(line) })})
      end
    end
  end
end
