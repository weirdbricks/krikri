require "../minitest_helper"

# A builtin module whose name carries an ansible_builtin_runtime.yml
# redirect still shows the redirected FQCN in the task-args finalization
# error: ansible reports the redirect target for both the bare spelling
# and the explicit ansible.builtin.* spelling (live-observed with 2.19.x
# for authorized_key and mount), even though krikri dispatches the
# ansible.builtin.* FQCN. Live-captured against ansible-core 2.19.x.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "test", "fixtures", "inventory-explicit-localhost.ini")

private def run_playbook(yaml : String)
  playbook = File.tempname("redirected-builtin-module-args", ".yml")
  File.write(playbook, yaml)
  output = IO::Memory.new
  status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)
  {status, output.to_s, playbook}
ensure
  File.delete(playbook) if playbook && File.exists?(playbook)
end

describe "redirected builtin module args finalization" do
  it "names the redirect target for bare authorized_key" do
    status, output, _ = run_playbook(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: undef args on redirected builtin module
            authorized_key:
              user: "{{ authorized_key_user }}"
              key: foo
          - name: sentinel
            ansible.builtin.debug:
              msg: SHOULD-RUN-AFTER
      YAML

    status.exit_code.must_equal(2)
    output.must_include("Finalization of task args for 'ansible.posix.authorized_key' failed: Error while resolving value for 'user': 'authorized_key_user' is undefined")
    output.must_include("failed=1")
    # A failed task halts the host, so the sentinel task never runs -
    # matches real ansible.
    output.wont_include("SHOULD-RUN-AFTER")
    output.wont_include("Finalization of task args for 'ansible.builtin.authorized_key'")
  end

  it "names the redirect target for explicit ansible.builtin.authorized_key" do
    status, output, _ = run_playbook(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: undef args on redirected builtin module, FQCN spelling
            ansible.builtin.authorized_key:
              user: "{{ authorized_key_user }}"
              key: foo
          - name: sentinel
            ansible.builtin.debug:
              msg: SHOULD-RUN-AFTER
      YAML

    status.exit_code.must_equal(2)
    output.must_include("Finalization of task args for 'ansible.posix.authorized_key' failed: Error while resolving value for 'user': 'authorized_key_user' is undefined")
    output.must_include("failed=1")
    output.wont_include("SHOULD-RUN-AFTER")
    output.wont_include("Finalization of task args for 'ansible.builtin.authorized_key'")
  end

  it "names the redirect target for bare mount" do
    status, output, _ = run_playbook(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: undef args on redirected builtin module, mount
            mount:
              path: "{{ mount_path }}"
              state: mounted
          - name: sentinel
            ansible.builtin.debug:
              msg: SHOULD-RUN-AFTER
      YAML

    status.exit_code.must_equal(2)
    output.must_include("Finalization of task args for 'ansible.posix.mount' failed: Error while resolving value for 'path': 'mount_path' is undefined")
    output.must_include("failed=1")
    output.wont_include("SHOULD-RUN-AFTER")
    output.wont_include("Finalization of task args for 'ansible.builtin.mount'")
  end

  # A bare-name task inside a block/role prints the full chained block, but
  # when the module key itself carries the FQCN the redirect target no longer
  # matches anything in the playbook text - before the as-written lookup the
  # whole block silently vanished, leaving only the fatal: line.
  it "prints the full error block for a top-level FQCN spelled task" do
    status, output, playbook = run_playbook(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: undef args on redirected builtin module, FQCN spelling
            ansible.builtin.authorized_key:
              user: "{{ authorized_key_user }}"
              key: foo
      YAML

    status.exit_code.must_equal(2)
    output.must_include("[ERROR]: Task failed: Finalization of task args for 'ansible.posix.authorized_key' failed: Error while resolving value for 'user': 'authorized_key_user' is undefined")
    output.must_include("\nTask failed.\nOrigin: #{playbook}:5:7")
    output.must_include("\nFinalization of task args for 'ansible.posix.authorized_key' failed.\nOrigin: #{playbook}:6:7")
    output.must_include("Error while resolving value for 'user': 'authorized_key_user' is undefined\nOrigin: #{playbook}:7:15")
    output.must_include("failed=1")
  end
end
