require "../minitest_helper"
require "../../src/krikri/plugin_helpers/nsupdate_message"

# Unit-tests the nsupdate pure logic: DNS wire-format name/rdata
# encoding, message building, response parsing and the RFC2845 TSIG
# plumbing. The plugin's network I/O (and the real DNS-server flows the
# RFC2136 update path needs) belong to the live benchmark rounds.
describe Krikri::PluginHelpers::NsupdateMessage do
  describe ".encode_name" do
    it "emits length-prefixed labels with a root terminator" do
      Krikri::PluginHelpers::NsupdateMessage.encode_name("host.example.com.").must_equal(
        Bytes[4, 'h'.ord, 'o'.ord, 's'.ord, 't'.ord, 7, 'e'.ord, 'x'.ord, 'a'.ord, 'm'.ord, 'p'.ord,
          'l'.ord, 'e'.ord, 3, 'c'.ord, 'o'.ord, 'm'.ord, 0])
    end

    it "accepts relative names and the root" do
      Krikri::PluginHelpers::NsupdateMessage.encode_name("example.com").must_equal(
        Bytes[7, 'e'.ord, 'x'.ord, 'a'.ord, 'm'.ord, 'p'.ord, 'l'.ord, 'e'.ord, 3, 'c'.ord, 'o'.ord, 'm'.ord, 0])
      Krikri::PluginHelpers::NsupdateMessage.encode_name(".").size.must_equal(0)
      Krikri::PluginHelpers::NsupdateMessage.encode_name("").size.must_equal(0)
    end

    it "rejects over-long labels" do
      assert_raises(Krikri::PluginHelpers::NsupdateMessage::WireError) do
        Krikri::PluginHelpers::NsupdateMessage.encode_name("#{"a" * 64}.example.com")
      end
    end
  end

  describe ".decode_name / .encode_name roundtrip" do
    it "round-trips a plain name" do
      msg = Krikri::PluginHelpers::NsupdateMessage.encode_name("a.b.example.")
      name, next_offset = Krikri::PluginHelpers::NsupdateMessage.decode_name(msg, 0)
      name.must_equal("a.b.example.")
      next_offset.must_equal(msg.size)
    end

    it "follows compression pointers without consuming the pointed-to bytes" do
      io = IO::Memory.new
      io.write(Krikri::PluginHelpers::NsupdateMessage.encode_name("example.com."))
      pointer_at = io.pos
      io.write_byte(0xC0u8)
      io.write_byte(0u8)
      msg = io.to_slice
      name, next_offset = Krikri::PluginHelpers::NsupdateMessage.decode_name(msg, pointer_at)
      name.must_equal("example.com.")
      next_offset.must_equal(pointer_at + 2)
    end
  end

  describe ".names_equal? / .subdomain_of? / .parent" do
    it "compares names case-insensitively" do
      Krikri::PluginHelpers::NsupdateMessage.names_equal?("Host.Example.Com.", "host.example.com.").must_equal(true)
      Krikri::PluginHelpers::NsupdateMessage.names_equal?("host.example.com.", "other.example.com.").must_equal(false)
    end

    it "recognizes subdomains (and equality) but not superdomains" do
      Krikri::PluginHelpers::NsupdateMessage.subdomain_of?("www.example.com.", "example.com.").must_equal(true)
      Krikri::PluginHelpers::NsupdateMessage.subdomain_of?("example.com.", "example.com.").must_equal(true)
      Krikri::PluginHelpers::NsupdateMessage.subdomain_of?("example.com.", "www.example.com.").must_equal(false)
      Krikri::PluginHelpers::NsupdateMessage.subdomain_of?("notexample.com.", "example.com.").must_equal(false)
    end

    it "drops the leftmost label for the SOA zone walk" do
      Krikri::PluginHelpers::NsupdateMessage.parent("www.example.com.").must_equal("example.com.")
      Krikri::PluginHelpers::NsupdateMessage.parent("com.").must_be_nil
    end
  end

  describe ".encode_rdata" do
    it "encodes an A record as four octets" do
      Krikri::PluginHelpers::NsupdateMessage.encode_rdata("A", "192.0.2.1").must_equal(Bytes[192, 0, 2, 1])
    end

    it "rejects malformed A values" do
      ["192.0.2", "192.0.2.256", "not-an-ip"].each do |value|
        assert_raises(Krikri::PluginHelpers::NsupdateMessage::MalformedValueError) do
          Krikri::PluginHelpers::NsupdateMessage.encode_rdata("A", value)
        end
      end
    end

    it "encodes AAAA (including :: compression)" do
      Krikri::PluginHelpers::NsupdateMessage.encode_rdata("AAAA", "2001:db8::1").must_equal(
        Bytes[0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1])
      assert_raises(Krikri::PluginHelpers::NsupdateMessage::MalformedValueError) do
        Krikri::PluginHelpers::NsupdateMessage.encode_rdata("AAAA", "2001:db8::zzzz")
      end
    end

    it "encodes MX as preference plus name" do
      Krikri::PluginHelpers::NsupdateMessage.encode_rdata("MX", "10 mail.example.com.").must_equal(
        Bytes[0, 10, 4, 'm'.ord, 'a'.ord, 'i'.ord, 'l'.ord, 7, 'e'.ord, 'x'.ord, 'a'.ord, 'm'.ord,
          'p'.ord, 'l'.ord, 'e'.ord, 3, 'c'.ord, 'o'.ord, 'm'.ord, 0])
    end

    it "encodes TXT as quoted character-strings and rejects unknown types" do
      Krikri::PluginHelpers::NsupdateMessage.encode_rdata("TXT", "\"hello world\"").must_equal(
        Bytes[11, 'h'.ord, 'e'.ord, 'l'.ord, 'l'.ord, 'o'.ord, ' '.ord, 'w'.ord, 'o'.ord, 'r'.ord, 'l'.ord, 'd'.ord])
      assert_raises(Krikri::PluginHelpers::NsupdateMessage::MalformedValueError) do
        Krikri::PluginHelpers::NsupdateMessage.encode_rdata("DHCID", "whatever")
      end
    end
  end

  describe ".txt_helper" do
    it "quotes bare values and keeps already-quoted ones" do
      Krikri::PluginHelpers::NsupdateMessage.txt_helper("hello").must_equal("\"hello\"")
      Krikri::PluginHelpers::NsupdateMessage.txt_helper("\"hello\"").must_equal("\"hello\"")
    end
  end

  describe ".build_query / .parse_response roundtrip" do
    it "builds a standard query with a question section" do
      msg = Krikri::PluginHelpers::NsupdateMessage.build_query(0x1234u16, "example.com.", 6, nil)
      msg[0].must_equal(0x12)
      msg[1].must_equal(0x34)
      # RD flag, QDCOUNT=1, everything else 0
      msg[2].must_equal(0x01)
      msg[3].must_equal(0x00)
      msg[4, 8].must_equal(Bytes[0, 1, 0, 0, 0, 0, 0, 0])
    end

    it "round-trips an answer RR through parse_response" do
      msg = Krikri::PluginHelpers::NsupdateMessage.build_query(0x0102u16, "example.com.", 1, nil)
      parsed = Krikri::PluginHelpers::NsupdateMessage.parse_response(msg)
      parsed.id.must_equal(0x0102)
      parsed.rcode.must_equal(0)
      parsed.answer.size.must_equal(0)
    end

    it "reads the rcode out of a response" do
      id = 0x4321u16
      io = IO::Memory.new
      io.write_bytes(id, IO::ByteFormat::NetworkEndian)
      io.write_bytes(0x8105u16, IO::ByteFormat::NetworkEndian) # QR+RD+RA, RCODE=REFUSED
      io.write(Bytes.new(8, 0))
      parsed = Krikri::PluginHelpers::NsupdateMessage.parse_response(io.to_slice)
      parsed.rcode.must_equal(5)
      Krikri::PluginHelpers::NsupdateMessage.rcode_to_text(parsed.rcode).must_equal("REFUSED")
    end
  end

  describe ".build_update" do
    it "sets opcode UPDATE with zone/prerequisite/update counts" do
      prereq = Krikri::PluginHelpers::NsupdateMessage.prerequisite_present("host.example.com.", 1)
      update = Krikri::PluginHelpers::NsupdateMessage.update_add("host.example.com.", 1, 3600,
        Krikri::PluginHelpers::NsupdateMessage.encode_rdata("A", "192.0.2.7"))
      msg = Krikri::PluginHelpers::NsupdateMessage.build_update(0x00ffu16, "example.com.", [prereq], [update], nil)

      msg[2, 2].must_equal(Bytes[0x28, 0x00])       # opcode 5 (UPDATE) in the flags
      msg[4, 6].must_equal(Bytes[0, 1, 0, 1, 0, 1]) # ZOCOUNT/PRCOUNT/UPCOUNT
      # delete-style updates carry class NONE and ttl 0
      del = Krikri::PluginHelpers::NsupdateMessage.update_delete("host.example.com.", 1)
      del.class_code.must_equal(254)
      del.ttl.must_equal(0)
    end
  end

  describe "TSIG" do
    it "appends a well-formed TSIG RR (correct rdlength, spliced MAC)" do
      tsig = Krikri::PluginHelpers::NsupdateMessage::Tsig.new("sig-key.",
        "secret".to_slice, "HMAC-MD5.SIG-ALG.REG.INT")
      msg = Krikri::PluginHelpers::NsupdateMessage.build_query(0x0001u16, "example.com.", 6, tsig)

      # header: id + RD + QDCOUNT=1 + ARCOUNT=1
      msg[0, 2].must_equal(Bytes[0, 1])
      msg[2, 2].must_equal(Bytes[0x01, 0x00])
      msg[4, 8].must_equal(Bytes[0, 1, 0, 0, 0, 0, 0, 1])

      # walk to the TSIG RR: skip header + question
      pos = 12
      while msg[pos] != 0
        pos += 1 + msg[pos]
      end
      pos += 5 # root terminator + qtype + qclass

      name, pos = Krikri::PluginHelpers::NsupdateMessage.decode_name(msg, pos)
      name.must_equal("sig-key.")
      type_code = (msg[pos].to_u16 << 8) | msg[pos + 1]
      type_code.must_equal(250)
      rdlength = (msg[pos + 8].to_u16 << 8) | msg[pos + 9]
      rdata = msg[pos + 10, rdlength]

      alg, rpos = Krikri::PluginHelpers::NsupdateMessage.decode_name(rdata, 0)
      alg.must_equal("HMAC-MD5.SIG-ALG.REG.INT.")
      mac_size = (rdata[rpos + 8].to_u16 << 8) | rdata[rpos + 9]
      mac_size.must_equal(16) # MD5
      # rdata holds algorithm + time signed (6) + fudge (2) + MAC size (2)
      # + MAC + original id (2) + error (2) + other len (2)
      rdlength.must_equal(rpos + 8 + 2 + mac_size + 6)
    end

    it "signs per algorithm, including the canonical hmac-md5 name" do
      tsig = Krikri::PluginHelpers::NsupdateMessage::Tsig.new("k.", "s".to_slice, "hmac-sha256")
      Krikri::PluginHelpers::NsupdateMessage.hmac(tsig, "data".to_slice).size.must_equal(32)
      tsig = Krikri::PluginHelpers::NsupdateMessage::Tsig.new("k.", "s".to_slice, "HMAC-MD5.SIG-ALG.REG.INT")
      Krikri::PluginHelpers::NsupdateMessage.hmac(tsig, "data".to_slice).size.must_equal(16)
    end
  end
end
