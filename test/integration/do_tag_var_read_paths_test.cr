require "../minitest_helper"

private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")

# ansible-core never loads jinja2.ext.do, so a variable whose value holds a
# `{% do %}` tag fails EVERY read of it with a syntax error (issue #322,
# pgvillage.chainsmith). krikri's engine supports the tag, so each read path
# needs its own refusal; before this, `debug: var:` printed ok, `assert:`
# killed the process and a `loop:` source iterated the rendered value.
describe "{% do %} tag in a variable's value fails every read path (#322)" do
  it "fails debug var:, assert, when: and loop: without crashing or reporting ok" do
    playbook = File.tempname("do-tag-read-paths", ".yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        vars:
          a: "{% set files = [] %}{% do files.append(1) %}{{ files }}"
        tasks:
          - name: debug var
            ansible.builtin.debug:
              var: a
            ignore_errors: true
          - name: assert that
            ansible.builtin.assert:
              that: "a | length > 0"
            ignore_errors: true
          - name: when gate
            ansible.builtin.debug:
              msg: ran
            when: "a | length > 0"
            ignore_errors: true
          - name: loop source
            ansible.builtin.debug:
              msg: "item {{ item }}"
            loop: "{{ a }}"
            ignore_errors: true
      YAML

    output = IO::Memory.new
    Process.run(BINARY, [playbook], output: output, error: output)
    text = output.to_s

    assert text.scan("Encountered unknown tag 'do'").size >= 4
    text.must_include("Error while resolving `var` expression: Syntax error in template: Encountered unknown tag 'do'.")
    text.must_include("ignored=4")
    text.wont_include("Unhandled exception")
    text.wont_include("item 1")
  ensure
    File.delete(playbook) if playbook && File.exists?(playbook)
  end
end
