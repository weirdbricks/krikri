require "../minitest_helper"
require "../../src/krikri/plugin_helpers/pem_bundle"

private def cert_block(label : String, body : String) : String
  "-----BEGIN #{label}-----\n#{body}\n-----END #{label}-----"
end

describe Krikri::PluginHelpers::PemBundle do
  describe ".key_first" do
    it "does not treat a certificate whose base64 body contains KEY as a key" do
      cert_body = "Q0VSVElGSUNBVEUgS0VZIERPTU1ZIGRhdGE="
      cert = cert_block("CERTIFICATE", cert_body)
      key = cert_block("PRIVATE KEY", "QUJDREVGR0g=")
      other = cert_block("CERTIFICATE", "T1RIRVIgQ0VSVA==")

      result = Krikri::PluginHelpers::PemBundle.key_first([cert, key, other].join("\n"))
      result.must_equal([key, cert, other].map { |b| b + "\n" }.join)
    end

    it "puts the key first with 1 key + 2 certs in cert-first input" do
      key = cert_block("PRIVATE KEY", "S0VZ")
      cert1 = cert_block("CERTIFICATE", "Q0VSVDEx")
      cert2 = cert_block("CERTIFICATE", "Q0VSVDIy")
      result = Krikri::PluginHelpers::PemBundle.key_first([cert1, cert2, key].join("\n"))
      result.must_equal([key, cert1, cert2].map { |b| b + "\n" }.join)
    end

    it "preserves relative certificate order" do
      key = cert_block("PRIVATE KEY", "S0VZ")
      cert1 = cert_block("CERTIFICATE", "QUFB")
      cert2 = cert_block("CERTIFICATE", "QkJC")
      cert3 = cert_block("CERTIFICATE", "Q0ND")
      result = Krikri::PluginHelpers::PemBundle.key_first([cert3, key, cert1, cert2].join("\n"))
      result.must_equal([key, cert3, cert1, cert2].map { |b| b + "\n" }.join)
    end

    # Compile-time loop: minitest defines each `it` as a method, so the
    # names must be known at macro time.
    {% for label in ["RSA PRIVATE KEY", "EC PRIVATE KEY", "ENCRYPTED PRIVATE KEY", "PRIVATE KEY"] %}
      it {{ "recognizes " + label + " as the key" }} do
        key = cert_block({{ label }}, "S0VZ")
        cert = cert_block("CERTIFICATE", "Q0VSVA==")
        result = Krikri::PluginHelpers::PemBundle.key_first([cert, key].join("\n"))
        result.must_equal([key, cert].map { |b| b + "\n" }.join)
      end
    {% end %}

    it "returns nil when there are no PEM blocks" do
      Krikri::PluginHelpers::PemBundle.key_first("not a pem dump").must_be_nil
      Krikri::PluginHelpers::PemBundle.key_first("").must_be_nil
    end
  end
end
