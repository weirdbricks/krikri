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

      # systemd's own bad states, reported as "status" in preference to
      # the ACTIVE column - real Ansible's `SystemctlScanService.
      # BAD_STATES`, checked across every field EXCEPT the trailing
      # description (which can contain any of these words innocently).
      BAD_STATES = {"not-found", "masked", "failed"}

      # `systemctl list-units --type service --all --plain`, real
      # Ansible's `_list_from_units`. Returns {name => {state, status}}.
      # This listing is the one that carries units with NO unit file at
      # all - generated, transient and template-instance units - which
      # is why real Ansible reads it IN ADDITION to list-unit-files
      # rather than using the unit files alone as the key set.
      def self.parse_units(output : String) : Hash(String, NamedTuple(state: String, status: String))
        result = Hash(String, NamedTuple(state: String, status: String)).new
        output.each_line do |line|
          next unless line.includes?(".service")
          fields = line.strip.split(/\s+/)
          next if fields.size < 4

          # Everything but the description column.
          bad = fields[0...-1].find { |field| BAD_STATES.includes?(field) }
          status = bad || fields[2]
          result[fields[0]] = {state: fields[3] == "running" ? "running" : "stopped", status: status}
        end
        result
      end

      # `systemctl list-unit-files --type service --all`, real Ansible's
      # `_list_from_unit_files`: "UNIT_FILE STATE [VENDOR PRESET]".
      # Same as #parse_unit_files but filtered on ".service" the way the
      # real module filters it, so a wrapped/odd line can't contribute a
      # bogus key.
      def self.parse_unit_file_states(output : String) : Hash(String, String)
        result = Hash(String, String).new
        output.each_line do |line|
          next unless line.includes?(".service")
          parts = line.strip.split(/\s+/)
          next if parts.size < 2
          result[parts[0]] = parts[1]
        end
        result
      end

      # `systemctl show a.service b.service --property=Id
      # --property=ActiveState` - blank-line-separated blocks, one per
      # requested unit, in request order. Real Ansible issues one
      # `systemctl show` PER unit; batching is the same data for one
      # subprocess instead of dozens.
      #
      # Keyed by REQUEST POSITION, not by the Id field, because an ALIAS
      # unit reports its TARGET's Id: asking about
      # `dbus-org.freedesktop.login1.service` answers
      # `Id=systemd-logind.service`, so an Id-keyed result loses the
      # alias entirely and reports it "unknown" - which is exactly what
      # a first cut of this did, on all 12 aliases of a stock Debian
      # host. Real Ansible keys by the name it asked about, and so does
      # this.
      #
      # Returns nil if the block count doesn't match the request, which
      # is the caller's signal to fall back to one call per unit: a
      # single un-showable unit makes systemctl fail the WHOLE batch
      # with no output at all (see #showable_units).
      def self.parse_show_active_states(output : String, requested : Array(String)) : Hash(String, String)?
        states = [] of String
        output.split(/\n\s*\n/).each do |block|
          next if block.strip.empty?
          block.each_line do |line|
            key, sep, value = line.strip.partition('=')
            states << value if !sep.empty? && key == "ActiveState"
          end
        end
        return nil unless states.size == requested.size
        Hash.zip(requested, states)
      end

      # Units `systemctl show` cannot be asked about at all: a template
      # unit with an empty instance (`autovt@.service`, `getty@.service`)
      # is "neither a valid invocation ID nor unit name", and ONE of them
      # in an argument list fails the entire call. Real Ansible asks per
      # unit, so it just gets a failed rc for these and leaves their
      # state "unknown" - verified live: `autovt@.service` and
      # `getty@.service` both come back state "unknown" from real
      # ansible-core 2.19. Filtering them keeps the single batched call
      # viable on a normal host, where they are otherwise guaranteed to
      # be present.
      def self.showable_unit?(name : String) : Bool
        !name.includes?("@.")
      end

      # `service --status-all`'s own SysV listing, real Ansible's
      # `ServiceScanService._list_sysvinit` regex
      # (`^\s*\[ (?P<state>\+|\-) \]\s+(?P<name>.+)$`): a "+" means
      # running, a "-" stopped, and anything else on the line (a "?" for
      # a script with no status action, blank lines, warnings) is
      # ignored. Names carry no `.service` suffix here - that's real
      # too, and is what makes a sysv-sourced fact distinguishable from
      # a systemd one by key alone.
      def self.parse_sysv_status_all(output : String) : Hash(String, String)
        result = Hash(String, String).new
        output.each_line do |line|
          next unless match = line.match(/^\s*\[ (\+|-) \]\s+(.+)$/)
          result[match[2].strip] = match[1] == "+" ? "running" : "stopped"
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
