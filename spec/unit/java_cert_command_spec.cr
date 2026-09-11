require "../spec_helper"
require "../../src/krikri/plugin_helpers/java_cert_command"

# Unit-tests the keytool/openssl command lines against real
# community.general.java_cert's own helpers (read from a live
# collection install) - the plugin's execution paths need a JVM and a
# real keystore, the argv shapes don't.
describe Krikri::PluginHelpers::JavaCertCommand do
  describe ".keystore_type_params" do
    it "appends -storetype only when a type is set" do
      Krikri::PluginHelpers::JavaCertCommand.keystore_type_params("JCEKS").should eq(["-storetype", "JCEKS"])
      Krikri::PluginHelpers::JavaCertCommand.keystore_type_params(nil).should eq([] of String)
    end
  end

  describe ".check_cmd" do
    it "dumps the alias as RFC PEM, in the real module's flag order" do
      Krikri::PluginHelpers::JavaCertCommand.check_cmd("keytool", "/etc/ssl/cacerts", "example.com", nil)
        .should eq("keytool -list -keystore /etc/ssl/cacerts -alias example.com -rfc")
      Krikri::PluginHelpers::JavaCertCommand.check_cmd("keytool", "/etc/ssl/cacerts", "example.com", "JCEKS")
        .should eq("keytool -list -keystore /etc/ssl/cacerts -alias example.com -rfc -storetype JCEKS")
    end
  end

  describe ".delete_cmd" do
    it "deletes by alias with -noprompt" do
      Krikri::PluginHelpers::JavaCertCommand.delete_cmd("keytool", "/etc/ssl/cacerts", "example.com", nil)
        .should eq("keytool -delete -noprompt -keystore /etc/ssl/cacerts -alias example.com")
    end
  end

  describe ".import_cert_cmd" do
    it "builds the -importcert command, with -trustcacerts only when asked" do
      Krikri::PluginHelpers::JavaCertCommand.import_cert_cmd("keytool", "/tmp/cert.pem", "/etc/ssl/cacerts", "example.com", nil, false)
        .should eq("keytool -importcert -noprompt -keystore /etc/ssl/cacerts -file /tmp/cert.pem -alias example.com")
      Krikri::PluginHelpers::JavaCertCommand.import_cert_cmd("keytool", "/tmp/cert.pem", "/etc/ssl/cacerts", "example.com", "JKS", true)
        .should eq("keytool -importcert -noprompt -keystore /etc/ssl/cacerts -file /tmp/cert.pem -alias example.com -storetype JKS -trustcacerts")
    end
  end

  describe ".import_pkcs12_cmd" do
    it "builds the -importkeystore command with optional aliases" do
      Krikri::PluginHelpers::JavaCertCommand.import_pkcs12_cmd("keytool", "/tmp/site.p12", "1", "/etc/ssl/cacerts", "example.com", nil)
        .should eq("keytool -importkeystore -noprompt -srcstoretype pkcs12 -srckeystore /tmp/site.p12 -destkeystore /etc/ssl/cacerts -destalias example.com -srcalias 1")
    end
  end

  describe ".export_pkcs12_cmd / .fetch_url_cmd" do
    it "builds the PKCS12 PEM export command" do
      Krikri::PluginHelpers::JavaCertCommand.export_pkcs12_cmd("keytool", "/tmp/site.p12", nil)
        .should eq("keytool -list -noprompt -keystore /tmp/site.p12 -storetype pkcs12 -rfc")
    end

    it "builds the -printcert TLS fetch command with proxy options" do
      Krikri::PluginHelpers::JavaCertCommand.fetch_url_cmd("keytool", "example.com", 8443,
        ["-J-Dhttps.proxyHost=proxy", "-J-Dhttps.proxyPort=3128"])
        .should eq("keytool -printcert -rfc -sslserver -J-Dhttps.proxyHost=proxy -J-Dhttps.proxyPort=3128 example.com:8443")
    end
  end

  describe ".extract_x509_cmd / .dgst_cmd" do
    it "builds the openssl extract (PEM and DER fallback) and sha256 commands" do
      Krikri::PluginHelpers::JavaCertCommand.extract_x509_cmd("openssl", "/tmp/c.pem", "/tmp/o.pem")
        .should eq("openssl x509 -in /tmp/c.pem -out /tmp/o.pem")
      Krikri::PluginHelpers::JavaCertCommand.extract_x509_cmd("openssl", "/tmp/c.pem", "/tmp/o.pem", der_fallback: true)
        .should eq("openssl x509 -in /tmp/c.pem -out /tmp/o.pem -inform der")
      Krikri::PluginHelpers::JavaCertCommand.dgst_cmd("openssl", "/tmp/o.pem")
        .should eq("openssl dgst -r -sha256 /tmp/o.pem")
    end
  end

  describe ".proxy_opts" do
    it "builds JVM proxy flags from https_proxy/no_proxy" do
      Krikri::PluginHelpers::JavaCertCommand.proxy_opts("http://proxy:3128", nil)
        .should eq(["-J-Dhttps.proxyHost=proxy", "-J-Dhttps.proxyPort=3128"])
      Krikri::PluginHelpers::JavaCertCommand.proxy_opts("proxy:3128", ".internal,.corp")
        .should eq(["-J-Dhttps.proxyHost=proxy", "-J-Dhttps.proxyPort=3128", "-J-Dhttp.nonProxyHosts=*.internal|*.corp"])
      Krikri::PluginHelpers::JavaCertCommand.proxy_opts(nil, nil).should eq([] of String)
    end
  end

  describe ".with_stdin" do
    it "feeds each data string as one stdin line, shell-quoted" do
      Krikri::PluginHelpers::JavaCertCommand.with_stdin("keytool -list", ["pass"])
        .should eq("printf '%s\\n' 'pass' | keytool -list")
      Krikri::PluginHelpers::JavaCertCommand.with_stdin("keytool -importcert", ["pass", "pass"])
        .should eq("printf '%s\\n' 'pass' 'pass' | keytool -importcert")
    end
  end
end
