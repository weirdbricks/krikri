require "../minitest_helper"
require "../../src/krikri/task_executor"
require "../../src/krikri/vault"

# Regression spec for the KNOWN_MISSING.md open gap "copy: never
# auto-decrypts a vault-encrypted src:": real Ansible's copy: decrypt:
# param (default true) transparently decodes a vault-armored src file on
# the CONTROLLER before transfer, but krikri's controller-side read
# (TaskExecutor#inline_copy_source_content) uploaded the ciphertext
# verbatim - krikri's effective behavior equaled real Ansible's
# decrypt: false for every run.
#
# The private method is exercised through a subclass (Crystal private
# methods are callable from subclasses via the implicit receiver), the
# same probe pattern copy_binary_source_staging_spec.cr uses. The vault
# crypto itself is spec'd in spec/unit/vault_spec.cr - this only covers
# the wiring: inline_copy_source_content must actually call
# Vault.maybe_decrypt, honor decrypt: false, and fail with Vault::Error
# when no usable password is configured.
private class InlineCopyVaultProbeExecutor < Krikri::TaskExecutor
  def probe(task, params, host, vars_context)
    inline_copy_source_content(task, params, host, vars_context)
  end
end

describe "copy: vault-encrypted src is decrypted on the controller" do
  # Vault password/vault_ids are engine-global state; with_vault holds
  # STATE_MUTEX and always starts and ends from a clean slate.
  it "inlines the decrypted plaintext as content: (decrypt: true default)" do
    with_vault do
      src = File.tempname("copy-vault-src-spec")
      begin
        ciphertext = Krikri::Vault.encrypt("secret key material\n", "spec-vault-pass")
        File.write(src, ciphertext)

        task = Krikri::Task.new("Copy vaulted key", "ansible.builtin.copy")
        host = Krikri::Host.new("unreachable-spec-host", "root", 1)
        params = {"src" => src, "dest" => "/etc/spec-secret.conf", "mode" => "0600"}

        Krikri::Vault.password = "spec-vault-pass"
        resolved = InlineCopyVaultProbeExecutor.new([host] of Krikri::Host, [task] of Krikri::Task)
          .probe(task, params, host, {} of String => JSON::Any)

        resolved["content"]?.must_equal("secret key material\n")
        resolved["content"]?.wont_equal(ciphertext)
        resolved["src"]?.must_be_nil
        resolved["__original_src_basename"]?.must_equal(File.basename(src))
      ensure
        File.delete(src) if src && File.exists?(src)
      end
    end
  end

  it "keeps the ciphertext when decrypt: false is set explicitly" do
    with_vault do
      src = File.tempname("copy-vault-nodecrypt-src-spec")
      begin
        ciphertext = Krikri::Vault.encrypt("secret key material\n", "spec-vault-pass")
        File.write(src, ciphertext)

        task = Krikri::Task.new("Copy vaulted key", "ansible.builtin.copy")
        host = Krikri::Host.new("unreachable-spec-host", "root", 1)
        params = {"src" => src, "dest" => "/etc/spec-secret.conf", "decrypt" => "false"}

        Krikri::Vault.password = "spec-vault-pass"
        resolved = InlineCopyVaultProbeExecutor.new([host] of Krikri::Host, [task] of Krikri::Task)
          .probe(task, params, host, {} of String => JSON::Any)

        resolved["content"]?.must_equal(ciphertext)
      ensure
        File.delete(src) if src && File.exists?(src)
      end
    end
  end

  it "raises Vault::Error when no vault password is configured" do
    with_vault do
      src = File.tempname("copy-vault-nopass-src-spec")
      begin
        File.write(src, Krikri::Vault.encrypt("secret key material\n", "spec-vault-pass"))

        task = Krikri::Task.new("Copy vaulted key", "ansible.builtin.copy")
        host = Krikri::Host.new("unreachable-spec-host", "root", 1)
        params = {"src" => src, "dest" => "/etc/spec-secret.conf"}

        Krikri::Vault.password = nil
        assert_raises(Krikri::Vault::Error) do
          InlineCopyVaultProbeExecutor.new([host] of Krikri::Host, [task] of Krikri::Task)
            .probe(task, params, host, {} of String => JSON::Any)
        end
      ensure
        File.delete(src) if src && File.exists?(src)
      end
    end
  end
end
