require "../minitest_helper"
require "system/user"

# The connection/become/misc CLI flags added in 0.9.565. Behavior checked
# against a ansible-core 2.19.4 where observable.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(__DIR__, "..", "fixtures", "inventory-explicit-localhost.ini")

private def run_with(args : Array(String), yaml : String, input : String? = nil, env : Hash(String, String)? = nil)
  playbook = File.tempname("cli-flags", ".yml")
  File.write(playbook, yaml)
  stdout_io = IO::Memory.new
  status = Process.run(BINARY, ["-i", INVENTORY] + args + [playbook],
    output: stdout_io, error: stdout_io,
    input: input ? IO::Memory.new(input) : Process::Redirect::Close,
    env: env)
  {status, stdout_io.to_s}
ensure
  File.delete(playbook) if playbook && File.exists?(playbook)
end

private SHOW_VARS = <<-YAML
  - name: V
    hosts: localhost
    connection: local
    gather_facts: false
    tasks:
      - name: show
        ansible.builtin.debug:
          msg: "u={{ ansible_user | default('-') }} c={{ ansible_connection | default('-') }} b={{ ansible_become | default(false) }}"
  YAML

describe "connection CLI flags" do
  it "-u sets ansible_user for every host" do
    _, output = run_with(["-u", "bob"], SHOW_VARS)
    output.must_include("u=bob")
  end

  it "--connection sets ansible_connection" do
    _, output = run_with(["--connection", "local"], SHOW_VARS)
    output.must_include("c=local")
  end

  # Ansible's -b sets an internal default and leaves the VARIABLE
  # unset - `{{ ansible_become | default(false) }}` still renders False
  # under -b. Setting the var would be visible to playbooks reading it.
  it "-b does not expose itself as the ansible_become variable" do
    _, output = run_with(["-b"], SHOW_VARS)
    output.must_include("b=False")
  end

  # Issue #1479: -b/--become-user are Ansible's base defaults for the
  # become family, so a task that writes no become: keyword of its own
  # must actually escalate through sudo. Same-user escalation is the only
  # one every sudo/PAM default allows without a password, and
  # ANSIBLE_BECOME_ALLOW_SAME_USER is Ansible's own opt-out from its
  # same-user no-op gate - with it, sudo really wraps the command and
  # sets SUDO_USER in the child's environment.
  it "-b and --become-user escalate a task that sets no become: keyword" do
    user = System::User.find_by?(id: LibC.getuid.to_s).try(&.username) || raise "cannot determine invoking user"
    status, output = run_with(
      ["-b", "--become-user", user], <<-YAML,
        - hosts: localhost
          connection: local
          gather_facts: false
          tasks:
            - name: show SUDO_USER
              ansible.builtin.command: printenv SUDO_USER
              register: r
              changed_when: false
              failed_when: false
            - ansible.builtin.debug: {var: r.stdout}
        YAML
      env: {"ANSIBLE_BECOME_ALLOW_SAME_USER" => "1"})

    status.exit_code.must_equal(0)
    output.must_match(/"r.stdout": "#{Regex.escape(user)}"/)
  end

  # The flags supply the DEFAULT only: a play or task that writes its own
  # become: keyword still wins (ansible-core's FieldAttribute rules).
  it "lets an explicit become: false keyword override -b" do
    user = System::User.find_by?(id: LibC.getuid.to_s).try(&.username) || raise "cannot determine invoking user"
    _, output = run_with(
      ["-b", "--become-user", user], <<-YAML,
        - hosts: localhost
          connection: local
          gather_facts: false
          tasks:
            - name: opts out
              become: false
              ansible.builtin.command: printenv SUDO_USER
              register: r
              changed_when: false
              failed_when: false
            - ansible.builtin.debug: {var: r.stdout}
        YAML
      env: {"ANSIBLE_BECOME_ALLOW_SAME_USER" => "1"})

    output.must_include(%("r.stdout": ""))
  end

  it "accepts --private-key, -T, --ssh-extra-args, --flush-cache, -M and --vault-id" do
    status, _ = run_with(
      ["--private-key", "/dev/null", "-T", "25", "--ssh-extra-args", "-o LogLevel=ERROR",
       "--flush-cache", "-M", "/tmp/x", "--vault-id", "foo@prompt"], SHOW_VARS)
    status.exit_code.must_equal(0)
  end

  # Ansible's own short forms, which this engine previously lacked.
  # -C's observable effect: a command task reports "skipping:" (the
  # module does not run in check mode), like ansible-playbook -C.
  it "supports -C for check mode and -D for diff mode" do
    _, check = run_with(["-C"], <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - ansible.builtin.command: echo check-probe
      YAML
    check.must_include("skipping: [localhost]")
    status, _ = run_with(["-D"], SHOW_VARS)
    status.exit_code.must_equal(0)
  end

  # 0.9.566 flipped -c from --check to --connection, matching
  # Ansible. -C is now the only short form for check mode.
  it "-c is --connection, not --check" do
    _, output = run_with(["-c", "local"], SHOW_VARS)
    output.must_include("c=local")
    output.wont_include("CHECK")
  end

  # Ansible's own long aliases (both still listed in ansible-core
  # 2.19.4's --help) - a command line copied from a ansible-playbook
  # invocation must parse here too.
  it "accepts --inventory-file and --vault-pass-file as aliases" do
    status, output = run_with(["--inventory-file", INVENTORY, "--vault-pass-file", "/dev/null"], SHOW_VARS)
    status.exit_code.must_equal(0)
    output.must_include("PLAY")
  end
end

describe "--step" do
  # y runs, n skips, c runs and stops prompting.
  it "runs, skips and continues per answer" do
    yaml = <<-YAML
      - name: S
        hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: one
            ansible.builtin.debug: {msg: "ONE"}
          - name: two
            ansible.builtin.debug: {msg: "TWO"}
          - name: three
            ansible.builtin.debug: {msg: "THREE"}
      YAML

    _, output = run_with(["--step"], yaml, input: "y\nn\nc\n")
    output.must_include("Perform task: TASK: one")
    output.must_include("ONE")
    output.wont_include("TWO")
    output.must_include("THREE")
  end
end
