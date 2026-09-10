require "../spec_helper"

# Runs the compiled binary against a real .j2 template file (the
# vendored-Crinja rendering path, separate from the hand-rolled {{ }}
# evaluator that spec/unit/conditional_evaluator_spec.cr already covers
# for the same bug shape).
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "spec", "fixtures", "inventory-explicit-localhost.ini")

describe "in <string> with an undefined left operand in a real .j2 template" do
  it "raises the real Jinja2/ansible-core TypeError instead of silently coercing to true" do
    # Round71000's asg1612.gluster: `{% if node_1 in "..." %}` with
    # node_1 never defined. Real Jinja2 evaluates `x in y` as
    # `y.__contains__(x)`; a Python str.__contains__ requires its
    # argument to itself be a str, so the Undefined marker (Jinja2
    # defers the undefined raise to force time) hits Python's own
    # TypeError: "'in <string>' requires string as left operand, not
    # UndefinedMarker". The vendored crinja fork previously stringified
    # the marker to "" (a substring of everything) instead, silently
    # returning true under the default lenient mode. Fixed in the fork
    # (weirdbricks/crinja, tag crystal-play-0.9.30).
    src = File.tempname("crinja-in-undef-src", ".j2")
    playbook = File.tempname("crinja-in-undef", ".yml")
    File.write(src, %({% if node_1 in "some-string-value" %}yes{% else %}no{% endif %}\n))

    File.write(playbook, <<-YAML)
      - name: repro
        hosts: localhost
        gather_facts: false
        tasks:
          - name: render
            ansible.builtin.template:
              src: #{src}
              dest: /tmp/crinja-in-undef-dest-#{Random.rand(1_000_000)}
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)

    status.success?.should be_false
    output.to_s.should contain("'in <string>' requires string as left operand, not UndefinedMarker")
  ensure
    File.delete(playbook) if playbook && File.exists?(playbook)
    File.delete(src) if src && File.exists?(src)
  end

  it "still treats undefined in a LIST leniently as False, matching Python's list.__contains__" do
    src = File.tempname("crinja-in-list-src", ".j2")
    dest = File.tempname("crinja-in-list-dest")
    playbook = File.tempname("crinja-in-list", ".yml")
    File.write(src, "{% if node_1 in ['a', 'b'] %}yes{% else %}no{% endif %}\n")

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

    status.success?.should be_true
    File.read(dest).should eq("no\n")
  ensure
    File.delete(playbook) if playbook && File.exists?(playbook)
    File.delete(src) if src && File.exists?(src)
    File.delete(dest) if dest && File.exists?(dest)
  end
end
