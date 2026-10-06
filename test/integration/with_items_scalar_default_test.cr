require "../minitest_helper"

# A with_items: source that resolves to a SCALAR through a filter chain
# (`{{ undefined_var | default('xclip') }}`, nephelaiio.xclip's own
# `with_items: "{{ xclip_packages | default(xclip_packages_default) }}"`
# with only the default-defined scalar available) must iterate ONCE with
# the scalar as `item` - Ansible always wraps a non-list resolution into a
# single iteration for with_items:, verified live against ansible-core
# 2.19.11 (cold_py.out of round 2100565: `ok: => (item=xclip)`). Krikri's
# filter-chain resolution path used to return no loop items at all for the
# scalar, running the task ONCE with `item` unbound - pre-strict
# templating read `{{ item }}` as the "undefined" sentinel, 2.19-parity
# strictness fails the task with "'item' is undefined".
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "test", "fixtures", "inventory-explicit-localhost.ini")

private def run_playbook(yaml : String)
  playbook = File.tempname("with-items-scalar", ".yml")
  File.write(playbook, yaml)
  output = IO::Memory.new
  status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)
  {status, output.to_s}
ensure
  File.delete(playbook) if playbook && File.exists?(playbook)
end

describe "with_items: scalar filter-chain resolution" do
  it "wraps an undefined-var defaulting to a scalar into one iteration with that scalar as item" do
    status, output = run_playbook(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        vars:
          xclip_packages_default: xclip
        tasks:
          - name: install xclip packages
            ansible.builtin.debug:
              msg: "{{ item }}"
            with_items: "{{ xclip_packages | default(xclip_packages_default) }}"
      YAML

    status.exit_code.must_equal(0)
    output.must_include("(item=xclip)")
    output.wont_include("'item' is undefined")
  end

  it "wraps a defined scalar variable into one iteration, matching the direct-path convention" do
    status, output = run_playbook(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        vars:
          myscalar: ruby
        tasks:
          - name: scalar loop
            ansible.builtin.debug:
              msg: "{{ item }}"
            with_items: "{{ myscalar | upper }}"
      YAML

    status.exit_code.must_equal(0)
    output.must_include("(item=RUBY)")
  end
end
