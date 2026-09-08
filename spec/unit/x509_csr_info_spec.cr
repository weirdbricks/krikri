require "../spec_helper"
require "file_utils"
require "../../src/krikri/plugin_helpers/x509_cert_info"

# The last two community.crypto *_info modules the KNOWN_MISSING.md
# deliberate-limits entry called "read-only and cheap": both result
# shapes are mirrored against real community.crypto 3.1.1 (probed live
# with ansible-playbook on this host), the same way the certificate
# half (X509CertInfo.parse) was differentialed.
private def generate_fixture(dir : String) : Nil
  req_args = ["req", "-new", "-newkey", "rsa:2048", "-nodes",
              "-keyout", File.join(dir, "key.pem"),
              "-out", File.join(dir, "req.csr"),
              "-subj", "/CN=example.com/O=Test Org",
              "-addext", "subjectAltName=DNS:example.com,DNS:www.example.com,IP:1.2.3.4",
              "-addext", "keyUsage=digitalSignature,keyEncipherment",
              "-addext", "basicConstraints=CA:FALSE"]
  Process.run("openssl", req_args, output: IO::Memory.new, error: IO::Memory.new)
  Process.run("openssl", ["rsa", "-in", File.join(dir, "key.pem"), "-pubout", "-out", File.join(dir, "pub.pem")], output: IO::Memory.new, error: IO::Memory.new)
end

describe Krikri::X509CertInfo do
  fixture = File.join(Dir.tempdir, "krikri-csrinfo-#{Random.rand(1_000_000)}")
  Dir.mkdir_p(fixture)
  generate_fixture(fixture)

  csr_result = File.read(File.join(fixture, "req.csr")).try do |pem|
    Krikri::X509CertInfo.parse_csr(pem)
  end
  raise "CSR fixture unparseable" unless csr_result
  result = csr_result

  it "parses the subject in cryptography's long-name vocabulary" do
    result["subject"].as_h["commonName"].as_s.should eq("example.com")
    result["subject"].as_h["organizationName"].as_s.should eq("Test Org")
    result["subject_ordered"].as_a[0].as_a[0].as_s.should eq("commonName")
  end

  it "reports the requested extensions" do
    result["basic_constraints"].as_a.map(&.as_s).should eq(["CA:FALSE"])
    result["basic_constraints_critical"].as_bool.should be_false
    result["key_usage"].as_a.map(&.as_s).should eq(["Digital Signature", "Key Encipherment"])
    result["subject_alt_name"].as_a.map(&.as_s)
      .should eq(["DNS:example.com", "DNS:www.example.com", "IP:1.2.3.4"])
  end

  it "always carries the extension keys, None when the extension is absent" do
    # the real backend's getters return (None, False) for every
    # extension the request does not carry
    result["extended_key_usage"].raw.should be_nil
    result["extended_key_usage_critical"].as_bool.should be_false
    result["ocsp_must_staple"].raw.should be_nil
    result["ocsp_must_staple_critical"].as_bool.should be_false
  end

  it "reports the public key shape under the csr_info field names" do
    result["public_key_type"].as_s.should eq("RSA")
    data = result["public_key_data"].as_h
    data["size"].as_i.should eq(2048)
    data["exponent"].as_i.should eq(65537)
    result["public_key"].as_s.should contain("-----BEGIN PUBLIC KEY-----")
    fingerprints = result["public_key_fingerprints"].as_h
    fingerprints["sha256"].as_s.should match(/\A([0-9a-f]{2}:){31}[0-9a-f]{2}\z/)
  end

  it "validates the request's self-signature" do
    result["signature_valid"].as_bool.should be_true
  end

  it "detects a tampered request as signature-invalid" do
    # the PEM payload is base64 (the subject text never appears
    # literally), so flip a payload character to break the signature
    req = File.read(File.join(fixture, "req.csr"))
    first_line_end = req.index("
") || raise "no newline in fixture"
    payload_start = (req.index("
", first_line_end + 1) || raise "no payload in fixture") + 1
    bytes = req.to_slice.dup
    flip = bytes[payload_start] == 'A'.ord ? 'B'.ord : 'A'.ord
    bytes[payload_start] = flip.to_u8
    tampered = String.new(bytes)
    parsed = Krikri::X509CertInfo.parse_csr(tampered)
    raise "tampered fixture unparseable" unless parsed
    parsed["signature_valid"].as_bool.should be_false
  end

  # describe-body code runs at collection time, so the fixture must
  # outlive the examples - cleaned up after the whole suite
  Spec.after_suite do
    FileUtils.rm_r(fixture) if Dir.exists?(fixture)
  end
end
