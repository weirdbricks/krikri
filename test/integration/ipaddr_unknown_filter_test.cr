require "../minitest_helper"

# Bare `ipaddr` (and the whole ansible.utils ipaddr family) is NOT a core
# Ansible filter - it lives in the ansible.utils collection, reachable only
# as `ansible.utils.ipaddr` (issue #335, bersace.dockerdns: the role's own
# template uses bare `network|ipaddr('netmask')` and
# `network|ipaddr(1)|ipaddr('address')`). So a playbook using the bare name
# must fail the same way ansible-core 2.19.11 fails it (live-verified on
# this host): through the task-arg finalization chain for a `{{ }}` param,
# and as the template-file COMPILE crash ("Syntax error in template: No
# filter named 'ipaddr'.", cause Origin the template file) for a .j2 -
# NOT the "succeed-then-crash" shape the old bare registration produced
# (`ipaddr(1)`'s integer query died in an Int64->String cast).
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "test", "fixtures", "inventory-explicit-localhost.ini")

describe "bare ipaddr family is rejected as unknown filters" do
  it "fails a task-arg bare ipaddr through the finalization chain like ansible-core" do
    playbook = File.tempname("ipaddr-unknown-filter", ".yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        vars:
          network: 192.168.7.0/24
        tasks:
          - debug:
              msg: "{{ network | ipaddr('netmask') }}"
      YAML
    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)
    text = output.to_s

    text.must_include("No filter named 'ipaddr'")
    text.must_include("Finalization of task args for 'ansible.builtin.debug' failed")
    status.success?.must_equal(false)
  ensure
    File.delete(playbook) if playbook && File.exists?(playbook)
  end

  it "fails a bare ipaddr inside a template file with ansible's compile-crash shape" do
    src = File.tempname("ipaddr-bare-src", ".j2")
    dest = File.tempname("ipaddr-bare-dest")
    playbook = File.tempname("ipaddr-bare-template", ".yml")
    File.write(src, "{{ network | ipaddr('netmask') }}\n")

    File.write(playbook, <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        vars:
          network: 192.168.7.0/24
        tasks:
          - template:
              src: #{src}
              dest: #{dest}
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)

    status.exit_code.must_equal(2)
    text = output.to_s
    # Byte-verified against ansible-playbook 2.19.11 on the same playbook:
    # the uncaught TemplateAssertionError takes the crash shape, the
    # <<< caused by >>> cause naming the bare filter and pointing its
    # Origin at the TEMPLATE file (path only), the fatal msg keeping the
    # "Task failed: " prefix.
    text.must_include("[ERROR]: Task failed: Syntax error in template: No filter named 'ipaddr'.")
    text.must_include("<<< caused by >>>")
    text.must_include("Syntax error in template: No filter named 'ipaddr'.\nOrigin: #{src}")
    text.must_include(%(fatal: [localhost]: FAILED! => {"changed": false, "msg": "Task failed: Syntax error in template: No filter named 'ipaddr'."}))
    text.wont_include("Failed to render template")
    File.exists?(dest).must_equal(false)
  ensure
    File.delete(playbook) if playbook && File.exists?(playbook)
    File.delete(src) if src && File.exists?(src)
    File.delete(dest) if dest && File.exists?(dest)
  end

  it "renders the ansible.utils FQCN spelling, including the integer ipaddr(1) query" do
    src = File.tempname("ipaddr-fqcn-src", ".j2")
    dest = File.tempname("ipaddr-fqcn-dest")
    playbook = File.tempname("ipaddr-fqcn-template", ".yml")
    # The dddns role's own idiom, under the spelling real resolves
    # against the installed ansible.utils collection (live-verified:
    # netmask 255.255.255.0, ipaddr(1) -> 192.168.7.1/24 whose address
    # query is 192.168.7.1).
    File.write(src, "{{ network | ansible.utils.ipaddr('netmask') }}\n{{ network | ansible.utils.ipaddr(1) | ansible.utils.ipaddr('address') }}\n")

    File.write(playbook, <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        vars:
          network: 192.168.7.0/24
        tasks:
          - template:
              src: #{src}
              dest: #{dest}
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)

    status.success?.must_equal(true)
    File.read(dest).must_equal("255.255.255.0\n192.168.7.1\n")
  ensure
    File.delete(playbook) if playbook && File.exists?(playbook)
    File.delete(src) if src && File.exists?(src)
    File.delete(dest) if dest && File.exists?(dest)
  end
end
