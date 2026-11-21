require "../minitest_helper"

# Pins plugins/get_certificate.cr's argument-validation surface against
# real community.crypto.get_certificate's AnsibleModule setup
# (source-verified against the collection's get_certificate.py; live-diffed
# vs ansible-playbook via the podman-diff get_certificate_edge_cases
# harness):
#
# - host and port are the only required params; no required_if/together
# - the Ansible module has NO path/output-file params (a prior revision here
#   invented them) - path et al. are unsupported params
# - port/proxy_port/timeout are ints, asn1_base64/get_certificate_chain
#   are bools (spec declaration order)
# - select_crypto_backend (auto/cryptography) and starttls (mysql) choices
describe "get_certificate plugin argument validation" do
  it "fails without host and port" do
    result = PluginSpecHelper.run("get_certificate", {} of String => String)

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal("missing required arguments: host, port")
  end

  it "fails without port" do
    result = PluginSpecHelper.run("get_certificate", {"host" => "127.0.0.1"})

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal("missing required arguments: port")
  end

  it "rejects the invented path parameter as unsupported" do
    result = PluginSpecHelper.run("get_certificate", {
      "host" => "127.0.0.1",
      "port" => "443",
      "path" => "/tmp/cert.pem",
    })

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal(
      "Unsupported parameters for (community.crypto.get_certificate) module: path. " \
      "Supported parameters include: asn1_base64, ca_cert, ciphers, get_certificate_chain, host, port, " \
      "proxy_host, proxy_port, select_crypto_backend, server_name, starttls, timeout, tls_ctx_options.")
  end

  it "fails a non-integer port" do
    result = PluginSpecHelper.run("get_certificate", {"host" => "127.0.0.1", "port" => "banana"})

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal("argument 'port' is of type str and we were unable to convert to int: \"'banana'\" cannot be converted to an int")
  end

  it "fails a non-boolean get_certificate_chain" do
    result = PluginSpecHelper.run("get_certificate", {"host" => "127.0.0.1", "port" => "443", "get_certificate_chain" => "banana"})

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_include("argument 'get_certificate_chain' is of type str and we were unable to convert to bool: " \
                                    "The value 'banana' is not a valid boolean. Valid booleans include: ")
  end

  it "fails an invalid starttls choice" do
    result = PluginSpecHelper.run("get_certificate", {"host" => "127.0.0.1", "port" => "443", "starttls" => "banana"})

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal("value of starttls must be one of: mysql, got: banana")
  end

  it "fails an invalid select_crypto_backend choice" do
    result = PluginSpecHelper.run("get_certificate", {"host" => "127.0.0.1", "port" => "443", "select_crypto_backend" => "banana"})

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal("value of select_crypto_backend must be one of: auto, cryptography, got: banana")
  end

  # get_certificate.py declares no supports_check_mode, so basic.py skips
  # the task under --check instead of connecting (kpg issue #1312: the
  # plugin used to dial out, fail on the unresolvable host, and register a
  # failed result where ansible had a skip).
  it "skips in check mode like a module without supports_check_mode" do
    result = PluginSpecHelper.run("get_certificate", {
      "host"                => "acmaxz",
      "port"                => "41",
      "timeout"             => "8",
      "_ansible_check_mode" => "true",
    })

    result["skipped"].as_bool.must_equal(true)
    # The module's wire dict carries only exit_json's own kwargs; the
    # controller backfills changed/failed (registered order
    # changed, failed, skipped, msg, live-verified vs 2.21.6).
    result.as_h.keys.must_equal(["skipped", "msg"])
    result["msg"].as_s.must_equal("remote module (community.crypto.get_certificate) does not support check mode")
  end

  # basic.py's gate sits after argument validation, so a bad arg still
  # fails (live-verified vs 2.21.6 under --check).
  it "validates arguments before the check-mode skip" do
    result = PluginSpecHelper.run("get_certificate", {
      "host"                => "acmaxz",
      "_ansible_check_mode" => "true",
    })

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal("missing required arguments: port")
  end

  # The skip also wins over the ca_cert existence check, because that check
  # lives in the module body ansible never runs under --check (kpg issue
  # #1314: a missing ca_cert used to fail the task instead of skipping it,
  # flipping a following `when: r is succeeded` gate).
  it "skips in check mode before the missing ca_cert error" do
    result = PluginSpecHelper.run("get_certificate", {
      "host"                => "127.0.0.1",
      "port"                => "443",
      "ca_cert"             => "/tmp/krikri-get-certificate-check-mode-missing.pem",
      "_ansible_check_mode" => "true",
    })

    result.as_h.keys.must_equal(["skipped", "msg"])
    result["msg"].as_s.must_equal("remote module (community.crypto.get_certificate) does not support check mode")
  end
end
