require "../minitest_helper"
require "../../src/krikri/role_loader"

# ansible-core 2.19 refuses the whole playbook run (rc=1, "[ERROR]:" +
# the file's Origin block on STDERR, no excerpt) when a file a play loads
# is vault-encrypted and no supplied vault secret can open it -
# fogartyp.oraswdb-install's own vault-encrypted vars/main.yml (issue
# #873). role_loader used to let the raw Vault::Error escape, which the
# per-play rescue degraded into "Warning: Failed to parse play N" + "No
# valid plays found in playbook" (rc=4) - output and exit code ansible
# never produces for this.
describe "role file vault decryption failure (role_vault_error_test.cr)" do
  serial!

  it "raises VaultFileError for a vault-encrypted vars/main.yml with no vault password" do
    saved_password = Krikri::Vault.password
    saved_ids = Krikri::Vault.vault_ids.dup
    Krikri::Vault.password = nil
    Krikri::Vault.vault_ids.clear
    begin
      root = PluginSpecHelper.tmp_path("role_vault_error_spec")
      role_dir = File.join(root, "roles", "vaulted_role")
      Dir.mkdir_p(File.join(role_dir, "tasks"))
      Dir.mkdir_p(File.join(role_dir, "vars"))
      File.write(File.join(role_dir, "tasks", "main.yml"), "- name: noop\n  debug:\n    msg: hi\n")
      vars_path = File.join(role_dir, "vars", "main.yml")
      # Header alone is enough: the no-secrets refusal fires before any
      # decrypt attempt, exactly like ansible's VaultLib.decrypt.
      File.write(vars_path, "$ANSIBLE_VAULT;1.1;AES256\n6266346533366131343631343537656633316265336430343938396131313066653562393433623361393162326231613132633765613134623966313730660a383365323435333031383435386237343464653862\n")

      play = Krikri::Play.new("test play", "all")
      roles = YAML.parse("- vaulted_role").as_a
      ex = assert_raises(Krikri::VaultFileError) do
        Krikri::RoleLoader.load_roles(roles, play, root)
      end
      ex.message.must_equal("Attempting to decrypt but no vault secrets found.")
      ex.path.must_equal(vars_path)
      ex.render.must_equal("[ERROR]: Attempting to decrypt but no vault secrets found.\nOrigin: #{File.expand_path(vars_path)}\n\n")
    ensure
      Krikri::Vault.password = nil
      Krikri::Vault.vault_ids.clear
      saved_ids.each { |label, secret| Krikri::Vault.add_vault_id(label, secret) }
      Krikri::Vault.password = saved_password
    end
  end

  it "raises VaultFileError with ansible's decryption-failed message when supplied secrets do not fit" do
    saved_password = Krikri::Vault.password
    saved_ids = Krikri::Vault.vault_ids.dup
    Krikri::Vault.password = nil
    Krikri::Vault.vault_ids.clear
    begin
      root = PluginSpecHelper.tmp_path("role_vault_error_spec_wrongpass")
      role_dir = File.join(root, "roles", "vaulted_role")
      Dir.mkdir_p(File.join(role_dir, "tasks"))
      Dir.mkdir_p(File.join(role_dir, "vars"))
      File.write(File.join(role_dir, "tasks", "main.yml"), "- name: noop\n  debug:\n    msg: hi\n")
      vars_path = File.join(role_dir, "vars", "main.yml")
      File.write(vars_path, Krikri::Vault.encrypt("db_password: supersecret\n", "right"))

      Krikri::Vault.password = "wrong"
      play = Krikri::Play.new("test play", "all")
      roles = YAML.parse("- vaulted_role").as_a
      ex = assert_raises(Krikri::VaultFileError) do
        Krikri::RoleLoader.load_roles(roles, play, root)
      end
      ex.message.must_equal("Decryption failed (no vault secrets were found that could decrypt).")
      ex.path.must_equal(vars_path)
    ensure
      Krikri::Vault.password = nil
      Krikri::Vault.vault_ids.clear
      saved_ids.each { |label, secret| Krikri::Vault.add_vault_id(label, secret) }
      Krikri::Vault.password = saved_password
    end
  end
end
