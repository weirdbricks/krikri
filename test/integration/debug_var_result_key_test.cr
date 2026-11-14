require "../minitest_helper"

# Runs the compiled binary against a real playbook.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "test", "fixtures", "inventory-explicit-localhost.ini")

# Ansible's debug action plugin puts a `var:` result under the
# VARIABLE NAME key - never under msg (podman-diff debug_edge_cases
# D1/D4: a follow-up `d.msg | default('none')` prints 'none' on real
# for both a defined and an undefined var, and an unresolvable var:
# succeeds with the inline marker "<< error 1 - 'x' is undefined >>" (2.19.11; older releases printed "VARIABLE IS NOT DEFINED!") under
# that same key). A verbosity-skipped debug's registered result
# carries skipped but NO msg key either (D3).
describe "debug: var result key" do
  it "registers a defined var's value under the var name, with no msg" do
    playbook = File.tempname("debug-var-key", ".yml")
    File.write(playbook, <<-YAML)
      - name: repro
        hosts: localhost
        gather_facts: false
        vars:
          krikri_spec_defined_var: target-value
        tasks:
          - name: var debug
            ansible.builtin.debug:
              var: krikri_spec_defined_var
            register: r
          - name: show result
            ansible.builtin.debug:
              msg: "R msg={{ r.msg | default('none') }} val={{ r['krikri_spec_defined_var'] | default('none') }}"
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)

    status.success?.must_equal(true)
    output.to_s.must_include("R msg=none val=target-value")
  ensure
    File.delete(playbook) if playbook && File.exists?(playbook)
  end

  it "registers an undefined var as Ansible 2.19.11's inline error marker and still succeeds" do
    playbook = File.tempname("debug-var-undefined", ".yml")
    File.write(playbook, <<-YAML)
      - name: repro
        hosts: localhost
        gather_facts: false
        tasks:
          - name: undefined var debug
            ansible.builtin.debug:
              var: krikri_spec_undefined_var_zzz
            register: r
            ignore_errors: true
          - name: show result
            ansible.builtin.debug:
              msg: "R failed={{ r.failed | default('none') }} msg={{ r.msg | default('none') }} val={{ r['krikri_spec_undefined_var_zzz'] | default('none') }}"
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)

    status.success?.must_equal(true)
    output.to_s.must_include("R failed=False msg=none val=<< error 1 - 'krikri_spec_undefined_var_zzz' is undefined >>")
  ensure
    File.delete(playbook) if playbook && File.exists?(playbook)
  end

  it "registers a verbosity-skipped debug with skipped but no msg" do
    playbook = File.tempname("debug-skip-no-msg", ".yml")
    File.write(playbook, <<-YAML)
      - name: repro
        hosts: localhost
        gather_facts: false
        tasks:
          - name: gated debug
            ansible.builtin.debug:
              msg: hidden
              verbosity: 3
            register: r
            ignore_errors: true
          - name: show result
            ansible.builtin.debug:
              msg: "R failed={{ r.failed | default('none') }} msg={{ r.msg | default('none') }} skipped={{ r.skipped | default('none') }}"
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)

    status.success?.must_equal(true)
    output.to_s.must_include("R failed=False msg=none skipped=True")
  ensure
    File.delete(playbook) if playbook && File.exists?(playbook)
  end

  # Real debug templates the looked-up value through the Templar, which
  # renders a value made up ONLY of `{% %}` statement tags (no `{{ }}`
  # span at all) too - the lazy-render gate admitted `{{` only, so the
  # raw block-tag text was printed as the value (issue #1247). A
  # block-tag template that produces no output is a native None in
  # ansible (its Jinja concat returns None for an empty node list) and
  # prints as null, while a whole `{{ '' }}` span keeps the empty
  # string. Every shape below is live-verified against ansible-core
  # 2.21.6.
  it "renders var values made only of statement tags" do
    playbook = File.tempname("debug-var-block-tag", ".yml")
    File.write(playbook, <<-YAML)
      - name: repro
        hosts: localhost
        gather_facts: false
        tasks:
          - name: statement block
            ansible.builtin.debug:
              var: krikri_spec_stmt
            vars:
              krikri_spec_stmt: "{% if true %}yes{% else %}no{% endif %}"
          - name: folded multiline block
            ansible.builtin.debug:
              var: krikri_spec_folded
            vars:
              krikri_spec_folded: >-
                {% if true %}
                multi
                {% endif %}
          - name: loop block
            ansible.builtin.debug:
              var: krikri_spec_loop
            vars:
              krikri_spec_loop: "{% for i in [1, 2] %}{{ i }}{% endfor %}"
          - name: comment only renders null
            ansible.builtin.debug:
              var: krikri_spec_comment
            vars:
              krikri_spec_comment: "{# just a comment #}"
          - name: false branch renders null
            ansible.builtin.debug:
              var: krikri_spec_false
            vars:
              krikri_spec_false: "{% if false %}x{% endif %}"
          - name: empty expression stays empty
            ansible.builtin.debug:
              var: krikri_spec_empty
            vars:
              krikri_spec_empty: "{{ '' }}"
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)

    status.success?.must_equal(true)
    output.to_s.must_include(%("krikri_spec_stmt": "yes"))
    output.to_s.must_include(%("krikri_spec_folded": " multi "))
    output.to_s.must_include(%("krikri_spec_loop": "12"))
    output.to_s.must_include(%("krikri_spec_comment": null))
    output.to_s.must_include(%("krikri_spec_false": null))
    output.to_s.must_include(%("krikri_spec_empty": ""))
    output.to_s.wont_include("{%")
  ensure
    File.delete(playbook) if playbook && File.exists?(playbook)
  end

  # ansible-core's debug evaluates the raw `var` text as a Jinja
  # EXPRESSION (action/debug.py: evaluate_expression(raw_var_arg)), so a
  # filter chain resolves to its value while the result key keeps the raw
  # text. Live-verified against 2.21.6, and the exact shape
  # hurricanehrndz.sssd ships (issue #970): the chain used to be reported
  # as an undefined NAME.
  it "evaluates the var: text as an expression, under the raw text as key" do
    playbook = File.tempname("debug-var-expression", ".yml")
    File.write(playbook, <<-YAML)
      - name: repro
        hosts: localhost
        gather_facts: false
        tasks:
          - name: filtered default debug
            ansible.builtin.debug:
              var: krikri_spec_undefined_var_zzz|default(false)
          - name: is defined debug
            ansible.builtin.debug:
              var: krikri_spec_undefined_var_zzz is defined
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)

    status.success?.must_equal(true)
    output.to_s.must_include(%("krikri_spec_undefined_var_zzz|default(false)": false))
    output.to_s.must_include(%("krikri_spec_undefined_var_zzz is defined": false))
    output.to_s.wont_include("is undefined >>")
  ensure
    File.delete(playbook) if playbook && File.exists?(playbook)
  end
end
