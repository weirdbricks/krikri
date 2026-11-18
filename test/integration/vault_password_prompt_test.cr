require "file_utils"
require "../minitest_helper"

# Vault command-line password handling. Expected output is live-verified
# against ansible-core 2.21.6, which loads every vault secret before any
# play/file is read:
#
# - it prompts through Python's getpass, so a password piped into
#   --ask-vault-pass (a wrapper/CI job) is read from stdin with a
#   "Warning: Password input may be echoed." note and no stty call at all;
# - a secret it cannot load is fatal before the play starts: a [WARNING]
#   naming the source, the same text as [ERROR], exit 1 - never a later
#   decryption failure rendered as "Unknown error.".
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")

private VAULT_PASSWORD = "vault-pw-test"

private def run_vaulted_play(args : Array(String), stdin : String = "")
  dir = File.tempname("vault-pw-prompt")
  Dir.mkdir_p(dir)
  File.write(File.join(dir, "inv.ini"), "host1 ansible_connection=local\n")
  File.write(File.join(dir, "pw"), "#{VAULT_PASSWORD}\n")
  File.write(File.join(dir, "enc.yml"), "secret_val: abc123\n")
  Process.run(BINARY, ["vault", "encrypt", "--vault-password-file", "pw", "enc.yml"],
    output: Process::Redirect::Close, error: Process::Redirect::Close, chdir: dir)
  File.write(File.join(dir, "p.yml"), <<-YAML)
    - hosts: all
      gather_facts: false
      tasks:
        - ansible.builtin.include_vars: enc.yml
        - ansible.builtin.debug: {msg: "{{ secret_val }}"}
    YAML

  output = IO::Memory.new
  status = Process.run(BINARY, ["-i", "inv.ini"] + args + ["p.yml"],
    input: IO::Memory.new(stdin), output: output, error: output, chdir: dir)
  {status.exit_code, output.to_s}
ensure
  FileUtils.rm_rf(dir) if dir && Dir.exists?(dir)
end

describe "vault password prompt without a terminal" do
  it "reads the password piped into --ask-vault-pass and never runs stty" do
    code, output = run_vaulted_play(["--ask-vault-pass"], "#{VAULT_PASSWORD}\n")
    code.must_equal(0)
    output.must_include("abc123")
    output.must_include("Warning: Password input may be echoed.")
    output.wont_include("stty")
    output.scan("Vault password").size.must_equal(1)
  end

  it "prompts once for --vault-id LABEL@prompt and reads the piped password" do
    code, output = run_vaulted_play(["--vault-id", "dev@prompt"], "#{VAULT_PASSWORD}\n")
    code.must_equal(0)
    output.must_include("abc123")
    output.must_include("Vault password (dev): ")
    output.scan("Vault password").size.must_equal(1)
  end
end

describe "vault password loading errors" do
  it "rejects an empty --vault-password-file before the play runs" do
    code, output = run_vaulted_play(["--vault-password-file", "/dev/null"])
    code.must_equal(1)
    output.must_include("[WARNING]: Error in vault password file loading (default): Invalid vault password was provided from file (/dev/null)")
    output.must_include("[ERROR]: Invalid vault password was provided from file (/dev/null)")
    output.wont_include("PLAY [")
  end

  it "names the vault id when an empty --vault-id password file is rejected" do
    code, output = run_vaulted_play(["--vault-id", "dev@/dev/null"])
    code.must_equal(1)
    output.must_include("[WARNING]: Error in vault password file loading (dev): Invalid vault password was provided from file (/dev/null)")
    output.must_include("[ERROR]: Invalid vault password was provided from file (/dev/null)")
    output.wont_include("PLAY [")
  end

  it "reports a missing vault password file instead of raising" do
    code, output = run_vaulted_play(["--vault-password-file", "/nonexistent/krikri-vault-password.txt"])
    code.must_equal(1)
    output.must_include("[WARNING]: Error getting vault password file (default): The vault password file /nonexistent/krikri-vault-password.txt was not found")
    output.must_include("[ERROR]: The vault password file /nonexistent/krikri-vault-password.txt was not found")
    output.wont_include("PLAY [")
  end

  it "rejects an empty password read from the --ask-vault-pass prompt" do
    code, output = run_vaulted_play(["--ask-vault-pass"], "\n")
    code.must_equal(1)
    output.must_include("[WARNING]: Error in vault password prompt (default): Invalid vault password was provided")
    output.must_include("[ERROR]: Invalid vault password was provided")
    output.wont_include("PLAY [")
  end

  it "reports EOF on the --ask-vault-pass prompt" do
    code, output = run_vaulted_play(["--ask-vault-pass"], "")
    code.must_equal(1)
    output.must_include("[WARNING]: Error in vault password prompt (default): EOFError (ctrl-d) on prompt for (default)")
    output.must_include("[ERROR]: EOFError (ctrl-d) on prompt for (default)")
    output.wont_include("PLAY [")
  end
end
