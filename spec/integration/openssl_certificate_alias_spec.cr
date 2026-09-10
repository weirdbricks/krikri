require "../spec_helper"
require "file_utils"

# community.crypto.openssl_certificate (plus every other spelling real
# roles write: bare, ansible.builtin., ansible.legacy.,
# community.general.) - x509_certificate's old name, resolved through
# MODULE_ALIASES onto the existing x509_certificate plugin binary.
#
# The module itself is covered by x509_certificate_spec.cr; what is
# pinned here is the resolution and dispatch chain end-to-end: a
# role-style three-task play (openssl_privatekey -> openssl_csr ->
# openssl_certificate, all bare names like weareinteractive.openssl
# writes) must run to completion under each spelling - no parse-time
# "uses unimplemented plugin" warning (rc=4), and a real certificate on
# disk at the end. Run before the aliases existed, the third task was
# silently dropped under the bare spelling and hard-stopped under the
# FQCN spellings.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "spec", "fixtures", "inventory-explicit-localhost.ini")
private TMP_DIR      = File.join(PROJECT_ROOT, "spec", "tmp", "openssl_certificate_alias")

%w[
  openssl_certificate
  ansible.builtin.openssl_certificate
  ansible.legacy.openssl_certificate
  community.crypto.openssl_certificate
  community.general.openssl_certificate
].each do |module_name|
  describe "openssl_certificate alias resolution" do
    it "issues a self-signed certificate via `#{module_name}:` end-to-end" do
      FileUtils.rm_rf(TMP_DIR) if Dir.exists?(TMP_DIR)
      Dir.mkdir_p(TMP_DIR)
      key = File.join(TMP_DIR, "server.key")
      csr = File.join(TMP_DIR, "server.csr")
      cert = File.join(TMP_DIR, "server.crt")

      playbook = File.tempname("openssl-cert-alias", ".yml")
      File.write(playbook, <<-YAML)
        - hosts: localhost
          connection: local
          gather_facts: false
          tasks:
            - name: key
              openssl_privatekey:
                path: #{key}
                size: 2048
            - name: csr
              openssl_csr:
                path: #{csr}
                privatekey_path: #{key}
                common_name: alias.example.com
            - name: cert under test
              #{module_name}:
                path: #{cert}
                csr_path: #{csr}
                privatekey_path: #{key}
                provider: selfsigned
        YAML

      captured = IO::Memory.new
      status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: captured, error: captured)
      output = captured.to_s

      status.success?.should be_true, "playbook failed: #{output}"
      output.should_not contain("uses unimplemented plugin: #{module_name}")
      output.should_not contain("unavailable modules")
      File.read(cert).should contain("BEGIN CERTIFICATE")
      `openssl x509 -in #{cert} -noout -subject`.strip.should contain("alias.example.com")
    ensure
      File.delete(playbook) if playbook && File.exists?(playbook)
      FileUtils.rm_rf(TMP_DIR) if Dir.exists?(TMP_DIR)
    end
  end
end
