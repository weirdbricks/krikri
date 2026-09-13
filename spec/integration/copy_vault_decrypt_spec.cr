require "../spec_helper"
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
  it "inlines the decrypted plaintext as content: (decrypt: true default)" do
    src = File.tempname("copy-vault-src-spec")
    ciphertext = Krikri::Vault.encrypt("secret key material\n", "spec-vault-pass")
    File.write(src, ciphertext)

    task = Krikri::Task.new("Copy vaulted key", "ansible.builtin.copy")
    host = Krikri::Host.new("unreachable-spec-host", "root", 1)
    params = {"src" => src, "dest" => "/etc/spec-secret.conf", "mode" => "0600"}

    Krikri::Vault.password = "spec-vault-pass"
    resolved = InlineCopyVaultProbeExecutor.new([host] of Krikri::Host, [task] of Krikri::Task)
      .probe(task, params, host, {} of String => JSON::Any)

    resolved["content"]?.should eq("secret key material\n")
    resolved["content"]?.should_not eq(ciphertext)
    resolved["src"]?.should be_nil
    resolved["__original_src_basename"]?.should eq(File.basename(src))
  ensure
    Krikri::Vault.password = nil
    File.delete(src) if src && File.exists?(src)
  end

  it "keeps the ciphertext when decrypt: false is set explicitly" do
    src = File.tempname("copy-vault-nodecrypt-src-spec")
    ciphertext = Krikri::Vault.encrypt("secret key material\n", "spec-vault-pass")
    File.write(src, ciphertext)

    task = Krikri::Task.new("Copy vaulted key", "ansible.builtin.copy")
    host = Krikri::Host.new("unreachable-spec-host", "root", 1)
    params = {"src" => src, "dest" => "/etc/spec-secret.conf", "decrypt" => "false"}

    Krikri::Vault.password = "spec-vault-pass"
    resolved = InlineCopyVaultProbeExecutor.new([host] of Krikri::Host, [task] of Krikri::Task)
      .probe(task, params, host, {} of String => JSON::Any)

    resolved["content"]?.should eq(ciphertext)
  ensure
    Krikri::Vault.password = nil
    File.delete(src) if src && File.exists?(src)
  end

  it "raises Vault::Error when no vault password is configured" do
    src = File.tempname("copy-vault-nopass-src-spec")
    File.write(src, Krikri::Vault.encrypt("secret key material\n", "spec-vault-pass"))

    task = Krikri::Task.new("Copy vaulted key", "ansible.builtin.copy")
    host = Krikri::Host.new("unreachable-spec-host", "root", 1)
    params = {"src" => src, "dest" => "/etc/spec-secret.conf"}

    Krikri::Vault.password = nil
    expect_raises(Krikri::Vault::Error) do
      InlineCopyVaultProbeExecutor.new([host] of Krikri::Host, [task] of Krikri::Task)
        .probe(task, params, host, {} of String => JSON::Any)
    end
  ensure
    Krikri::Vault.password = nil
    File.delete(src) if src && File.exists?(src)
  end
end
