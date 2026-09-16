require "../spec_helper"

# Pins plugins/get_certificate.cr's argument-validation surface against
# real community.crypto.get_certificate's AnsibleModule setup
# (source-verified against the collection's get_certificate.py; live-diffed
# vs real ansible-playbook via the podman-diff get_certificate_edge_cases
# harness):
#
# - host and port are the only required params; no required_if/together
# - the real module has NO path/output-file params (a prior revision here
#   invented them) - path et al. are unsupported params
# - port/proxy_port/timeout are ints, asn1_base64/get_certificate_chain
#   are bools (spec declaration order)
# - select_crypto_backend (auto/cryptography) and starttls (mysql) choices
describe "get_certificate plugin argument validation" do
  it "fails without host and port" do
    result = PluginSpecHelper.run("get_certificate", {} of String => String)

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should eq("missing required arguments: host, port")
  end

  it "fails without port" do
    result = PluginSpecHelper.run("get_certificate", {"host" => "127.0.0.1"})

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should eq("missing required arguments: port")
  end

  it "rejects the invented path parameter as unsupported" do
    result = PluginSpecHelper.run("get_certificate", {
      "host" => "127.0.0.1",
      "port" => "443",
      "path" => "/tmp/cert.pem",
    })

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should eq(
      "Unsupported parameters for (community.crypto.get_certificate) module: path. " \
      "Supported parameters include: asn1_base64, ca_cert, ciphers, get_certificate_chain, host, port, " \
      "proxy_host, proxy_port, select_crypto_backend, server_name, starttls, timeout, tls_ctx_options.")
  end

  it "fails a non-integer port" do
    result = PluginSpecHelper.run("get_certificate", {"host" => "127.0.0.1", "port" => "banana"})

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should eq("argument 'port' is of type <class 'str'> and we were unable to convert to int: <class 'str'> cannot be converted to an int")
  end

  it "fails a non-boolean get_certificate_chain" do
    result = PluginSpecHelper.run("get_certificate", {"host" => "127.0.0.1", "port" => "443", "get_certificate_chain" => "banana"})

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should contain("argument 'get_certificate_chain' is of type <class 'str'> and we were unable to convert to bool: " \
                                      "The value 'banana' is not a valid boolean.  Valid booleans include: ")
  end

  it "fails an invalid starttls choice" do
    result = PluginSpecHelper.run("get_certificate", {"host" => "127.0.0.1", "port" => "443", "starttls" => "banana"})

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should eq("value of starttls must be one of: mysql, got: banana")
  end

  it "fails an invalid select_crypto_backend choice" do
    result = PluginSpecHelper.run("get_certificate", {"host" => "127.0.0.1", "port" => "443", "select_crypto_backend" => "banana"})

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should eq("value of select_crypto_backend must be one of: auto, cryptography, got: banana")
  end
end
