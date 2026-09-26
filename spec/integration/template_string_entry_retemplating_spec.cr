require "../spec_helper"

# Runs the compiled binary against a real playbook (real .j2 template
# rendering via TemplateActionPlugin's variable preparation), since the bug
# lives in that preparation path, not in the engine itself.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "spec", "fixtures", "inventory-explicit-localhost.ini")

# A variable value that is itself a Jinja-containing string must be fully
# re-templated - recursively, to a fixed point, PRESERVING TYPES - before a
# .j2 template sees it. Real Ansible re-templates a list entry whose whole
# value is one `{{ }}` expression that evaluates to a dict into a REAL dict,
# so `{% for item in list %}{{ item.items() }}` works; rendering that entry
# to a substituted STRING (dict.update-then-discard style text, or the
# JSON-text of a sibling list) leaves it a str and the attribute access
# fails. Rounds 975058/975059 (jtyr.motd, jtyr.sudo: "object of type 'str'
# has no attribute 'items'") and 975081 (Oefenweb.sudoers: same shape, via
# `.name`).
describe "a .j2 template over a variable whose string value evaluates to a container" do
  it "re-templates a list entry that is a string evaluating to a dict into a real dict (.items() access)" do
    template = File.tempname("retempl-list-entry", ".j2")
    dest = File.tempname("retempl-list-entry-out")
    playbook = File.tempname("retempl-list-entry", ".yml")
    File.write(template, <<-J2)
      {% for item in info %}
        {%- for key, value in item.items() %}
      {{ key }}={{ value }}
        {%- endfor %}
      {% endfor %}
      J2

    # jtyr.motd's own defaults shape: the second entry is a bare string
    # whose `{{ }}` evaluates (via a Jinja conditional expression) to a
    # dict; the surrounding entries are ordinary dict literals.
    File.write(playbook, <<-YAML)
      - name: repro
        hosts: localhost
        gather_facts: false
        vars:
          info__custom: []
          info__default:
            - First: "{{ greeting }}"
            - "{{ { 'K': ('v1\\n' if newline else 'v1') } }}"
            - Third: "{{ plain }}"
          info: "{{ info__default + info__custom }}"
          greeting: hello
          plain: world
          newline: true
        tasks:
          - name: render
            ansible.builtin.template:
              src: #{template}
              dest: #{dest}
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)

    status.success?.should be_true, output.to_s
    rendered = File.read(dest)
    rendered.should contain("First=hello")
    rendered.should contain("K=v1")
    rendered.should_not contain("{{")
  ensure
    File.delete(template) if template && File.exists?(template)
    File.delete(dest) if dest && File.exists?(dest)
    File.delete(playbook) if playbook && File.exists?(playbook)
  end

  it "re-templates a dict value that is a string evaluating to a list into a real list (.name attribute access)" do
    template = File.tempname("retempl-dict-value", ".j2")
    dest = File.tempname("retempl-dict-value-out")
    playbook = File.tempname("retempl-dict-value", ".yml")
    File.write(template, <<-J2)
      {% for item in sudoers.privileges %}
      {{ item.name }} {{ item.entry }}
      {% endfor %}
      {% for opt in sudoers.defaults %}
      {{ opt }}
      {% endfor %}
      J2

    # Oefenweb.sudoers' own defaults shape: every value of the dict the
    # template iterates into is itself a bare `{{ preset }}` string whose
    # evaluation yields the real list.
    File.write(playbook, <<-YAML)
      - name: repro
        hosts: localhost
        gather_facts: false
        vars:
          sudoers:
            defaults: "{{ preset_defaults }}"
            privileges: "{{ preset_privileges }}"
          preset_defaults:
            - env_reset
            - 'secure_path="/usr/local/sbin:/usr/local/bin"'
          preset_privileges:
            - name: root
              entry: 'ALL=(ALL:ALL) ALL'
            - name: '%sudo'
              entry: 'ALL=(ALL:ALL) ALL'
        tasks:
          - name: render
            ansible.builtin.template:
              src: #{template}
              dest: #{dest}
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)

    status.success?.should be_true, output.to_s
    rendered = File.read(dest)
    rendered.should contain("root ALL=(ALL:ALL) ALL")
    rendered.should contain("%sudo ALL=(ALL:ALL) ALL")
    rendered.should contain("env_reset")
    rendered.should_not contain("{{")
  ensure
    File.delete(template) if template && File.exists?(template)
    File.delete(dest) if dest && File.exists?(dest)
    File.delete(playbook) if playbook && File.exists?(playbook)
  end
end
