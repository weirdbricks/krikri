require "../spec_helper"

# java_cert's parameter-validation failures, exercised before anything
# shells out. Actually importing/removing certificates mutates a real
# Java keystore and needs a JVM (keytool); that belongs to the live
# benchmark rounds.
describe "java_cert plugin" do
  it "fails when keystore_pass is missing" do
    result = PluginSpecHelper.run("java_cert", {"cert_path" => "/tmp/x.pem", "cert_alias" => "x", "keystore_path" => "/tmp/ks"})

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should contain("keystore_pass")
  end

  it "fails when state=present has no certificate source" do
    result = PluginSpecHelper.run("java_cert", {"keystore_path" => "/tmp/ks", "keystore_pass" => "pw"})

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should contain("cert_path")
  end

  it "fails when certificate sources are mutually exclusive" do
    result = PluginSpecHelper.run("java_cert", {
      "cert_path"     => "/tmp/x.pem",
      "cert_url"      => "example.com",
      "cert_alias"    => "x",
      "keystore_path" => "/tmp/ks",
      "keystore_pass" => "pw",
    })

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should contain("mutually exclusive")
  end

  it "fails on an invalid state" do
    result = PluginSpecHelper.run("java_cert", {
      "cert_path"     => "/tmp/x.pem",
      "cert_alias"    => "x",
      "keystore_path" => "/tmp/ks",
      "keystore_pass" => "pw",
      "state"         => "bogus",
    })

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should contain("state")
  end

  it "fails when cert_path is used without an alias" do
    result = PluginSpecHelper.run("java_cert", {
      "cert_path"     => "/tmp/x.pem",
      "keystore_path" => "/tmp/ks",
      "keystore_pass" => "pw",
    })

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should contain("requires alias argument")
  end

  it "fails when keytool is not installed", tags: "needs_keytool" do
    result = PluginSpecHelper.run("java_cert", {
      "cert_path"     => "/tmp/x.pem",
      "cert_alias"    => "x",
      "keystore_path" => "/tmp/ks",
      "keystore_pass" => "pw",
    })

    next if system("command -v keytool >/dev/null")

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should contain("keytool")
  end
end
