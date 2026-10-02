require "../minitest_helper"

# Pins plugins/java_cert.cr's keytool probe against real
# community.general.java_cert (live-diffed vs real ansible-playbook
# 2.19.11 in the no-java container): real's test_keytool runs
# module.run_command([executable], check_rc=True) BEFORE any openssl use
# (the openssl get_bin_path resolution is deferred to first use), so a
# missing keytool surfaces the raw run_command OSError shape.
describe "java_cert keytool probe" do
  it "fails a missing keytool with the OSError shape" do
    result = PluginSpecHelper.run("java_cert", {
      "cert_url"      => "https://example.com/cert.pem",
      "keystore_pass" => "secret",
    })

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal("Error executing command.")
    result["rc"].as_i.must_equal(2)
    result["cmd"].as_s.must_equal("keytool")
    result["exception"].as_s.must_equal("[Errno 2] No such file or directory: b'keytool'")
  end

  it "fails a missing executable override with the OSError shape" do
    result = PluginSpecHelper.run("java_cert", {
      "cert_url"      => "https://example.com/cert.pem",
      "keystore_pass" => "secret",
      "executable"    => "/no/such/keytool",
    })

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal("Error executing command.")
    result["exception"].as_s.must_equal("[Errno 2] No such file or directory: b'/no/such/keytool'")
  end
end
