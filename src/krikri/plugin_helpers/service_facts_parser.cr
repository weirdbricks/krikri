module Krikri
  module PluginHelpers
    # ServiceFactsParser - pure text-parsing logic for the service_facts
    # plugin, factored out so it can be unit tested without a real
    # systemd host.
    module ServiceFactsParser
      # "UNIT_FILE STATE [VENDOR PRESET]" per line, e.g.
      # "sshd.service enabled enabled".
      def self.parse_unit_files(output : String) : Hash(String, String)
        result = Hash(String, String).new
        output.each_line do |line|
          parts = line.strip.split(/\s+/)
          next if parts.size < 2
          result[parts[0]] = parts[1]
        end
        result
      end

      # "UNIT LOAD ACTIVE SUB DESCRIPTION" per line, e.g.
      # "sshd.service loaded active running OpenSSH server". Real
      # `systemctl list-units` output indents every row with leading
      # whitespace even under `--no-legend` - splitting on /\s+/
      # WITHOUT stripping first produces a leading empty-string
      # element, shifting every field one column early (the service
      # name landed under the "" key, and the SUB column check
      # compared against ACTIVE instead). Found benchmarking
      # linux-system-roles.network (round 160): `state` came back
      # "stopped" for every service regardless of its real state,
      # including a genuinely-running NetworkManager.service - the
      # role's own provider autodetection depends on this and always
      # fell back to the wrong ('initscripts') provider as a result.
      def self.parse_active_states(output : String) : Hash(String, String)
        result = Hash(String, String).new
        output.each_line do |line|
          parts = line.strip.split(/\s+/)
          next if parts.size < 4
          result[parts[0]] = parts[3] == "running" ? "running" : "stopped"
        end
        result
      end
    end
  end
end
