require "../spec_helper"

# The connection/become/misc CLI flags added in 0.9.565. Behavior checked
# against a real ansible-core 2.19.4 where observable.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "spec", "fixtures", "inventory-explicit-localhost.ini")

private def run_with(args : Array(String), yaml : String, input : String? = nil)
  playbook = File.tempname("cli-flags", ".yml")
  File.write(playbook, yaml)
  stdout_io = IO::Memory.new
  status = Process.run(BINARY, ["-i", INVENTORY] + args + [playbook],
    output: stdout_io, error: stdout_io,
    input: input ? IO::Memory.new(input) : Process::Redirect::Close)
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
    output.should contain("u=bob")
  end

  it "--connection sets ansible_connection" do
    _, output = run_with(["--connection", "local"], SHOW_VARS)
    output.should contain("c=local")
  end

  # Real Ansible's -b sets an internal default and leaves the VARIABLE
  # unset - `{{ ansible_become | default(false) }}` still renders False
  # under -b. Setting the var would be visible to playbooks reading it.
  it "-b does not expose itself as the ansible_become variable" do
    _, output = run_with(["-b"], SHOW_VARS)
    output.should contain("b=False")
  end

  it "accepts --private-key, -T, --ssh-extra-args, --flush-cache, -M and --vault-id" do
    status, _ = run_with(
      ["--private-key", "/dev/null", "-T", "25", "--ssh-extra-args", "-o LogLevel=ERROR",
       "--flush-cache", "-M", "/tmp/x", "--vault-id", "foo@prompt"], SHOW_VARS)
    status.exit_code.should eq(0)
  end

  # Real Ansible's own short forms, which this engine previously lacked.
  it "supports -C for check mode and -D for diff mode" do
    _, check = run_with(["-C"], SHOW_VARS)
    check.should contain("CHECK")
    status, _ = run_with(["-D"], SHOW_VARS)
    status.exit_code.should eq(0)
  end

  # 0.9.566 flipped -c from --check to --connection, matching real
  # Ansible. -C is now the only short form for check mode.
  it "-c is --connection, not --check" do
    _, output = run_with(["-c", "local"], SHOW_VARS)
    output.should contain("c=local")
    output.should_not contain("CHECK")
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
    output.should contain("Perform task: TASK: one")
    output.should contain("ONE")
    output.should_not contain("TWO")
    output.should contain("THREE")
  end
end
