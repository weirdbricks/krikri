require "../minitest_helper"
require "../../src/krikri/plugin_helpers/nsupdate_message"

# A stand-in for the authoritative Bind9 the module talks to. It rejects an
# UPDATE exactly where Bind9 does (a zone section without ZTYPE/ZCLASS, an
# owner name outside the zone, a class-IN or class-NONE RR with an empty
# rdata) with the same rcode the real server returns, answers the existence
# probe with NOERROR (or NXRRSET when the stand-in's zone has no such record),
# and answers the TTL query with the record - so a spec's expected result only
# holds when the message layout dnspython produces is what goes on the wire.
private def start_nsupdate_server(zone : String, host : String, ttl : Int32, value_present : Bool = true, exists : Bool = true) : {TCPServer, Int32}
  listener = TCPServer.new("127.0.0.1", 0)
  port = listener.local_address.port
  spawn do
    loop do
      connection = listener.accept? || break
      spawn do
        begin
          length = connection.read_bytes(UInt16, IO::ByteFormat::NetworkEndian)
          message = Bytes.new(length)
          connection.read_fully(message)
          response = nsupdate_test_response(message, zone, host, ttl, value_present, exists)
          connection.write_bytes(response.size.to_u16, IO::ByteFormat::NetworkEndian)
          connection.write(response)
          connection.flush
        rescue
          # the plugin hung up early, which the assertion reports anyway
        ensure
          connection.close rescue nil
        end
      end
    end
  end
  Fiber.yield
  {listener, port}
end

private def nsupdate_test_u16(message : Bytes, offset : Int32) : Int32
  ((message[offset].to_u16 << 8) | message[offset + 1]).to_i32
end

# Bind9's rcode for one UPDATE message: 0 when it is valid, 1 (FORMERR) for
# a malformed section, 10 (NOTZONE) for an out-of-zone owner name and 8
# (NXRRSET) for a prerequisite the stand-in cannot satisfy - the RRSET-exists
# form when the record is missing, the specific-value form when it does not
# have that rdata, so the modify path gets exercised.
private def nsupdate_test_update_rcode(message : Bytes, zone : String, value_present : Bool, exists : Bool) : Int32
  section_rcode, pos = nsupdate_test_zone_section_rcode(message, zone)
  return section_rcode unless section_rcode == 0

  prerequisites = nsupdate_test_u16(message, 6)
  (prerequisites + nsupdate_test_u16(message, 8)).times do |index|
    rcode, pos = nsupdate_test_rr_rcode(message, pos, zone, index < prerequisites, value_present, exists)
    return rcode unless rcode == 0
  end
  0
end

# The zone section is one record (ZNAME ZTYPE ZCLASS), the layout Bind9
# insists on before it looks at the update itself.
private def nsupdate_test_zone_section_rcode(message : Bytes, zone : String) : {Int32, Int32}
  zone_name, pos = Krikri::PluginHelpers::NsupdateMessage.decode_name(message, 12)
  return {1, pos} unless Krikri::PluginHelpers::NsupdateMessage.names_equal?(zone_name, zone)
  return {1, pos} if pos + 4 > message.size
  return {1, pos} unless nsupdate_test_u16(message, pos) == 6 && nsupdate_test_u16(message, pos + 2) == 1
  {0, pos + 4}
end

private def nsupdate_test_rr_rcode(message : Bytes, pos : Int32, zone : String,
                                   prerequisite : Bool, value_present : Bool, exists : Bool) : {Int32, Int32}
  name, pos = Krikri::PluginHelpers::NsupdateMessage.decode_name(message, pos)
  return {10, pos} unless Krikri::PluginHelpers::NsupdateMessage.subdomain_of?(name, zone)
  return {1, pos} if pos + 10 > message.size
  class_code = nsupdate_test_u16(message, pos + 2)
  rdlength = nsupdate_test_u16(message, pos + 8)
  return {1, pos} if rdlength == 0 && (class_code == 1 || class_code == 254)
  return {8, pos} if prerequisite && class_code == 255 && !exists
  return {8, pos} if prerequisite && class_code == 1 && !value_present
  {0, pos + 10 + rdlength}
