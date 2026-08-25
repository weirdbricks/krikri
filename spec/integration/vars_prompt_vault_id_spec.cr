require "file_utils"
require "../spec_helper"

# `vars_prompt:` and `--vault-id`, both previously unimplemented.
# Expectations from ansible-core 2.19.4.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "crystal-ansible")

private def run_play(playbook : String, args : Array(String) = Array(String).new, files : Hash(String, String)? = nil)
  dir = File.tempname("vp-vid")
  Dir.mkdir_p(dir)
  File.write(File.join(dir, "inv.ini"), "localhost ansible_connection=local\n")
  File.write(File.join(dir, "pb.yml"), playbook)
  files.try &.each { |name, body| File.write(File.join(dir, name), body) }

  stdout_io = IO::Memory.new
  status = Process.run(BINARY, ["-i", "inv.ini"] + args + ["pb.yml"],
    output: stdout_io, error: stdout_io, chdir: dir)
  {status.exit_code, stdout_io.to_s}
ensure
  FileUtils.rm_rf(dir) if dir && Dir.exists?(dir)
end

describe "vars_prompt:" do
  # Real Ansible only PROMPTS on a terminal. With stdin piped or closed
  # it does not read the input at all - it uses the default. Verified:
  # piping "bob" to a prompt defaulting to "admin" still yields admin.
  it "uses defaults when not attached to a terminal" do
    code, output = run_play(<<-YAML)
      - hosts: all
        gather_facts: false
        vars_prompt:
          - name: username
            prompt: "What is your username?"
            private: false
            default: "admin"
          - name: secretword
            prompt: "Secret?"
            default: "s3cr3t"
        tasks:
          - name: t
            ansible.builtin.debug: {msg: "U={{ username }} S={{ secretword }}"}
      YAML

    code.should eq(0)
    output.should contain("U=admin S=s3cr3t")
  end

  # With no default and no terminal, the variable ends up as the literal
  # STRING "None" - type str, `is none` false. That is Python's
  # str(None) leaking through in real Ansible, quirk and all.
  it "yields the string None when there is no default" do
    _, output = run_play(<<-YAML)
      - hosts: all
        gather_facts: false
        vars_prompt:
          - name: nd
            prompt: "p"
            private: false
        tasks:
          - name: t
            ansible.builtin.debug:
              msg: "V=[{{ nd }}] T=[{{ nd | type_debug }}] isnone={{ nd is none }}"
      YAML

    output.should contain("V=[None]")
    output.should contain("T=[str]")
    output.should contain("isnone=False")
  end
end

# Produces a vault blob with this engine's own vault CLI, indented for
# use as a YAML `!vault |` block.
private def vault_block(value : String, password_file : String, password : String) : String
  File.write(password_file, password + "\n")
  stdout_io = IO::Memory.new
  Process.run(BINARY, ["vault", "encrypt_string", "--vault-password-file", password_file, value, "--name", "v"],
    output: stdout_io, error: Process::Redirect::Close)
  # Drop the "v: !vault |" first line, keep the indented ciphertext.
  stdout_io.to_s.lines[1..]?.try(&.join("\n")) || ""
end

describe "--vault-id" do
  # Several --vault-id flags each open their own blob; an unlabeled one
  # is the default identity.
  it "decrypts values belonging to different identities" do
    dir = File.tempname("vault-id")
    Dir.mkdir_p(dir)
    dev = vault_block("dev-secret-value", File.join(dir, "dev.txt"), "devpass")
    prod = vault_block("prod-secret-value", File.join(dir, "prod.txt"), "prodpass")
    File.write(File.join(dir, "inv.ini"), "localhost ansible_connection=local\n")
    File.write(File.join(dir, "pb.yml"), <<-YAML)
      - hosts: all
        gather_facts: false
        vars:
          devvar: !vault |
      #{dev}
          prodvar: !vault |
      #{prod}
        tasks:
          - name: t
            ansible.builtin.debug: {msg: "D={{ devvar }} P={{ prodvar }}"}
      YAML

    begin
      stdout_io = IO::Memory.new
      status = Process.run(BINARY,
        ["-i", "inv.ini", "--vault-id", "dev@dev.txt", "--vault-id", "prod@prod.txt", "pb.yml"],
        output: stdout_io, error: stdout_io, chdir: dir)
      status.exit_code.should eq(0)
      stdout_io.to_s.should contain("D=dev-secret-value")
      stdout_io.to_s.should contain("P=prod-secret-value")
    ensure
      FileUtils.rm_rf(dir) if Dir.exists?(dir)
    end
  end

  # The functional payoff of deferring the failure to point-of-use: a
  # playbook carrying a var this run cannot decrypt still runs, as long
  # as no task references it. Real Ansible exits 0 there, and 2 only
  # when the value IS used.
  it "runs when an undecryptable var is never referenced, and fails when it is" do
    dir = File.tempname("vault-id-unused")
    Dir.mkdir_p(dir)
    prod = vault_block("prod-secret-value", File.join(dir, "prod.txt"), "prodpass")
    File.write(File.join(dir, "inv.ini"), "localhost ansible_connection=local\n")
    File.write(File.join(dir, "unused.yml"), <<-YAML)
      - hosts: all
        gather_facts: false
        vars:
          prodvar: !vault |
      #{prod}
        tasks:
          - name: t
            ansible.builtin.debug: {msg: "OK"}
      YAML
    File.write(File.join(dir, "used.yml"), <<-YAML)
      - hosts: all
        gather_facts: false
        vars:
          prodvar: !vault |
      #{prod}
        tasks:
          - name: t
            ansible.builtin.debug: {msg: "P={{ prodvar }}"}
      YAML

    begin
      unused_io = IO::Memory.new
      unused = Process.run(BINARY, ["-i", "inv.ini", "unused.yml"],
        output: unused_io, error: unused_io, chdir: dir)
      unused.exit_code.should eq(0)
      unused_io.to_s.should contain("OK")

      used_io = IO::Memory.new
      used = Process.run(BINARY, ["-i", "inv.ini", "used.yml"],
        output: used_io, error: used_io, chdir: dir)
      used.exit_code.should eq(2)
      used_io.to_s.should contain("undecryptable variable")
    ensure
      FileUtils.rm_rf(dir) if Dir.exists?(dir)
    end
  end
end
