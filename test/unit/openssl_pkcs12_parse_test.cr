require "../minitest_helper"

# Pins plugins/openssl_pkcs12.cr's native libcrypto parse (action=parse)
# and the backend constructor's eager file reads against real
# community.crypto.openssl_pkcs12 (live-diffed vs ansible-playbook
# 2.19.11):
#
# - the parse action dumps the private key first, then the certificates
# - PKCS#12 data that cannot be deserialized (corrupt file, wrong
#   passphrase) fails with the exact "Could not deserialize PKCS12 data"
# - a missing certificate_path/privatekey_path surfaces the UNHANDLED
#   OSError chain before anything else, in every state
describe "openssl_pkcs12 native parse" do
  it "dumps the private key first, then the certificates" do
    work = PluginSpecHelper.tmp_path("pkcs12-parse")
    Dir.mkdir_p(work)

    key = File.join(work, "key.pem")
    cert = File.join(work, "cert.pem")
    p12 = File.join(work, "bundle.p12")
    out_path = File.join(work, "out.pem")
    run = Process.run("sh", {"-c", "openssl req -x509 -newkey rsa:2048 -keyout '#{key}' -nodes -out '#{cert}' -days 1 -subj '/CN=krikri-test' 2>/dev/null && openssl pkcs12 -export -in '#{cert}' -inkey '#{key}' -out '#{p12}' -passout pass:secret"})
    run.success?.must_equal(true)

    result = PluginSpecHelper.run("openssl_pkcs12", {
      "action"     => "parse",
      "src"        => p12,
      "path"       => out_path,
      "passphrase" => "secret",
    })
    result["changed"].as_bool.must_equal(true)
    pem = File.read(out_path)
    pem.must_include("-----BEGIN PRIVATE KEY-----")
    key_idx = pem.index("-----BEGIN PRIVATE KEY-----")
    cert_idx = pem.index("-----BEGIN CERTIFICATE-----")
    assert(key_idx && cert_idx && key_idx < cert_idx)
  end

  it "fails a corrupt archive with the exact deserialize message" do
    work = PluginSpecHelper.tmp_path("pkcs12-corrupt")
    Dir.mkdir_p(work)
    p12 = File.join(work, "bad.p12")
    File.write(p12, "garbage")

    result = PluginSpecHelper.run("openssl_pkcs12", {
      "action" => "parse",
      "src"    => p12,
      "path"   => File.join(work, "out.pem"),
    })
    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal("Could not deserialize PKCS12 data")
  end

  it "fails a wrong passphrase with the exact deserialize message" do
    work = PluginSpecHelper.tmp_path("pkcs12-passphrase")
    Dir.mkdir_p(work)
    key = File.join(work, "key.pem")
    cert = File.join(work, "cert.pem")
    p12 = File.join(work, "bundle.p12")
    run = Process.run("sh", {"-c", "openssl req -x509 -newkey rsa:2048 -keyout '#{key}' -nodes -out '#{cert}' -days 1 -subj '/CN=krikri-test' 2>/dev/null && openssl pkcs12 -export -in '#{cert}' -inkey '#{key}' -out '#{p12}' -passout pass:secret"})
    run.success?.must_equal(true)

    result = PluginSpecHelper.run("openssl_pkcs12", {
      "action"     => "parse",
      "src"        => p12,
      "path"       => File.join(work, "out.pem"),
      "passphrase" => "wrong",
    })
    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal("Could not deserialize PKCS12 data")
  end

  it "reads the certificate input eagerly, before the state dispatch" do
    work = PluginSpecHelper.tmp_path("pkcs12-eager")
    Dir.mkdir_p(work)
    missing = File.join(work, "nope.pem")

    result = PluginSpecHelper.run("openssl_pkcs12", {
      "state"            => "absent",
      "path"             => File.join(work, "out.p12"),
      "certificate_path" => missing,
    })
    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal("Task failed: Module failed: [Errno 2] No such file or directory: '#{missing}'")
  end
end
