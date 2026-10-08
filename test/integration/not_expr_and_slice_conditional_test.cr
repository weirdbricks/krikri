require "../minitest_helper"

# Two expression-parsing shapes the strict probes and the conditional
# evaluator mis-handled, both found in benchmark round 5210000 (real
# Atlantic.net hosts, krikri vs ansible-core 2.19.11):
#
# 1. `not(...)` with NO space before the paren. The Jinja operator
#    keyword `not` matched undefined_access_chain_source's
#    root-then-call regex as a variable named "not" being "called", so
#    the strict probe raised "'not' is undefined" where Ansible
#    evaluates the negation fine (rubyisbeautiful.proxy-common's
#    `{{ not((common_proxy_host is undefined) or ...) }}` set_fact).
#    Fix: operator keywords join NON_VAR_ROOT_NAMES, so they can never
#    be read as a variable root.
# 2. A Python-style slice index inside a bare `when:` condition
#    (`item[8:] not in query('varnames', '.*')` - sdarwin.nagios's
#    looped set_fact). ConditionalEvaluator#evaluate_value's naive
#    dotted/indexed branch fed the whole `item[8:]` text to
#    VariableLookup#resolve as a literal bracket key, missed, and
#    raised "'item' is undefined" per item; slice-bearing operands now
#    route through ExpressionEvaluator's ArraySlicer, which handles
#    slices on strings and lists alike.
#
# Both shapes live-verified against ansible-core 2.19.11 locally.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "test", "fixtures", "inventory-explicit-localhost.ini")

private def run_playbook(yaml : String)
  playbook = File.tempname("not-slice-conditional", ".yml")
  File.write(playbook, yaml)
  output = IO::Memory.new
  status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)
  {status, output.to_s}
ensure
  File.delete(playbook) if playbook && File.exists?(playbook)
end

describe "not() expression and when: slice parsing" do
  it "evaluates not(...) without a space like Ansible" do
    status, output = run_playbook(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        vars:
          foo: ""
        tasks:
          - set_fact:
              active: "{{ not((foo is undefined) or (foo == None)) }}"
          - debug:
              msg: "active={{ active | type_debug }}={{ active }}"
      YAML

    status.exit_code.must_equal(0)
    output.must_include("active=bool=True")
    output.wont_include("'not' is undefined")
  end

  it "evaluates a slice index in a looped when: like Ansible" do
    status, output = run_playbook(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        vars:
          default_alpha: "one"
        tasks:
          - name: Set facts based on defaults
            set_fact:
              "{{ item[8:] }}": "{{ lookup('vars', item) }}"
            when: item[8:] not in query('varnames', '.*')
            loop: "{{ query('varnames', '^default_') }}"
          - debug:
              msg: "alpha={{ alpha | default('MISSING') }}"
      YAML

    status.exit_code.must_equal(0)
    output.must_include("alpha=one")
    output.wont_include("'item' is undefined")
  end
end
