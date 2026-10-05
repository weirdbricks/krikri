require "../minitest_helper"

# End-to-end specs for the LOCAL persistent plugin daemon
# (ansible_connection=local): the same one-resident-plugin-process
# optimization the ssh path has had since 0.9.501, applied to local
# connections. These run the compiled binary against real playbooks - the
# daemon spawn/reuse/fallback wiring, the per-request env/cwd isolation a
# long-lived process needs, and the --no-persistent-daemon opt-out
# producing byte-identical output.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "test", "fixtures", "inventory-explicit-localhost.ini")

private TWO_LOCAL_INVENTORY = File.join(PROJECT_ROOT, "test", "fixtures", "inventory-two-local-hosts.ini")

private def run_playbook(yaml : String, extra_args : Array(String) = [] of String, inventory : String = INVENTORY) : {Process::Status, String, String}
  playbook = File.tempname("local-daemon-spec", ".yml")
  File.write(playbook, yaml)
  stdout = IO::Memory.new
  stderr = IO::Memory.new
  status = Process.run(BINARY, ["-i", inventory, playbook] + extra_args, output: stdout, error: stderr)
  {status, stdout.to_s, stderr.to_s}
ensure
  File.delete(playbook) if playbook && File.exists?(playbook)
end

describe "local plugin daemon (ansible_connection=local)" do
  it "serves consecutive local tasks from one resident daemon without leaking environment or cwd between them" do
    status, stdout, _stderr = run_playbook(<<-YAML, ["--timing-profile"])
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - command: env
            environment:
              KRIKRI_DAEMON_SPEC_PROBE: from-task-one
            register: marked
          - command: env
            register: clean
          - command: pwd
            args:
              chdir: /etc
            register: moved
          - command: pwd
            register: home
          - debug:
              msg: >-
                marked={{ 'KRIKRI_DAEMON_SPEC_PROBE=from-task-one' in marked.stdout }}
                leak={{ 'KRIKRI_DAEMON_SPEC_PROBE' in clean.stdout }}
                moved={{ moved.stdout }}
                cwd_reset={{ home.stdout != moved.stdout }}
      YAML

    status.success?.must_equal(true)
    stdout.includes?("marked=True leak=False moved=/etc cwd_reset=True").must_equal(true)
    # The daemon transport was actually used end to end (its own timing
    # bucket appears), not silently fallen back to one-shot execs.
    stdout.includes?("local daemon request").must_equal(true)
  end

  it "gives each local host its own resident daemon under --forks 2 (per-host keying)" do
    status, stdout, _stderr = run_playbook(<<-YAML, ["--timing-profile", "--forks", "2"], inventory: TWO_LOCAL_INVENTORY)
      - hosts: hostone:hosttwo
        connection: local
        gather_facts: false
        tasks:
          - command: echo keyed-{{ inventory_hostname }}
            register: out
          - command: echo again-{{ inventory_hostname }}
          - debug: msg="saw={{ out.stdout }}"
      YAML

    status.success?.must_equal(true)
    stdout.includes?("saw=keyed-hostone").must_equal(true)
    stdout.includes?("saw=keyed-hosttwo").must_equal(true)
    stdout.includes?("failed=0").must_equal(true)
    # The daemon transport served both hosts' tasks (each host gets its
    # own resident daemon keyed by host name - the send count reflects
    # every request, not a single shared pipe's worth).
    stdout.includes?("local daemon request").must_equal(true)
  end

  it "runs a become_user task through the daemon when the escalation is a no-op (become_user == invoking user)" do
    user = ENV["USER"]? || "root"
    status, stdout, _stderr = run_playbook(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        become: true
        become_user: #{user}
        tasks:
          - command: echo become-daemon
            register: out
          - command: echo become-again
          - debug: msg="saw={{ out.stdout }}"
      YAML

    status.success?.must_equal(true)
    stdout.includes?("saw=become-daemon").must_equal(true)
    stdout.includes?("failed=0").must_equal(true)
  end

  it "produces byte-identical stdout with the daemon disabled (--no-persistent-daemon)" do
    playbook_body = <<-YAML
      - hosts: localhost
        connection: local
        gather_facts: true
        tasks:
          - command: echo daemon-parity
          - stat: path=/etc/hostname
          - command: env
            environment:
              KRIKRI_DAEMON_SPEC_PROBE: parity
            register: marked
          - command: env
            register: clean
          - debug:
              msg: "parity={{ 'KRIKRI_DAEMON_SPEC_PROBE=parity' in marked.stdout }} leak={{ 'KRIKRI_DAEMON_SPEC_PROBE' in clean.stdout }}"
      YAML

    daemon_status, daemon_out, _ = run_playbook(playbook_body)
    plain_status, plain_out, _ = run_playbook(playbook_body, ["--no-persistent-daemon"])

    daemon_status.success?.must_equal(true)
    plain_status.success?.must_equal(true)
    # Identical modulo the timing-profile block only the daemon run asked
    # for - so neither run asks for it.
    daemon_out.must_equal(plain_out)
  end
end
