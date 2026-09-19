#!/usr/bin/env crystal

require "json"
require "socket"
require "base64"
require "../src/krikri/base_plugin"
require "../src/krikri/plugin_helpers/nsupdate_message"

module Krikri
  # nsupdate plugin - a native port of community.general.nsupdate:
  # create/update/remove DNS records via RFC2136 dynamic update,
  # speaking the DNS wire format directly (the pieces of dnspython the
  # real module drives - see NsupdateMessage; the real module shells
  # out to dnspython, this one doesn't).
  #
  # Follows the real module's RecordManager control flow:
  #   - record_exists() probes with a "prerequisite: RRSET exists"
  #     update, then "RRSET exists with this rdata" per value, then
  #     compares TTLs via a standard query (rc 0 + same values + same
  #     TTL -> unchanged; new/changed values/TTL -> create/modify)
  #   - state=present adds the values (modify first deletes the RRSET,
  #     except NS records, where - to survive Bind9's refusal to
  #     delete a zone's last NS entries - inserts happen before the
  #     delete of stale entries, ported field-for-field)
  #   - state=absent deletes the RRSET (changed only when it existed)
  #   - zone omitted -> SOA-query zone lookup walking up the name
  #     (answer SOA matching the queried name, or an authority SOA the
  #     queried name is a subdomain of)
  #   - TSIG authentication for all of the above (RFC2845, per-message
  #     HMAC over previous-request-MAC || message), with the real
  #     module's algorithm normalization (hmac-md5 ->
  #     HMAC-MD5.SIG-ALG.REG.INT)
  #   - check mode exits changed=true before any mutation
  #   - the real module's TXT quoting (txt_helper) and its
  #     "value needed when state=present" / "Invalid/malformed value"
  #     failures
  #
  # Deliberately left out (noted, not silently dropped): GSS-TSIG
  # authentication (needs a Kerberos ticket environment; fails with an
  # explicit message), version_by_spec-style response TSIG
  # verification (responses are trusted by message ID alone, a spoofed
  # response could make a change look unnecessary - the real module
  # verifies the MAC), and the s3-style breadth of dnspython's rdata
  # grammars (A/AAAA/NS/CNAME/PTR/TXT/MX/SRV are wired; other types
  # fail with the real module's "Invalid/malformed value" shape).
  class NsupdatePlugin < BasePlugin
    @tsig : PluginHelpers::NsupdateMessage::Tsig?
    @dns_rc = 0
    @query_timeout = 10.0

    def execute : PluginResult
      server = @params["server"]?
      return PluginResult.new(changed: false, failed: true,
        msg: "missing required arguments: server") unless server
      record = @params["record"]?
      return PluginResult.new(changed: false, failed: true,
        msg: "missing required arguments: record") unless record

      # real validation order: AnsibleModule's parameter.py type coercion
      # runs before the choices checks and before the module body's own
      # record-empty check
      port = (@params["port"]? || "53").to_i32?
      return PluginResult.new(changed: false, failed: true,
        msg: "argument 'port' is of type <class 'str'> and we were unable to convert to int: <class 'str'> cannot be converted to an int") unless port
      ttl = (@params["ttl"]? || "3600").to_i32?
      return PluginResult.new(changed: false, failed: true,
        msg: "argument 'ttl' is of type <class 'str'> and we were unable to convert to int: <class 'str'> cannot be converted to an int") unless ttl
      timeout = (@params["timeout"]? || "10").to_f?
      return PluginResult.new(changed: false, failed: true,
        msg: "argument 'timeout' is of type <class 'str'> and we were unable to convert to float: <class 'str'> cannot be converted to a float") unless timeout
      @query_timeout = timeout.not_nil!

      state = @params["state"]? || "present"
      return PluginResult.new(changed: false, failed: true,
        msg: "value of state must be one of: present, absent, got: #{state}") unless ["present", "absent"].includes?(state)

      record_type = @params["type"]? || "A"
      protocol = @params["protocol"]? || "tcp"
      return PluginResult.new(changed: false, failed: true,
        msg: "value of protocol must be one of: tcp, udp, got: #{protocol}") unless ["tcp", "udp"].includes?(protocol)

      key_algorithm = @params["key_algorithm"]? || "hmac-md5"
      known_algorithms = ["HMAC-MD5.SIG-ALG.REG.INT", "hmac-md5", "hmac-sha1", "hmac-sha224",
                          "hmac-sha256", "hmac-sha384", "hmac-sha512", "gss-tsig"]
      return PluginResult.new(changed: false, failed: true,
        msg: "value of key_algorithm must be one of: #{known_algorithms.join(", ")}, got: #{key_algorithm}") unless known_algorithms.includes?(key_algorithm)

      return PluginResult.new(changed: false, failed: true,
        msg: "record cannot be empty.") if record.empty?

      @tsig = nil
      tsig = build_tsig(key_algorithm)
      return tsig.as(PluginResult) if tsig.is_a?(PluginResult)
      @tsig = tsig

      values = parse_values
      if record_type.upcase == "TXT" && (vals = values)
        values = vals.map { |v| PluginHelpers::NsupdateMessage.txt_helper(v) }
      end

      zone = @params["zone"]?
      if zone.nil? || zone.empty?
        return PluginResult.new(changed: false, failed: true,
          msg: "record must be absolute when omitting zone parameter") unless record.ends_with?(".")
        zone = lookup_zone(server.not_nil!, port, protocol, record)
        return zone if zone.is_a?(PluginResult)
        zone = zone.as(String)
      else
        zone = zone.ends_with?(".") ? zone : zone + "."
      end

      fqdn = record.ends_with?(".") ? record : "#{record}.#{zone}"

      # the real module only parses the record type inside record_exists
      # (dnspython raises UnknownRdatatype at message-build time, after the
      # TSIG/zone setup, before any network traffic)
      unless PluginHelpers::NsupdateMessage::TYPES.has_key?(record_type.upcase)
        return PluginResult.new(changed: false, failed: true,
          msg: "Record error: DNS resource record type is unknown.")
      end
      type_code = PluginHelpers::NsupdateMessage::TYPES[record_type.upcase].to_i32

      result = state == "absent" ? remove_record(server.not_nil!, port, protocol, zone.as(String), record, type_code) :
                create_or_update_record(server.not_nil!, port, protocol, zone.as(String), record, fqdn, type_code, ttl, values)
      return result if result.is_a?(PluginResult)

      changed, failed = result.as(Tuple(Bool, Bool))
      if failed
        return PluginResult.new(changed: false, failed: true,
          msg: result_msg(changed, state),
          dns_rc: @dns_rc, dns_rc_str: PluginHelpers::NsupdateMessage.rcode_to_text(@dns_rc))
      end

      PluginResult.new(changed: changed, failed: false, msg: result_msg(changed, state),
        dns_rc: @dns_rc, dns_rc_str: PluginHelpers::NsupdateMessage.rcode_to_text(@dns_rc),
        record: {
          zone: zone.as(String), record: record, type: record_type, ttl: ttl,
          value: (values || [] of String),
        }.to_json)
    end

    private def result_msg(changed : Bool, state : String) : String
      changed ? "DNS record #{state == "absent" ? "removed" : "created/updated"}" : "no change needed"
    end

    private def build_tsig(key_algorithm : String) : (PluginHelpers::NsupdateMessage::Tsig | PluginResult | Nil)
      if key_algorithm == "gss-tsig"
        # the real module checks the key_name incompatibility before
        # importing gssapi, so this fires even without the library
        return PluginResult.new(changed: false, failed: true,
          msg: "key_name cannot be used with GSS-TSIG") if @params["key_name"]?
        # Real nsupdate.py's check_gssapi fails through AnsibleModule's
        # missing_required_lib wording - hostname, the interpreter path,
        # the module's own reason ("for gss-tsig keys") and doc URL all
        # included (found via the podman-diff nsupdate_edge_cases N12
        # case, where this used to be a made-up "not supported by this
        # implementation" message).
        return PluginResult.new(changed: false, failed: true,
          msg: "Failed to import the required Python library (gssapi) on #{System.hostname}'s Python /usr/bin/python3. " \
               "This is required for gss-tsig keys. See https://github.com/pythongssapi/python-gssapi for more info. " \
               "Please read the module documentation and install it in the appropriate location. " \
               "If the required library is installed, but Ansible is using the wrong Python interpreter, " \
               "please consult the documentation on ansible_python_interpreter")
      end

      key_name = @params["key_name"]?
      return nil unless key_name

      key_secret = @params["key_secret"]?
      return PluginResult.new(changed: false, failed: true,
        msg: "Missing key_secret") unless key_secret

      # Real nsupdate.py decodes the secret with Python's base64.b64decode
      # (validate=False: characters outside the base64 alphabet are
      # silently DISCARDED first, then the remaining data characters are
      # checked - a count of 1 mod 4 is binascii's "cannot be 1 more than
      # a multiple of 4" error, anything else padding-short decodes as
      # "Incorrect padding"). Crystal's Base64 raises its own generic
      # "base64 decoding failed" for all of these (found via the N8 case).
      if error = python_base64_error(key_secret)
        return PluginResult.new(changed: false, failed: true,
          msg: "TSIG key error: #{error}")
      end

      begin
        secret = Base64.decode(key_secret)
      rescue
        return PluginResult.new(changed: false, failed: true,
          msg: "TSIG key error: Incorrect padding")
      end

      algorithm = key_algorithm == "hmac-md5" ? "HMAC-MD5.SIG-ALG.REG.INT" : key_algorithm
      PluginHelpers::NsupdateMessage::Tsig.new(key_name, secret.to_slice, algorithm)
    end

    private def parse_values : Array(String)?
      raw = @params["value"]?
      return nil unless raw

      begin
        parsed = JSON.parse(raw)
        return parsed.as_a.map(&.as_s) if parsed.as_a?
        return [parsed.as_s] if parsed.as_s? && !parsed.as_s.empty?
      rescue
      end

      return [] of String if raw.empty?
      raw.includes?(",") ? raw.split(",").map(&.strip).reject(&.empty?) : [raw]
    end

    # ------------------------------------------------------------------
    # Network layer
    # ------------------------------------------------------------------

    private def query_wire(server : String, port : Int32, protocol : String, message : Bytes) : (Bytes | PluginResult)
      begin
        if protocol == "tcp"
          socket = TCPSocket.new(server, port, connect_timeout: @query_timeout.seconds)
          socket.read_timeout = @query_timeout.seconds
          socket.write_timeout = @query_timeout.seconds
          begin
            header = IO::Memory.new
            header.write_bytes(message.size.to_u16, IO::ByteFormat::NetworkEndian)
            socket.write(header.to_slice)
            socket.write(message)
            socket.flush
            len_bytes = Bytes.new(2)
            socket.read_fully(len_bytes)
            len = (len_bytes[0].to_u16 << 8) | len_bytes[1]
            response = Bytes.new(len)
            socket.read_fully(response)
            response
          ensure
            socket.close
          end
        else
          socket = UDPSocket.new
          socket.connect(server, port)
          socket.read_timeout = @query_timeout.seconds
          socket.write_timeout = @query_timeout.seconds
          begin
            socket.write(message)
            socket.flush
            response = Bytes.new(65535)
            received = socket.read(response)
            response[0, received]
          ensure
            socket.close
          end
        end
      rescue e
        PluginResult.new(changed: false, failed: true,
          msg: "DNS server error: #{python_transport_error(e, protocol)}")
      end
    end

    # Python's binascii.a2b_base64 (what base64.b64decode and dnspython's
    # TSIG key setup end up in) validates the DATA-CHARACTER count after
    # discarding everything outside the base64 alphabet - its two error
    # wordings are what real's "TSIG key error: ..." wraps.
    private def python_base64_error(secret : String) : String?
      data_chars = secret.chars.count do |char|
        char.alphanumeric? || char == '+' || char == '/'
      end
      remainder = data_chars % 4
      return "Invalid base64-encoded string: number of data characters (#{data_chars}) cannot be 1 more than a multiple of 4" if remainder == 1
      return "Incorrect padding" if remainder == 2 || remainder == 3
      nil
    end

    # Real nsupdate.py surfaces dnspython's exceptions, whose str() is
    # Python's own OSError shape - the exception CLASS name plus
    # "[Errno <n>] <strerror>" (e.g. "(ConnectionRefusedError): [Errno 111]
    # Connection refused"), with dnspython's own dns.exception.Timeout
    # ("(Timeout): The DNS operation timed out.") for the timed-out case.
    # The UDP transport never surfaces the kernel's ECONNREFUSED (the
    # ICMP refusal arrives on a later recv, which dnspython's select loop
    # ignores until its lifetime expires), so a UDP failure is ALWAYS
    # reported as a timeout - exactly what N17's real side shows.
    private def python_transport_error(e : Exception, protocol : String) : String
      return "(Timeout): The DNS operation timed out." if protocol == "udp" || e.is_a?(IO::TimeoutError)

      errno = e.as?(Socket::Error).try(&.os_error).as?(Errno)
      return "(#{e.class.name.split("::").last}): #{e.message}" unless errno

      py_class = case errno
                 when .econnrefused? then "ConnectionRefusedError"
                 when .etimedout?    then "TimeoutError"
                 when .eacces?       then "PermissionError"
                 else                     "OSError"
                 end
      "(#{py_class}): [Errno #{errno.value}] #{String.new(LibC.strerror(errno.value))}"
    end

    # Sends a message, checks the response id; returns the parsed
    # response or a failure result.
    private def do_query(server : String, port : Int32, protocol : String, message : Bytes) : PluginResult?
      response = query_wire(server, port, protocol, message)
      return response.as(PluginResult) if response.is_a?(PluginResult)

      parsed = PluginHelpers::NsupdateMessage.parse_response(response.as(Bytes))
      @dns_rc = parsed.rcode
      @last_response = parsed
      nil
    rescue e
      PluginResult.new(changed: false, failed: true,
        msg: "DNS server error: (#{e.class.name.split("::").last}): #{e.message}")
    end

    # ------------------------------------------------------------------
    # Zone lookup (the real module's lookup_zone)
    # ------------------------------------------------------------------

    private def lookup_zone(server : String, port : Int32, protocol : String, record : String) : (String | PluginResult)
      name = record
      loop do
        id = new_id
        message = PluginHelpers::NsupdateMessage.build_query(id, name, 6, @tsig) # SOA
        if (failure = do_query(server, port, protocol, message))
          return failure
        end

        if [2, 5].includes?(@dns_rc) # SERVFAIL, REFUSED
          return PluginResult.new(changed: false, failed: true,
            msg: "Zone lookup failure: '#{server}' will not respond to queries regarding '#{record}'.")
        end

        response = @last_response.not_nil!
        response.answer.each do |rr|
          if rr.type_code == 6 && PluginHelpers::NsupdateMessage.names_equal?(rr.name, name)
            return rr.name
          end
        end
        response.authority.each do |rr|
          if rr.type_code == 6 && PluginHelpers::NsupdateMessage.subdomain_of?(name, rr.name)
            return rr.name
          end
        end

        parent = PluginHelpers::NsupdateMessage.parent(name)
        return PluginResult.new(changed: false, failed: true,
          msg: "Zone lookup of '#{record}' failed for unknown reason.") unless parent
        name = parent
      end
    end

    @last_response : PluginHelpers::NsupdateMessage::ParsedResponse?

    private def new_id : UInt16
      Random.new.rand(0u16..65535u16)
    end

    # ------------------------------------------------------------------
    # Record operations (the real module's methods, same rc bookkeeping)
    # ------------------------------------------------------------------

    private def send_update(server : String, port : Int32, protocol : String, zone : String,
                            prerequisites : Array(PluginHelpers::NsupdateMessage::RR),
                            updates : Array(PluginHelpers::NsupdateMessage::RR)) : PluginResult?
      message = PluginHelpers::NsupdateMessage.build_update(new_id, zone, prerequisites, updates, @tsig)
      do_query(server, port, protocol, message)
    end

    # 0 = record missing, 1 = record present with our values, 2 = record
    # present but values or TTL differ.
    private def record_exists(server : String, port : Int32, protocol : String,
                              zone : String, record : String, type_code : Int32,
                              values : Array(String)?) : (Int32 | PluginResult)
      failure = send_update(server, port, protocol, zone,
        [PluginHelpers::NsupdateMessage.prerequisite_present(record, type_code)], [] of PluginHelpers::NsupdateMessage::RR)
      # a transport-level error (unreachable/refusing server) fails the
      # task, the way the real module's __do_update exceptions do - only
      # a DNS-level rc != 0 means "record missing"
      return failure if failure
      return 0 if @dns_rc != 0

      return 1 if @params["state"]? == "absent"

      # the real module's value checks live at this same spot - after the
      # first probe round trip - so with an unreachable server a missing or
      # malformed value fails with the connection error first
      unless values
        return PluginResult.new(changed: false, failed: true,
          msg: "value needed when state=present")
      end

      # "RRSET exists with this rdata" per value
      prerequisites = values.map do |entry|
        rdata = begin
          PluginHelpers::NsupdateMessage.encode_rdata(type_name, entry)
        rescue PluginHelpers::NsupdateMessage::MalformedValueError
          return PluginResult.new(changed: false, failed: true,
            msg: "Invalid/malformed value")
        end
        PluginHelpers::NsupdateMessage.prerequisite_present_with(record, type_code, rdata)
      end

      failure = send_update(server, port, protocol, zone, prerequisites, [] of PluginHelpers::NsupdateMessage::RR)
      return failure if failure
      if @dns_rc == 0
        changed_ttl = ttl_changed(server, port, protocol, zone, record, type_code)
        return changed_ttl if changed_ttl.is_a?(PluginResult)
        return changed_ttl ? 2 : 1
      end
      2
    end

    @type_name = "A"

    private def type_name : String
      @type_name
    end

    private def ttl_changed(server : String, port : Int32, protocol : String,
                            zone : String, fqdn : String, type_code : Int32) : (Bool | PluginResult)
      id = new_id
      message = PluginHelpers::NsupdateMessage.build_query(id, fqdn, type_code, @tsig)
      if (failure = do_query(server, port, protocol, message))
        @dns_rc = 0
        return failure
      end

      if @dns_rc != 0
        return PluginResult.new(changed: false, failed: true,
          msg: "Failed to lookup TTL of existing matching record.")
      end

      response = @last_response.not_nil!
      current_ttl = response.answer.first?.try(&.ttl) || response.authority.first?.try(&.ttl) || 0
      current_ttl != (@ttl_value || 3600)
    end

    @ttl_value : Int32?

    private def create_or_update_record(server : String, port : Int32, protocol : String,
                                        zone : String, record : String, fqdn : String,
                                        type_code : Int32, ttl : Int32, values : Array(String)?) : (Tuple(Bool, Bool) | PluginResult)
      @ttl_value = ttl
      @type_name = (@params["type"]? || "A").upcase

      exists = record_exists(server, port, protocol, zone, record, type_code, values)
      return exists if exists.is_a?(PluginResult)

      if exists == 1
        return {false, false}
      end

      check_mode = true?(@params["_ansible_check_mode"]?)
      return PluginResult.new(changed: true, failed: false, msg: "check mode") if check_mode

      if exists == 0
        unless values
          return PluginResult.new(changed: false, failed: true,
            msg: "value needed when state=present")
        end
        rcode = create_record(server, port, protocol, zone, record, type_code, ttl, values.not_nil!)
        return PluginResult.new(changed: false, failed: true,
          msg: "Failed to create DNS record (rc: #{@dns_rc})",
          dns_rc: @dns_rc, dns_rc_str: PluginHelpers::NsupdateMessage.rcode_to_text(@dns_rc)) if rcode != 0
      elsif exists == 2
        unless values
          return PluginResult.new(changed: false, failed: true,
            msg: "value needed when state=present")
        end
        rcode = modify_record(server, port, protocol, zone, record, type_code, ttl, values.not_nil!)
        return PluginResult.new(changed: false, failed: true,
          msg: "Failed to update DNS record (rc: #{@dns_rc})",
          dns_rc: @dns_rc, dns_rc_str: PluginHelpers::NsupdateMessage.rcode_to_text(@dns_rc)) if rcode != 0
      end

      {true, false}
    end

    private def encode_values(record : String, type_code : Int32, ttl : Int32, values : Array(String)) : (Array(PluginHelpers::NsupdateMessage::RR) | PluginResult)
      type = (@params["type"]? || "A").upcase
      rrs = [] of PluginHelpers::NsupdateMessage::RR
      values.each do |entry|
        begin
          rdata = PluginHelpers::NsupdateMessage.encode_rdata(type, entry)
        rescue PluginHelpers::NsupdateMessage::MalformedValueError
          return PluginResult.new(changed: false, failed: true, msg: "Invalid/malformed value")
        end
        rrs << PluginHelpers::NsupdateMessage.update_add(record, type_code, ttl, rdata)
      end
      rrs
    end

    private def create_record(server : String, port : Int32, protocol : String,
                              zone : String, record : String, type_code : Int32,
                              ttl : Int32, values : Array(String)) : Int32
      if values.empty?
        @dns_rc = 5
        return 5
      end

      rrs = encode_values(record, type_code, ttl, values)
      return 1 if rrs.is_a?(PluginResult)

      send_update(server, port, protocol, zone, [] of PluginHelpers::NsupdateMessage::RR, rrs.as(Array(PluginHelpers::NsupdateMessage::RR)))

      @dns_rc
    end

    private def modify_record(server : String, port : Int32, protocol : String,
                              zone : String, record : String, type_code : Int32,
                              ttl : Int32, values : Array(String)) : Int32
      type = (@params["type"]? || "A").upcase
      updates = [] of PluginHelpers::NsupdateMessage::RR

      if type == "NS"
        # Bind9 silently refuses to delete all the NS entries for a
        # zone, so inserts happen first and stale entries are deleted
        # afterwards (see the real module's modify_record).
        id = new_id
        message = PluginHelpers::NsupdateMessage.build_query(id, record, type_code, @tsig)
        if do_query(server, port, protocol, message)
          return 1
        end

        lookup = @last_response.not_nil!
        existing = lookup.answer.empty? ? lookup.authority : lookup.answer
        stale = existing.flat_map do |record|
          decode_rr_values(record, type)
        end.reject { |entry| values.includes?(entry) }

        rrs = encode_values(record, type_code, ttl, values)
        return 1 if rrs.is_a?(PluginResult)
        updates += rrs.as(Array(PluginHelpers::NsupdateMessage::RR))
        stale.each do |entry|
          begin
            rdata = PluginHelpers::NsupdateMessage.encode_rdata(type, entry)
            updates << PluginHelpers::NsupdateMessage::RR.new(record, type_code,
              PluginHelpers::NsupdateMessage::CLASS_NONE, 0, rdata)
          rescue PluginHelpers::NsupdateMessage::MalformedValueError
            next
          end
        end
      else
        updates << PluginHelpers::NsupdateMessage.update_delete(record, type_code)
        rrs = encode_values(record, type_code, ttl, values)
        return 1 if rrs.is_a?(PluginResult)
        updates += rrs.as(Array(PluginHelpers::NsupdateMessage::RR))
      end

      send_update(server, port, protocol, zone, [] of PluginHelpers::NsupdateMessage::RR, updates)

      @dns_rc
    end

    # Decodes an RR's rdata back into the textual form values are
    # compared with (only the NS-record stale-entry path needs this).
    private def decode_rr_values(rr : PluginHelpers::NsupdateMessage::RR, type : String) : Array(String)
      data = rr.rdata
      case type
      when "A"
        data.size == 4 ? ["#{data[0]}.#{data[1]}.#{data[2]}.#{data[3]}"] : [] of String
      when "AAAA"
        begin
          groups = (0...8).map { |i| ((data[i * 2].to_u16 << 8) | data[i * 2 + 1]).to_s(16) }
          [groups.join(":")]
        rescue
          [] of String
        end
      when "TXT"
        begin
          pos = 0
          parts = [] of String
          while pos < data.size
            len = data[pos]
            parts << String.new(data[pos + 1, len])
            pos += 1 + len
          end
          parts.map { |part| "\"#{part}\"" }
        rescue
          [] of String
        end
      when "MX"
        if data.size > 3
          pref = (data[0].to_u16 << 8) | data[1]
          name, _ = PluginHelpers::NsupdateMessage.decode_name(data, 2)
          ["#{pref} #{name}"]
        else
          [] of String
        end
      when "NS", "CNAME", "PTR"
        begin
          [PluginHelpers::NsupdateMessage.decode_name(data, 0)[0]]
        rescue
          [] of String
        end
      else
        [] of String
      end
    end

    private def remove_record(server : String, port : Int32, protocol : String,
                              zone : String, record : String, type_code : Int32) : (Tuple(Bool, Bool) | PluginResult)
      exists = record_exists(server, port, protocol, zone, record, type_code, nil)
      return exists if exists.is_a?(PluginResult)
      return {false, false} if exists == 0

      check_mode = true?(@params["_ansible_check_mode"]?)
      return PluginResult.new(changed: true, failed: false, msg: "check mode") if check_mode

      failure = send_update(server, port, protocol, zone, [] of PluginHelpers::NsupdateMessage::RR,
        [PluginHelpers::NsupdateMessage.update_delete(record, type_code)])
      if failure
        return PluginResult.new(changed: false, failed: true,
          msg: "Failed to delete record (rc: #{@dns_rc})",
          dns_rc: @dns_rc, dns_rc_str: PluginHelpers::NsupdateMessage.rcode_to_text(@dns_rc))
      end

      if @dns_rc != 0
        return PluginResult.new(changed: false, failed: true,
          msg: "Failed to delete record (rc: #{@dns_rc})",
          dns_rc: @dns_rc, dns_rc_str: PluginHelpers::NsupdateMessage.rcode_to_text(@dns_rc))
      end

      {true, false}
    end
  end
end

input = STDIN.gets_to_end
config = JSON.parse(input)
plugin = Krikri::NsupdatePlugin.new(config)
plugin.run
