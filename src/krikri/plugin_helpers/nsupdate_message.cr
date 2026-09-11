require "socket"
require "openssl/hmac"

module Krikri
  module PluginHelpers
    # NsupdateMessage - a minimal RFC2136 dynamic-DNS client (wire
    # format + RFC2845 TSIG signing), the pieces of dnspython that
    # community.general.nsupdate actually drives: SOA queries (zone
    # lookup), standard queries (TTL check), and UPDATE messages with
    # prerequisites (record-exists probes), add/delete RR operations.
    # Pure byte plumbing + response parsing so it is unit-testable
    # without a DNS server; the plugin executes the network I/O.
    module NsupdateMessage
      TYPES = {
        "A" => 1, "NS" => 2, "CNAME" => 5, "SOA" => 6, "PTR" => 12,
        "MX" => 15, "TXT" => 16, "AAAA" => 28, "SRV" => 33, "ANY" => 255,
      }
      TYPE_NAMES = {
        1 => "A", 2 => "NS", 5 => "CNAME", 6 => "SOA", 12 => "PTR",
        15 => "MX", 16 => "TXT", 28 => "AAAA", 33 => "SRV", 255 => "ANY",
      }
      CLASS_IN  = 1
      CLASS_NONE = 254
      CLASS_ANY = 255
      TYPE_TSIG = 250

      # dnspython's dns.rcode.to_text table (the ones a DDNS update flow
      # can realistically see).
      RCODES = {
        0 => "NOERROR", 1 => "FORMERR", 2 => "SERVFAIL", 3 => "NXDOMAIN",
        4 => "NOTIMP", 5 => "REFUSED", 6 => "YXDOMAIN", 7 => "YXRRSET",
        8 => "NXRRSET", 9 => "NOTAUTH", 10 => "NOTZONE", 11 => "DSOTYPENI",
        12 => "BADSIG", 13 => "BADKEY", 14 => "BADTIME", 15 => "BADMODE",
        16 => "BADNAME", 17 => "BADALG", 18 => "BADTRUNC", 19 => "BADCOOKIE",
      }

      def self.rcode_to_text(rcode : Int32) : String
        RCODES[rcode]? || "RCODE#{rcode}"
      end

      # The TSIG signing material for one message flow.
      record Tsig, key_name : String, secret : Slice(UInt8), algorithm : String

      # One resource record, generic enough for build and parse.
      record RR, name : String, type_code : Int32, class_code : Int32, ttl : Int32, rdata : Slice(UInt8)

      class WireError < Exception
      end

      class MalformedValueError < Exception
      end

      # ------------------------------------------------------------------
      # Name encoding/decoding
      # ------------------------------------------------------------------

      # Encodes a (possibly relative) dotted name. No escape sequences,
      # no compression.
      def self.encode_name(name : String) : Bytes
        return Bytes.new(0) if name.empty? || name == "."

        buf = IO::Memory.new
        name.chomp(".").split(".", remove_empty: true).each do |label|
          raise WireError.new("label too long: #{label}") if label.bytesize > 63
          raise WireError.new("empty label in #{name}") if label.empty?
          buf.write_byte(label.bytesize.to_u8)
          buf.write(label.to_slice)
        end
        buf.write_byte(0)
        buf.to_slice
      end

      # Decodes a name at *offset* in *message*, following compression
      # pointers; returns {name (absolute, trailing dot), next_offset}.
      def self.decode_name(message : Bytes, offset : Int32) : {String, Int32}
        labels = [] of String
        jumped = false
        next_offset = offset
        seen = 0
        pos = offset
        loop do
          seen += 1
          raise WireError.new("name decompression loop") if seen > 255
          len = message[pos]?
          raise WireError.new("truncated name") unless len
          if len == 0
            next_offset = pos + 1 unless jumped
            break
          elsif (len & 0xC0) == 0xC0
            b2 = message[pos + 1]?
            raise WireError.new("truncated compression pointer") unless b2
            pointer = (((len & 0x3F).to_i32 << 8) | b2.to_i32)
            next_offset = pos + 2 unless jumped
            jumped = true
            pos = pointer
          elsif (len & 0xC0) != 0
            raise WireError.new("invalid label type")
          else
            chunk = message[pos + 1, len]
            raise WireError.new("truncated label") unless chunk.size == len
            labels << String.new(chunk)
            pos += 1 + len
          end
        end
        name = labels.empty? ? "." : labels.join(".") + "."
        {name, next_offset}
      end

      # Case-insensitive DNS name equality on label sequences.
      def self.names_equal?(a : String, b : String) : Bool
        a.downcase == b.downcase
      end

      # True when *name* is a subdomain of (or equal to) *zone*.
      def self.subdomain_of?(name : String, zone : String) : Bool
        n = name.downcase.chomp(".")
        z = zone.downcase.chomp(".")
        return true if z.empty?
        n == z || n.ends_with?(".#{z}")
      end

      # Drops the leftmost label of an absolute name (dns.name#parent).
      def self.parent(name : String) : String?
        labels = name.chomp(".").split(".", remove_empty: true)
        return nil if labels.size <= 1
        labels[1..].join(".") + "."
      end

      # ------------------------------------------------------------------
      # RR section packing
      # ------------------------------------------------------------------

      private def self.pack_rr(io : IO::Memory, rr : RR) : Nil
        io.write(encode_name(rr.name))
        put16(io, rr.type_code.to_u16)
        put16(io, rr.class_code.to_u16)
        put32(io, rr.ttl.to_u32)
        put16(io, rr.rdata.size.to_u16)
        io.write(rr.rdata)
      end

      private def self.put16(io : IO, v : UInt16) : Nil
        io.write_bytes(v, IO::ByteFormat::NetworkEndian)
      end

      private def self.put32(io : IO, v : UInt32) : Nil
        io.write_bytes(v, IO::ByteFormat::NetworkEndian)
      end

      # ------------------------------------------------------------------
      # RDATA encoding (the value grammar the real module feeds
      # dnspython's rdata constructors with).
      # ------------------------------------------------------------------

      def self.encode_rdata(type_name : String, value : String) : Bytes
        case type_name.upcase
        when "A"
          parts = value.split(".")
          raise MalformedValueError.new unless parts.size == 4
          bytes = parts.map do |p|
            octet = p.to_i?
            raise MalformedValueError.new unless octet && octet >= 0 && octet <= 255
            octet.to_u8
          end
          Slice(UInt8).new(bytes.size) { |i| bytes[i] }
        when "AAAA"
          ipv6_bytes(value)
        when "NS", "CNAME", "PTR"
          encode_name(value)
        when "TXT"
          encode_txt(value)
        when "MX"
          parts = value.split(/\s+/, 2)
          raise MalformedValueError.new unless parts.size == 2
          pref = parts[0].to_i?
          raise MalformedValueError.new unless pref && pref >= 0
          buf = IO::Memory.new
          put16(buf, pref.to_u16)
          buf.write(encode_name(parts[1]))
          buf.to_slice
        when "SRV"
          parts = value.split(/\s+/)
          raise MalformedValueError.new unless parts.size == 4
          prio = parts[0].to_i?
          weight = parts[1].to_i?
          port = parts[2].to_i?
          raise MalformedValueError.new unless prio && weight && port
          buf = IO::Memory.new
          put16(buf, prio.to_u16)
          put16(buf, weight.to_u16)
          put16(buf, port.to_u16)
          buf.write(encode_name(parts[3]))
          buf.to_slice
        else
          raise MalformedValueError.new
        end
      end

      private def self.ipv6_bytes(value : String) : Bytes
        bytes = Array(UInt8).new(16, 0)
        head, tail = value.split("::", 2)
        head_groups = head.empty? ? [] of String : head.split(":", remove_empty: true)
        tail_groups = tail.nil? ? [] of String : (tail.empty? ? [] of String : tail.split(":", remove_empty: true))
        raise MalformedValueError.new if tail.nil? && (head_groups.size != 8)
        raise MalformedValueError.new if head_groups.size + tail_groups.size > 7 && !tail.nil?
        fill = 8 - head_groups.size - tail_groups.size
        raise MalformedValueError.new if fill < 0
        groups = head_groups + Array.new(fill, "0") + tail_groups
        raise MalformedValueError.new unless groups.size == 8
        groups.each_with_index do |g, i|
          num = g.to_i?(16)
          raise MalformedValueError.new unless num && num >= 0 && num <= 0xFFFF
          bytes[i * 2] = (num >> 8).to_u8
          bytes[i * 2 + 1] = (num & 0xFF).to_u8
        end
        Slice(UInt8).new(16) { |i| bytes[i] }
      end

      # The value has already passed the real module's txt_helper (so it
      # carries its own quotes when quoted): strip them, then emit
      # <=255-byte character-strings.
      private def self.encode_txt(value : String) : Bytes
        unquoted = value.size >= 2 && value[0] == '"' && value[-1] == '"' ? value[1..-2] : value
        buf = IO::Memory.new
        data = unquoted.to_slice
        i = 0
        while i < data.size
          chunk = data[i, Math.min(255, data.size - i)]
          buf.write_byte(chunk.size.to_u8)
          buf.write(chunk)
          i += 255
        end
        buf.write_byte(0) if data.empty?
        buf.to_slice
      end

      # The real module's txt_helper: make sure a TXT value carries
      # quotes so dnspython's character-string parser sees one string.
      def self.txt_helper(entry : String) : String
        entry = entry.strip
        return entry if entry.size >= 2 && entry[0] == '"' && entry[-1] == '"'
        "\"#{entry}\""
      end

      # ------------------------------------------------------------------
      # Message building
      # ------------------------------------------------------------------

      # A standard query (opcode QUERY, RD set), optional TSIG in
      # additional.
      def self.build_query(id : UInt16, qname : String, qtype : Int32, tsig : Tsig?) : Bytes
        io = IO::Memory.new
        put16(io, id)
        flags = 0x0100 # RD
        put16(io, flags.to_u16)
        put16(io, 1u16) # QDCOUNT
        put16(io, 0u16) # ANCOUNT
        put16(io, 0u16) # NSCOUNT
        put16(io, tsig ? 1u16 : 0u16)
        io.write(encode_name(qname))
        put16(io, qtype.to_u16)
        put16(io, CLASS_IN.to_u16)
        append_tsig(io, tsig, id) if tsig
        io.to_slice
      end

      # An RFC2136 UPDATE message: zone section, prerequisite RRs
      # (class IN, "must exist" style), update RRs (add: class IN;
      # delete: class NONE).
      def self.build_update(id : UInt16, zone : String, prerequisites : Array(RR), updates : Array(RR), tsig : Tsig?) : Bytes
        io = IO::Memory.new
        put16(io, id)
        flags = (5 << 11) # OPCODE=UPDATE
        put16(io, flags.to_u16)
        put16(io, 1u16)                         # ZOCOUNT
        put16(io, prerequisites.size.to_u16)    # PRCOUNT
        put16(io, updates.size.to_u16)          # UPCOUNT
        put16(io, tsig ? 1u16 : 0u16)           # ARCOUNT
        io.write(encode_name(zone))
        prerequisites.each { |rr| pack_rr(io, rr) }
        updates.each { |rr| pack_rr(io, rr) }
        append_tsig(io, tsig, id) if tsig
        io.to_slice
      end

      # "this RRSET exists (independent of rdata)" prerequisite.
      def self.prerequisite_present(name : String, type_code : Int32) : RR
        RR.new(name, type_code, CLASS_IN, 0, Bytes.new(0))
      end

      # "RRSET exists with this rdata" prerequisite.
      def self.prerequisite_present_with(name : String, type_code : Int32, rdata : Bytes) : RR
        RR.new(name, type_code, CLASS_IN, 0, rdata)
      end

      def self.update_add(name : String, type_code : Int32, ttl : Int32, rdata : Bytes) : RR
        RR.new(name, type_code, CLASS_IN, ttl, rdata)
      end

      def self.update_delete(name : String, type_code : Int32) : RR
        RR.new(name, type_code, CLASS_NONE, 0, Bytes.new(0))
      end

      # RFC2845 TSIG RR appended to the additional section: the MAC is
      # computed over the whole message with an empty MAC field
      # (dnspython's signing order), then spliced in. Returns the final
      # bytes.
      private def self.append_tsig(io : IO::Memory, tsig : Tsig, id : UInt16) : Nil
        io.write(encode_name(tsig.key_name))
        put16(io, TYPE_TSIG.to_u16)
        put16(io, CLASS_ANY.to_u16)
        put32(io, 0u32) # TTL
        rdlength_at = io.pos
        put16(io, 0u16) # rdata length placeholder
        rdata_start = io.pos
        io.write(encode_name(tsig.algorithm))
        now = Time.utc.to_unix
        # Time Signed: 6 bytes (48-bit seconds)
        5.downto(0) { |shift| io.write_byte(((now >> (shift * 8)) & 0xFF).to_u8) }
        put16(io, 300u16) # Fudge
        mac_field_at = io.pos
        put16(io, 0u16)   # MAC size (empty while signing)
        put16(io, id)     # Original ID
        put16(io, 0u16)   # Error
        put16(io, 0u16)   # Other len
        rdata_end = io.pos

        # sign over the message with the MAC field empty (rdlength
        # reflects the empty MAC), per RFC2845
        put16_at(io, rdlength_at, (rdata_end - rdata_start).to_u16)
        mac = hmac(tsig, io.to_slice[0, rdata_end])

        # splice the MAC in: its 16-64 bytes widen the rdata past the
        # signed-over layout, and the MAC size field gains its value
        put16_at(io, rdlength_at, (rdata_end - rdata_start + mac.size).to_u16)
        final = IO::Memory.new
        original = io.to_slice
        final.write(original[0, mac_field_at])
        put16(final, mac.size.to_u16)
        final.write(mac)
        final.write(original[(mac_field_at + 2)..]) # Original ID, Error, Other len
        io.clear
        io.write(final.to_slice)
      end

      private def self.put16_at(io : IO::Memory, offset : Int32, v : UInt16) : Nil
        buf = io.to_slice
        buf[offset] = (v >> 8).to_u8
        buf[offset + 1] = (v & 0xFF).to_u8
      end

      def self.hmac(tsig : Tsig, data : Bytes) : Bytes
        algo = tsig.algorithm.downcase.chomp(".")
        # the real module's (dnspython's) canonical hmac-md5 name
        algo = "hmac-md5" if algo == "hmac-md5.sig-alg.reg.int"
        algorithm = case algo
                    when "hmac-md5"   then OpenSSL::Algorithm::MD5
                    when "hmac-sha1"  then OpenSSL::Algorithm::SHA1
                    when "hmac-sha224" then OpenSSL::Algorithm::SHA224
                    when "hmac-sha256" then OpenSSL::Algorithm::SHA256
                    when "hmac-sha384" then OpenSSL::Algorithm::SHA384
                    when "hmac-sha512" then OpenSSL::Algorithm::SHA512
                    else
                      raise WireError.new("unsupported TSIG algorithm #{tsig.algorithm}")
                    end
        OpenSSL::HMAC.digest(algorithm, tsig.secret, data).to_slice
      end

      # ------------------------------------------------------------------
      # Response parsing
      # ------------------------------------------------------------------

      record ParsedResponse, id : UInt16, rcode : Int32, answer : Array(RR), authority : Array(RR)

      def self.parse_response(message : Bytes) : ParsedResponse
        raise WireError.new("truncated response") if message.size < 12
        id = (message[0].to_u16 << 8) | message[1].to_u16
        flags = (message[2].to_u16 << 8) | message[3].to_u16
        rcode = (flags & 0x0F).to_i32
        qd = ((message[4].to_u16 << 8) | message[5]).to_i32
        an = ((message[6].to_u16 << 8) | message[7]).to_i32
        ns = ((message[8].to_u16 << 8) | message[9]).to_i32
        pos = 12
        qd.times do
          _, pos = decode_name(message, pos)
          raise WireError.new("truncated question") if pos + 4 > message.size
          pos += 4
        end
        answer = parse_section(message, pos, an)
        pos = answer[1]
        authority = parse_section(message, pos, ns)
        ParsedResponse.new(id, rcode, answer[0], authority[0])
      end

      private def self.parse_section(message : Bytes, start : Int32, count : Int32) : {Array(RR), Int32}
        records = [] of RR
        pos = start
        count.times do
          name, p = decode_name(message, pos)
          raise WireError.new("truncated RR") if p + 10 > message.size
          type_code = ((message[p].to_u16 << 8) | message[p + 1]).to_i32
          class_code = ((message[p + 2].to_u16 << 8) | message[p + 3]).to_i32
          ttl = ((message[p + 4].to_u32 << 24) | (message[p + 5].to_u32 << 16) | (message[p + 6].to_u32 << 8) | message[p + 7].to_u32).to_i32
          rdlength = (message[p + 8].to_u16 << 8) | message[p + 9].to_u16
          data_start = p + 10
          raise WireError.new("truncated rdata") if data_start + rdlength > message.size
          records << RR.new(name, type_code, class_code, ttl, message[data_start, rdlength])
          pos = data_start + rdlength
        end
        {records, pos}
      end
    end
  end
end
