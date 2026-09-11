module Krikri
  module PluginHelpers
    # KernelBlacklistFile - pure line-editing logic for
    # community.general.kernel_blacklist (see plugins/kernel_blacklist.cr):
    # given the blacklist file's existing lines, computes what the file
    # should look like for the requested state. Pure functions so the
    # real module's match semantics are unit-testable without a
    # modprobe.d directory to write to.
    #
    # The real module (Blacklist in kernel_blacklist.py) matches with
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
      # and whether anything changed - including the real module's
      # quirk that creating a previously-missing file counts as a
      # change on its own (state=absent against a missing file still
      # reports changed=true in real Ansible, because the file got
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
    end
  end
end
