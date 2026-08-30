module Krikri
  module PluginHelpers
    # ModprobeCommand - pure logic for building the `modprobe` load
    # command line. No I/O here - the plugin itself runs the resulting
    # command.
    module ModprobeCommand
      # `params:` (real community.general modprobe.py's own extra
      # modprobe arguments, e.g. "numdummies=2") is appended verbatim
      # after the module name, matching `modprobe <name> <params>` -
      # verified against the real module's source: `command.extend([
      # self.name] + shlex.split(self.params))`, only ever called when
      # the module isn't already loaded.
      def self.load_command(name : String, params : String?) : String
        params && !params.empty? ? "modprobe #{name} #{params}" : "modprobe #{name}"
      end
    end
  end
end
