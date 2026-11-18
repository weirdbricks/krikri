require "file_utils"
require "../minitest_helper"

# `vars_files:` was not implemented at all - the keyword parsed to
# nothing, so every name it should have defined was undefined and the
# task failed. Expectations below come from an ansible-core 2.19.4 run of
# the same playbooks.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")

private def run_play(playbook : String, files : Hash(String, String), vault_password : String? = nil)
  dir = File.tempname("vars-files")
  Dir.mkdir_p(dir)
  File.write(File.join(dir, "inv.ini"), "localhost ansible_connection=local\n")
  files.each { |name, body| File.write(File.join(dir, name), body) }
  File.write(File.join(dir, "pb.yml"), playbook)

  args = ["-i", "inv.ini", "pb.yml"]
  if password = vault_password
    File.write(File.join(dir, "pw"), "#{password}\n")
    args += ["--vault-password-file", "pw"]
  end

  stdout_io = IO::Memory.new
  status = Process.run(BINARY, args,
    output: stdout_io, error: stdout_io, chdir: dir)
  {status, stdout_io.to_s}
ensure
  FileUtils.rm_rf(dir) if dir && Dir.exists?(dir)
end

# `secret_val: abc123`, encrypted with the password `vault-pw-test`
# (`ansible-vault encrypt`), and `inline123` as `ansible-vault
# encrypt_string` emits it - the two shapes issue #1462 is about.
private ENCRYPTED_VARS_FILE = <<-VAULT
  $ANSIBLE_VAULT;1.1;AES256
  39363736613437633630366563653262323438303566633165646363333662306363616139306562
  6138613664333936666165666433666165643537363963390a373735666464393262636462373434
  32306437343765333133356361396230393430313836616236643934373433643163346666306333
  3637613230376530610a343531623363623739383237306161316563396437303238626133373232
  61343364376438323064393031306334633564633933366338666637666531636337
  VAULT

private ENCRYPTED_INLINE = <<-YAML
  inl: !vault |
              $ANSIBLE_VAULT;1.1;AES256
              32396161393439613366623435313165356663303434343430336535616662373734646466663133
              3665666132363462613832656663353964633733663337390a643537396162616538656165363939
              61363165613961326361303863653435343632363565363264646462346261643936343738396232
              3565333465336162350a373465376630346132313266653737393736373038336439303464313265
              6431
  YAML

describe "vars_files:" do
  # Precedence, verified live: a name set in BOTH `vars:` and a vars_file
  # resolves to the FILE's value, and a later file beats an earlier one.
  it "loads files, with later files and files-over-play-vars winning" do
    _, output = run_play(<<-YAML, {"v1.yml" => "a: from_file1\nshared: from_file1\n", "v2.yml" => "b: from_file2\nshared: from_file2\n"})
      - hosts: all
        gather_facts: false
        vars:
          playvar: from_play
          shared: from_play_vars
        vars_files:
          - v1.yml
          - v2.yml
        tasks:
          - name: t
            ansible.builtin.debug:
              msg: "a={{ a }} b={{ b }} shared={{ shared }} playvar={{ playvar }}"
      YAML

    output.must_include("a=from_file1")
    output.must_include("b=from_file2")
    output.must_include("shared=from_file2")
    output.must_include("playvar=from_play")
  end

  # A nested list is "first of these that exists".
  it "takes the first existing file of a candidate list" do
    _, output = run_play(<<-YAML, {"alt2.yml" => "alt: from_second\n"})
      - hosts: all
        gather_facts: false
        vars_files:
          - [ missing1.yml, alt2.yml ]
        tasks:
          - name: t
            ansible.builtin.debug: {msg: "alt={{ alt }}"}
      YAML

    output.must_include("alt=from_second")
  end

  # A missing file is tolerated silently by Ansible (rc=0), not an
  # error - verified.
  it "tolerates a missing file" do
    status, output = run_play(<<-YAML, {} of String => String)
      - hosts: all
        gather_facts: false
        vars_files:
          - nosuchfile.yml
        tasks:
          - name: t
            ansible.builtin.debug: {msg: "RAN"}
      YAML

    status.exit_code.must_equal(0)
    output.must_include("RAN")
  end

  # The path may be templated, including against a FACT - which means it
  # cannot be resolved until after gathering, and the per-host cache must
  # not be filled in from the pre-facts pass.
  it "resolves a path templated against a fact" do
    _, output = run_play(<<-YAML, {"vars-#{`. /etc/os-release 2>/dev/null; echo`.strip}.yml" => "", "os-marker.yml" => "os: loaded\n"})
      - hosts: all
        gather_facts: true
        vars_files:
          - "os-{{ 'marker' }}.yml"
        tasks:
          - name: t
            ansible.builtin.debug: {msg: "os={{ os }}"}
      YAML

    output.must_include("os=loaded")
  end

  # ansible decrypts a whole vault-armored vars_files entry; without this
  # the ciphertext parsed as a bare YAML string and every name it defined
  # stayed undefined (issue #1462).
  it "decrypts a vault-armored vars_file with the supplied password" do
    status, output = run_play(<<-YAML, {"enc.yml" => ENCRYPTED_VARS_FILE}, "vault-pw-test")
      - hosts: all
        gather_facts: false
        vars_files: [enc.yml]
        tasks:
          - name: t
            ansible.builtin.debug: {msg: "secret_val={{ secret_val }}"}
      YAML

    status.exit_code.must_equal(0)
    output.must_include("secret_val=abc123")
  end

  # The other vault shape a vars_files entry can carry: one value tagged
  # `!vault` inside an otherwise plaintext file (ansible-vault
  # encrypt_string), which used to reach the task still encrypted.
  it "decrypts an inline !vault value in a vars_file" do
    status, output = run_play(<<-YAML, {"inl.yml" => ENCRYPTED_INLINE}, "vault-pw-test")
      - hosts: all
        gather_facts: false
        vars_files: [inl.yml]
        tasks:
          - name: t
            ansible.builtin.debug: {msg: "inline={{ inl }}"}
      YAML

    status.exit_code.must_equal(0)
    output.must_include("inline=inline123")
  end

  # A file no supplied secret can open is ansible's whole-run refusal
  # before any PLAY output, not a silently skipped vars file: rc=1 and
  # the wrapped "Invalid vars_files file" block.
  it "refuses a vault-armored vars_file no secret can open" do
    status, output = run_play(<<-YAML, {"enc.yml" => ENCRYPTED_VARS_FILE}, "wrong-password")
      - hosts: all
        gather_facts: false
        vars_files: [enc.yml]
        tasks:
          - name: t
            ansible.builtin.debug: {msg: "RAN"}
      YAML

    status.exit_code.must_equal(1)
    output.wont_include("PLAY [all]")
    output.must_include("Invalid vars_files file '")
    output.must_include("Decryption failed (no vault secrets were found that could decrypt).")
    output.must_include("<<< caused by >>>")
  end
end
