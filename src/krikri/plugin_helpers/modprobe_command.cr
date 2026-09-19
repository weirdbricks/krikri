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
      # the module isn't already loaded. Real modprobe.py also resolves
      # the binary once via get_bin_path and invokes THAT path
      # (self.modprobe_bin), so the resolved path is passed in rather
      # than a bare "modprobe" hoping for $PATH lookup.
      def self.load_command(bin_path : String, name : String, params : String?) : String
        # One quoted shell word per token: real modprobe.py shlex-splits
        # `params:` into separate argv elements, so each token gets its
        # own quoting (Process.quote leaves safe tokens verbatim).
        params_tokens = params && !params.empty? ? params.split(' ').reject(&.empty?).map { |token| Process.quote(token) }.join(" ") : ""
        params_tokens.empty? ? "#{bin_path} #{Process.quote(name)}" : "#{bin_path} #{Process.quote(name)} #{params_tokens}"
      end

      # Parses the ModprobePlugin binary-resolution probe's output
      # (`searched=`/`found=` lines): the resolved modprobe path (nil
      # when the binary is missing - the caller must then fail with
      # real Ansible's get_bin_path(required=True) message BEFORE any
      # state check, not report "already unloaded" success) and the
      # colon-joined list of directories actually searched, for that
      # message's "in paths: ..." tail.
      def self.parse_bin_probe(stdout : String) : NamedTuple(path: String?, searched_paths: String)
        path = nil
        searched = ""
        stdout.each_line do |line|
          key, _, value = line.strip.partition('=')
          path = value.empty? ? nil : value if key == "found"
          searched = value if key == "searched"
        end
        {path: path, searched_paths: searched}
      end
    end
  end
end
