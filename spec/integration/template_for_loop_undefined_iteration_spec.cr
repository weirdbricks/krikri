require "../spec_helper"

# Runs the compiled binary against a real playbook (real .j2 template
# rendering via JinjaRenderer/TemplateActionPlugin), since this bug is
# specifically about the vendored Crinja fork's evaluator, not the
# hand-rolled plain {{ }} evaluator.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "spec", "fixtures", "inventory-explicit-localhost.ini")

describe "a {% for %} loop over an undefined variable" do
  it "fails the task instead of silently rendering zero iterations" do
    # Real bug found benchmarking ahuffman.resolv (round 159, crinja
    # crystal-play-0.9.15). Its own resolv.conf.j2 guards
    # resolv_search/resolv_domain/resolv_sortlist/resolv_options with
    # `is defined` before use, but not resolv_nameservers - real
    # ansible-playbook fails the whole render with
    # "'resolv_nameservers' is undefined" when that var is never set,
    # while crinja's plain (non-strict) Undefined used to iterate as
    # an empty sequence and quietly succeed. Real Jinja2's own vanilla
    # default Undefined does NOT raise here (Ansible's environment is
    # stricter than vanilla Jinja2 for this specific operation), so
    # crinja's own for-tag specs (ported from pallets/jinja) were
    # updated rather than left as the target behavior - see crinja's
    # spec/tags/for_spec.cr and spec/runtime/value_spec.cr.
    src = File.tempname("for-loop-undefined-src", ".j2")
    dest = File.tempname("for-loop-undefined-dest")
    playbook = File.tempname("for-loop-undefined", ".yml")
    File.write(src, "{% for ns in resolv_nameservers %}\nnameserver {{ ns }}\n{% endfor %}\n")

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

    status.success?.should be_false
    # Real ansible-core 2.19.11's failure wording for the same render
    # ("msg": "Task failed: 'resolv_nameservers' is undefined") - NOT
    # Crinja's internal TypeError text "can't iterate over undefined"
    # that used to leak through as the render error detail.
    output.to_s.should contain("'resolv_nameservers' is undefined")
    output.to_s.should_not contain("can't iterate over undefined")
    File.exists?(dest).should be_false
  ensure
    File.delete(playbook) if playbook && File.exists?(playbook)
    File.delete(src) if src && File.exists?(src)
    File.delete(dest) if dest && File.exists?(dest)
  end

  it "reports the real-Ansible undefined wording for a {% for %}...{% else %} over an unset variable" do
    # Same raise as the plain-for case above, exercised through the
    # for-else form: real ansible-core 2.19.11 fails the template task
    # with msg "Task failed: 'missing' is undefined" (the UndefinedError
    # wording), while krikri used to surface Crinja's internal
    # TypeError detail "Failed to render template: can't iterate over
    # undefined" - functionally the same failure, cosmetically divergent.
    src = File.tempname("for-else-undefined-src", ".j2")
    dest = File.tempname("for-else-undefined-dest")
    playbook = File.tempname("for-else-undefined", ".yml")
    File.write(src, "{% for item in missing %}x{% else %}EMPTY{% endfor %}\n")

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

    status.success?.should be_false
    output.to_s.should contain("'missing' is undefined")
    output.to_s.should_not contain("can't iterate over undefined")
    File.exists?(dest).should be_false
  ensure
    File.delete(playbook) if playbook && File.exists?(playbook)
    File.delete(src) if src && File.exists?(src)
    File.delete(dest) if dest && File.exists?(dest)
  end
end