end

private def nsupdate_test_response(message : Bytes, zone : String, host : String, ttl : Int32, value_present : Bool, exists : Bool) : Bytes
  io = IO::Memory.new
  flags = ((message[2].to_u16 << 8) | message[3].to_u16) & 0x7800
  opcode = (flags >> 11).to_i32

  if opcode == 5
    rcode = nsupdate_test_update_rcode(message, zone, value_present, exists)
    io.write(message[0, 2])
    io.write_bytes((flags | 0x8000 | rcode.to_u16), IO::ByteFormat::NetworkEndian)
    io.write(Bytes.new(8, 0))
    return io.to_slice
  end

  qname, pos = Krikri::PluginHelpers::NsupdateMessage.decode_name(message, 12)
  matches = Krikri::PluginHelpers::NsupdateMessage.names_equal?(qname, "#{host}.#{zone}")
  io.write(message[0, 2])
  io.write_bytes((flags | 0x8400 | (matches ? 0u16 : 3u16)), IO::ByteFormat::NetworkEndian)
  io.write_bytes(1u16, IO::ByteFormat::NetworkEndian)                  # QDCOUNT
  io.write_bytes(matches ? 1u16 : 0u16, IO::ByteFormat::NetworkEndian) # ANCOUNT
  io.write(Bytes.new(4, 0))
  io.write(message[12, pos + 4 - 12]) # the question, as asked
  if matches
    io.write(Bytes[0xC0, 0x0C]) # the question name, compressed
    io.write(Bytes[0, 1, 0, 1]) # A IN
    io.write_bytes(ttl.to_u32, IO::ByteFormat::NetworkEndian)
    io.write_bytes(4u16, IO::ByteFormat::NetworkEndian)
    io.write(Bytes[10, 0, 0, 1])
  end
  io.to_slice
end

