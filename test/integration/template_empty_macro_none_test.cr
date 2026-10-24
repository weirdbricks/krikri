require "../minitest_helper"

private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "test", "fixtures", "inventory-explicit-localhost.ini")

describe "a macro that renders no output" do
  it "hands None to the next filter, so indent fails like ansible-core 2.19" do
    # Issue #316 (bodsch.dhcpd): ansible-core's concat returns None for an
    # empty node list, so `{{ m() | indent(2) }}` fails the task with the
    # filter-plugin wrapper and the template file as Origin.
    src = File.tempname("empty-macro-src", ".j2")
    dest = File.tempname("empty-macro-dest")
    playbook = File.tempname("empty-macro", ".yml")
    File.write(src, "{% macro m(o) %}\n{% endmacro %}\n{{ m([1]) | indent(2) }}\n")

    File.write(playbook, <<-YAML)
      - name: repro
        hosts: localhost
        gather_facts: false
        tasks:
          - name: render
            ansible.builtin.template:
              src: #{src}
              dest: #{dest}
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)

    status.success?.must_equal(false)
    text = output.to_s
    text.must_include("The filter plugin 'ansible.builtin.indent' failed: unsupported operand type(s) for +=: 'NoneType' and 'str'\nOrigin: #{src}")
    File.exists?(dest).must_equal(false)
  ensure
    File.delete(playbook) if playbook && File.exists?(playbook)
    File.delete(src) if src && File.exists?(src)
    File.delete(dest) if dest && File.exists?(dest)
  end
end
