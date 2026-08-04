module CrystalPlay
  module PluginHelpers
    # ProcNetTcp - pure logic for parsing /proc/net/tcp (Linux's own
    # kernel-exposed TCP connection table) and matching active
    # connections the way wait_for's `state: drained` needs to. No I/O -
    # plugins/wait_for.cr reads the actual file and does the polling.
    #
    # IPv4 (`/proc/net/tcp`) only - real Ansible's own wait_for also reads
    # `/proc/net/tcp6`, but IPv6 `host:`/`exclude_hosts:` values are rare
    # in real `drained:` usage (almost always gating on a local service's
    # plain IPv4 default), and the byte-swapped-per-4-byte-word hex
    # encoding IPv6 addresses use there is meaningfully more involved than
    # IPv4's - a documented scope cut, not an oversight.
    module ProcNetTcp
      # Real Ansible's own connection-state name -> the two-hex-digit code
      # /proc/net/tcp itself uses, verified against
      # ansible/modules/wait_for.py's own `get_connection_state_id`
      # function source directly, not guessed from /proc/net/tcp's own
      # sparse kernel documentation.
      STATE_CODES = {
        "ESTABLISHED" => "01",
        "SYN_SENT"    => "02",
        "SYN_RECV"    => "03",
        "FIN_WAIT1"   => "04",
        "FIN_WAIT2"   => "05",
        "TIME_WAIT"   => "06",
      }

      # active_connection_states:'s own default, verified against real
      # Ansible's argument_spec (not every STATE_CODES entry is
      # necessarily in the default set, though in this case all six are).
      DEFAULT_ACTIVE_STATES = %w[ESTABLISHED FIN_WAIT1 FIN_WAIT2 SYN_RECV SYN_SENT TIME_WAIT]

      ANY_ADDRESS = "00000000"

      # Converts a dotted IPv4 address into /proc/net/tcp's own
      # byte-reversed hex form (verified against this machine's own real
      # /proc/net/tcp output, not assumed: "127.0.0.1" -> "0100007F" -
      # the octets appear reversed because the kernel writes the raw
      # 32-bit address in host byte order, little-endian on every
      # platform Linux's own /proc/net/tcp is read on). Returns nil for
      # anything that isn't a plain dotted-quad (hostnames need DNS
      # resolution, not attempted here - see the class doc above).
      def self.ipv4_to_hex(ip : String) : String?
        octets = ip.split('.')
        return nil unless octets.size == 4

        bytes = octets.compact_map(&.to_u8?)
        return nil unless bytes.size == 4

        bytes.reverse.map(&.to_s(16, upcase: true).rjust(2, '0')).join
      end

      def self.port_to_hex(port : Int32) : String
        port.to_s(16, upcase: true).rjust(4, '0')
      end

      record Connection, local_ip : String, local_port : String, remote_ip : String, state : String

      # Parses /proc/net/tcp's own content (header line included) into
      # Connection records - the raw hex fields, not yet matched against
      # anything.
      def self.parse(content : String) : Array(Connection)
        connections = [] of Connection

        content.each_line do |line|
          fields = line.split
          next if fields.size < 4 || fields[1] == "local_address" # header line

          local = fields[1].split(':')
          remote = fields[2].split(':')
          next unless local.size == 2 && remote.size == 2

          connections << Connection.new(local[0], local[1], remote[0], fields[3])
        end

        connections
      end

      # Counts connections matching `state: drained`'s own criteria: an
      # active connection state, the target port, a local address that's
      # either exactly `host_hex` or the "any address" wildcard (a
      # service listening on 0.0.0.0 shows every connection's local
      # address as 0.0.0.0 too, not the specific interface IP - matching
      # real Ansible's own `match_all_ips` handling), and a remote
      # address not in `exclude_hexes`.
      def self.count_active(
        connections : Array(Connection), host_hex : String, port_hex : String,
        active_states : Array(String), exclude_hexes : Array(String),
      ) : Int32
        state_codes = active_states.compact_map { |state| STATE_CODES[state]? }

        connections.count do |conn|
          state_codes.includes?(conn.state) &&
            conn.local_port == port_hex &&
            (conn.local_ip == host_hex || conn.local_ip == ANY_ADDRESS) &&
            !exclude_hexes.includes?(conn.remote_ip)
        end
      end
    end
  end
end