# nsupdate's parameter-validation failures and its offline failure
# path (connection refused), exercised without a DNS server. The real
# RFC2136 create/modify/delete flows - and the TSIG-authenticated
# updates they need - belong to the live benchmark rounds.
describe "nsupdate plugin" do
  it "fails when server is missing" do
    result = PluginSpecHelper.run("nsupdate", {"record" => "host.example.com."})

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_include("server")
  end

  it "fails when record is missing" do
    result = PluginSpecHelper.run("nsupdate", {"server" => "127.0.0.1"})

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_include("record")
  end

  it "fails when record is empty" do
    result = PluginSpecHelper.run("nsupdate", {"server" => "127.0.0.1", "record" => ""})

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_include("record cannot be empty")
  end

  it "fails on an invalid state" do
    result = PluginSpecHelper.run("nsupdate", {
      "server" => "127.0.0.1", "record" => "host.example.com.", "state" => "bogus",
    })

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_include("value of state must be one of")
  end

  it "fails on an invalid protocol" do
    result = PluginSpecHelper.run("nsupdate", {
      "server" => "127.0.0.1", "record" => "host.example.com.", "protocol" => "carrier-pigeon",
    })

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_include("value of protocol must be one of")
  end

  it "fails on an unknown record type (pre-network, dnspython wording)" do
    # DHCID is a valid dnspython type (Ansible accepts it and proceeds
    # to the network); the unknown-type wording is confirmed for truly
    # unknown types via podman-diff case N14 - and it fires before any
    # traffic, so the unreachable server never matters here.
    result = PluginSpecHelper.run("nsupdate", {
      "server" => "127.0.0.1", "record" => "host.example.com.",
      "zone" => "example.com.", "type" => "NOTATYPE",
    })

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal("Record error: DNS resource record type is unknown.")
  end

  it "fails on an invalid key_algorithm" do
    result = PluginSpecHelper.run("nsupdate", {
      "server" => "127.0.0.1", "record" => "host.example.com.", "key_algorithm" => "hmac-md6",
    })

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_include("value of key_algorithm must be one of")
  end

  it "fails explicitly on gss-tsig (deliberate limitation)" do
    result = PluginSpecHelper.run("nsupdate", {
      "server" => "127.0.0.1", "record" => "host.example.com.", "key_algorithm" => "gss-tsig",
    })

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_include("gss-tsig")
  end

  it "reports the connection error before a missing value (moment-of-use)" do
    # real nsupdate only checks the value inside create_record, after the
    # record-exists probe round trip - with no server, the connection
    # error wins (podman-diff case N16)
    result = PluginSpecHelper.run("nsupdate", {
      "server" => "127.0.0.1", "port" => "1",
      "record" => "host.example.com.", "zone" => "example.com.", "state" => "present",
    })

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_include("DNS server error")
  end

  it "fails cleanly when the DNS server refuses the connection" do
    result = PluginSpecHelper.run("nsupdate", {
      "server" => "127.0.0.1", "port" => "1",
      "record" => "host.example.com.", "zone" => "example.com.", "state" => "absent",
    })

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_include("DNS server error")
  end

  it "reports the connection error before a malformed value (moment-of-use)" do
    # same moment-of-use validation: the connection error wins first
    # (podman-diff case N15)
    result = PluginSpecHelper.run("nsupdate", {
      "server" => "127.0.0.1", "port" => "1",
      "record" => "host.example.com.", "zone" => "example.com.",
      "type" => "A", "value" => "not-an-ip-address",
    })

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_include("DNS server error")
  end

  it "reports a malformed value when the existence probe finds no record" do
    # The probe answering NXRRSET sends the module to create_record, whose
    # first add() raises SyntaxError before the update is sent - so the bad
    # A value fails as "Invalid/malformed value", not with the probe's
    # rcode (kpg issue 1964: the generated playbook pointed at a server
    # that answered NXRRSET).
    listener, port = start_nsupdate_server("example.com.", "host", 68, exists: false)
    begin
      result = PluginSpecHelper.run("nsupdate", {
        "server" => "127.0.0.1", "port" => port.to_s,
        "record" => "host", "zone" => "example.com.",
        "type" => "A", "value" => "not-an-ip-address",
      })
    ensure
      listener.close rescue nil
    end

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal("Invalid/malformed value")
    result["dns_rc"]?.must_be_nil
  end

  it "reports no change needed when the server accepts the update layout" do
    # A relative record plus the zone is what the generated playbooks send;
    # Bind9 answered the old messages FORMERR (zone section without
    # ZTYPE/ZCLASS, class-IN probe) or NOTZONE (bare "host." owner names),
    # failing tasks where Ansible succeeded.
    listener, port = start_nsupdate_server("example.com.", "host", 68)
    begin
      result = PluginSpecHelper.run("nsupdate", {
        "server" => "127.0.0.1", "port" => port.to_s,
        "record" => "host", "zone" => "example.com.", "type" => "A",
        "ttl" => "68", "value" => "10.0.0.1",
      })
    ensure
      listener.close rescue nil
    end

    result["failed"]?.must_be_nil
    result["changed"].as_bool.must_equal(false)
    result["msg"].as_s.must_equal("no change needed")
  end

  it "deletes and re-adds the RRset when the value differs" do
    # The modify path sends a class-ANY RRset delete; the old class-NONE
    # empty-rdata form is a malformed individual delete and Bind9 answered
    # FORMERR where Ansible's update succeeded.
    listener, port = start_nsupdate_server("example.com.", "host", 68, value_present: false)
    begin
      result = PluginSpecHelper.run("nsupdate", {
        "server" => "127.0.0.1", "port" => port.to_s,
        "record" => "host", "zone" => "example.com.", "type" => "A",
        "ttl" => "68", "value" => "10.0.0.2",
      })
    ensure
      listener.close rescue nil
    end

    result["failed"]?.must_be_nil
    result["changed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal("DNS record created/updated")
  end

  it "removes the RRset with a class-ANY delete" do
    listener, port = start_nsupdate_server("example.com.", "host", 68)
    begin
      result = PluginSpecHelper.run("nsupdate", {
        "server" => "127.0.0.1", "port" => port.to_s,
        "record" => "host", "zone" => "example.com.", "type" => "A",
        "state" => "absent",
      })
    ensure
      listener.close rescue nil
    end

    result["failed"]?.must_be_nil
    result["changed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal("DNS record removed")
  end
end
