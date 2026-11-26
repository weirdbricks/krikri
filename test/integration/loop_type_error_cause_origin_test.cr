require "../minitest_helper"

# Issue #239 - a loop source that IS defined but has the wrong shape
# (`loop: "{{ sensu_backend.namespaces }}"` over a `sensu_backend: {}`
# dict) fails with "object of type 'dict' has no attribute 'namespaces'",
# and the "<<< caused by >>>" stanza must pin its Origin at the loop
# VALUE token exactly like the 'is undefined' case does (live-verified
# vs ansible-core 2.19.11). The loop key is written AFTER a
# block-sequence module param here (argv:'s items) - the locator used to
# stop at those nested `- ` lines as if they were the next task and
# never find the key at all, for the undefined case too.

private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "test", "fixtures", "inventory-explicit-localhost.ini")

describe "loop type-error cause stanza origin" do
  it "pins the cause Origin at the loop value token after a block-sequence param" do
    pb = PluginSpecHelper.tmp_path("loop-attr-origin", "pb.yml")
    FileUtils.mkdir_p(File.dirname(pb))
    File.write(pb, <<-YAML)
      ---
      - hosts: localhost
        connection: local
        gather_facts: false
        vars:
          sensu_backend: {}
        tasks:
          - name: Create ns
            command:
              argv:
                - "true"
                - "{{ item }}"
            loop: "{{ sensu_backend.namespaces }}"
            ignore_errors: "true"
      YAML

    stdout = IO::Memory.new
    Process.run(BINARY, ["-i", INVENTORY, pb], output: stdout, error: Process::Redirect::Inherit)
    text = stdout.to_s

    text.must_include("[ERROR]: Task failed: object of type 'dict' has no attribute 'namespaces'")
    text.must_include("<<< caused by >>>")
    # The cause stanza's Origin sits at the loop VALUE token: line 13,
    # the opening quote's column (6-space indent + `loop: `).
    text.must_include("object of type 'dict' has no attribute 'namespaces'\nOrigin: #{pb}:13:13")
    # Same excerpt layout as the 'is undefined' case: 2 preceding source
    # lines, numbered, plus the caret under column 13.
    text.must_include("11           - \"true\"\n12           - \"{{ item }}\"\n13       loop: \"{{ sensu_backend.namespaces }}\"\n               ^ column 13")
  end

  it "pins the cause Origin for an undefined loop source after a block-sequence param too" do
    pb = PluginSpecHelper.tmp_path("loop-undef-origin", "pb.yml")
    FileUtils.mkdir_p(File.dirname(pb))
    File.write(pb, <<-YAML)
      ---
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: T
            command:
              argv:
                - "true"
                - "{{ item }}"
            loop: "{{ nope }}"
            ignore_errors: "true"
      YAML

    stdout = IO::Memory.new
    Process.run(BINARY, ["-i", INVENTORY, pb], output: stdout, error: Process::Redirect::Inherit)
    text = stdout.to_s

    text.must_include("[ERROR]: Task failed: 'nope' is undefined")
    text.must_include("'nope' is undefined\nOrigin: #{pb}:11:13")
    text.must_include(" 9           - \"true\"\n10           - \"{{ item }}\"\n11       loop: \"{{ nope }}\"\n               ^ column 13")
  end

  # Issue #1824 (jedimt.ssh) - the loop source READS a role default whose own
  # value carries the miss (`ssh_known_hosts: "{{ groups['servers'] }}"` over
  # an inventory with no `servers` group). Real templates that default lazily
  # and points the cause stanza at its value token, not at the `with_items:`
  # that read it (live-verified vs 2.21.6).
  it "pins the cause Origin at the loop source variable's own definition" do
    dir = PluginSpecHelper.tmp_path("loop-attr-def-origin")
    FileUtils.mkdir_p(File.join(dir, "roles", "ssh", "defaults"))
    FileUtils.mkdir_p(File.join(dir, "roles", "ssh", "tasks"))
    pb = File.join(dir, "pb.yml")
    File.write(pb, <<-YAML)
      ---
      - hosts: localhost
        connection: local
        gather_facts: false
        roles:
          - ssh
      YAML
    tasks = File.join(dir, "roles", "ssh", "tasks", "main.yml")
    File.write(tasks, <<-YAML)
      ---
      - name: For each host, scan for its ssh public key
        ansible.builtin.shell: "ssh-keyscan {{ item }}"
        with_items: "{{ ssh_known_hosts }}"
        changed_when: false
      YAML
    defaults = File.join(dir, "roles", "ssh", "defaults", "main.yml")
    File.write(defaults, <<-YAML)
      ---
      ssh_known_hosts: "{{ groups['servers'] }}"
      YAML

    stdout = IO::Memory.new
    Process.run(BINARY, ["-i", INVENTORY, pb], output: stdout, error: Process::Redirect::Inherit)
    text = stdout.to_s

    text.must_include("[ERROR]: Task failed: object of type 'dict' has no attribute 'servers'")
    text.must_include("object of type 'dict' has no attribute 'servers'\nOrigin: #{defaults}:2:18")
    text.wont_include("Origin: #{tasks}:5:13")
  end

  # Issue #1846 (mrlesmithjr.ansible_freeipa_server) - the LITERAL-with_items
  # sibling of the case above: the failing entry is a bare reference to a role
  # default whose own value reads a hostvars entry that does not exist
  # (`hostvars[inventory_hostname]['ansible_enp0s8']` on a host without that
  # interface). Real names the per-host HostVarsVars wrapper and points the
  # cause stanza at that default's value token, not at the `with_items:` entry
  # that read it (live-verified vs 2.21.6).
  it "pins the cause Origin at a literal loop item's referenced definition" do
    dir = PluginSpecHelper.tmp_path("loop-item-attr-def-origin")
    FileUtils.mkdir_p(File.join(dir, "roles", "freeipa", "defaults"))
    FileUtils.mkdir_p(File.join(dir, "roles", "freeipa", "tasks"))
    pb = File.join(dir, "pb.yml")
    File.write(pb, <<-YAML)
      ---
      - hosts: localhost
        connection: local
        gather_facts: false
        roles:
          - freeipa
      YAML
    tasks = File.join(dir, "roles", "freeipa", "tasks", "main.yml")
    File.write(tasks, <<-YAML)
      - name: hostname | Updating /etc/hosts
        lineinfile:
          path: /etc/hosts
          regexp: "^{{ item }}"
          line: "{{ item }} {{ freeIPA_server_fqdn }} {{ ansible_hostname }}"
          state: present
        become: true
        with_items:
          - 127.0.1.1
          - "{{ freeIPA_server_ip_address }}"
      YAML
    defaults = File.join(dir, "roles", "freeipa", "defaults", "main.yml")
    File.write(defaults, <<-YAML)
      ---
      freeIPA_server_fqdn: "{{ freeIPA_server_hostname }}.{{ freeIPA_server_domain }}"
      freeIPA_server_hostname: "{{ ansible_hostname }}"
      freeIPA_server_ip_address: "{{ hostvars[inventory_hostname]['ansible_' + freeIPA_server_ip_int]['ipv4']['address'] }}"
      freeIPA_server_ip_int: enp0s8
      YAML

    stdout = IO::Memory.new
    Process.run(BINARY, ["-i", INVENTORY, pb], output: stdout, error: Process::Redirect::Inherit)
    text = stdout.to_s

    text.must_include("[ERROR]: Task failed: object of type 'HostVarsVars' has no attribute 'ansible_enp0s8'")
    text.must_include("object of type 'HostVarsVars' has no attribute 'ansible_enp0s8'\nOrigin: #{defaults}:4:28")
    text.wont_include("Origin: #{tasks}:9:7")
  end
end
