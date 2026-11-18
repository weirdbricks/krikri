require "../minitest_helper"
require "file_utils"

# `group_vars/` and `host_vars/` files are vault-decrypted by ansible's
# inventory var loader just like every other vars source. Before issue
# #1462 an encrypted file there parsed as a bare YAML string, contributed
# no vars at all, and the run carried on with every name it defined
# undefined. Expectations below come from ansible-core 2.21.6.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")

# `secret_val: abc123`, encrypted with the password `vault-pw-test`
# (`ansible-vault encrypt`).
private ENCRYPTED_VARS_FILE = <<-VAULT
  $ANSIBLE_VAULT;1.1;AES256
  39363736613437633630366563653262323438303566633165646363333662306363616139306562
  6138613664333936666165666433666165643537363963390a373735666464393262636462373434
  32306437343765333133356361396230393430313836616236643934373433643163346666306333
  3637613230376530610a343531623363623739383237306161316563396437303238626133373232
  61343364376438323064393031306334633564633933366338666637666531636337
  VAULT

private PLAYBOOK = <<-YAML
  - hosts: all
    gather_facts: false
    tasks:
      - ansible.builtin.debug: {msg: "secret_val={{ secret_val | default('UNDEF') }}"}
  YAML

private def with_workspace(prefix : String, & : String -> Nil) : Nil
  workspace = File.tempname(prefix, ".d")
  Dir.mkdir_p(workspace)
  File.write(File.join(workspace, "inv.ini"), "[all]\nhost1 ansible_connection=local\n")
  yield workspace
ensure
  FileUtils.rm_rf(workspace) if workspace
end

private def run_playbook(workspace : String, password : String?, extra_args : Array(String) = [] of String) : {Process::Status, String}
  args = ["-i", File.join(workspace, "inv.ini"), File.join(workspace, "play.yml")]
  if pw = password
    File.write(File.join(workspace, "pw"), "#{pw}\n")
    args += ["--vault-password-file", File.join(workspace, "pw")]
  end
  args.concat(extra_args)

  output = IO::Memory.new
  status = Process.run(BINARY, args, output: output, error: output)
  {status, output.to_s}
end

private def write_group_vars(workspace : String) : Nil
  Dir.mkdir_p(File.join(workspace, "group_vars"))
  File.write(File.join(workspace, "group_vars", "all.yml"), ENCRYPTED_VARS_FILE)
  File.write(File.join(workspace, "play.yml"), PLAYBOOK)
end

describe "vault-encrypted inventory vars" do
  it "decrypts a whole vault-armored group_vars file" do
    with_workspace("vault-group-vars") do |workspace|
      write_group_vars(workspace)

      status, output = run_playbook(workspace, "vault-pw-test")

      status.exit_code.must_equal(0)
      output.must_include("secret_val=abc123")
    end
  end

  it "decrypts a whole vault-armored host_vars file" do
    with_workspace("vault-host-vars") do |workspace|
      Dir.mkdir_p(File.join(workspace, "host_vars"))
      File.write(File.join(workspace, "host_vars", "host1.yml"), ENCRYPTED_VARS_FILE)
      File.write(File.join(workspace, "play.yml"), PLAYBOOK)

      status, output = run_playbook(workspace, "vault-pw-test")

      status.exit_code.must_equal(0)
      output.must_include("secret_val=abc123")
    end
  end

  # ansible loads these vars lazily as the play starts, so the refusal is
  # a single "[ERROR]" line AFTER the PLAY banner at rc=4, with no task
  # and no PLAY RECAP.
  it "refuses a group_vars file no secret can open, after the PLAY banner" do
    with_workspace("vault-group-vars-fail") do |workspace|
      write_group_vars(workspace)

      status, output = run_playbook(workspace, "wrong-password")

      status.exit_code.must_equal(4)
      banner_at = output.index!("PLAY [all]")
      error_at = output.index!("[ERROR]: Decryption failed (no vault secrets were found that could decrypt).")
      (error_at > banner_at).must_equal(true)
      output.wont_include("PLAY RECAP")
    end
  end

  # ansible's --syntax-check never loads inventory vars at all, so an
  # undecryptable group_vars file must not turn syntax-checking a
  # playbook into a failure.
  it "leaves --syntax-check untouched by an undecryptable group_vars file" do
    with_workspace("vault-group-vars-syntax") do |workspace|
      write_group_vars(workspace)

      status, _output = run_playbook(workspace, nil, ["--syntax-check"])

      status.exit_code.must_equal(0)
    end
  end
end
