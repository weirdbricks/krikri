require "../spec_helper"

# Runs the compiled binary against a real playbook (real template
# rendering through TemplateActionPlugin's `{% if %}` in:/not in:
# rewrite pass), since this bug is specifically about
# TemplateActionPlugin#rewrite_in_expr, a private method.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY        = File.join(PROJECT_ROOT, "bin", "crystal-ansible")
private INVENTORY     = File.join(PROJECT_ROOT, "spec", "fixtures", "inventory-explicit-localhost.ini")

describe "a real Jinja2 `in` test inside {% if %} against a variable-bound list" do
  it "works against a dotted-path container, not just a literal list" do
    # Real bug found benchmarking dev-sec.os-hardening's own "rebuild
    # initramfs" task template: `{% if ('amd' in ansible_facts.
    # processor) | pytruthy %}`. #rewrite_in_expr only ever recognized a
    # `[...]` literal or a `(...)` tuple as the container - a bare
    # variable/dotted-path reference (`ansible_facts.processor`, far
    # more common in real roles than an inline literal list) fell
    # through unrewritten, leaving Crinja's own unsupported infix `in`
    # operator untouched and failing the whole template render outright
    # ("Expected RIGHT_PAREN, got IDENTIFIER").
    src = File.tempname("in-operator-src", ".j2")
    dest = File.tempname("in-operator-dest")
    playbook = File.tempname("in-operator", ".yml")
    File.write(src, "{% if 'amd' in cpu_list %}AMD{% else %}NOT AMD{% endif %}\n")

    File.write(playbook, <<-YAML)
      - name: repro
        hosts: localhost
        gather_facts: false
        vars:
          cpu_list: ["0", "amd", "AMD EPYC"]
        tasks:
          - name: render
            ansible.builtin.template:
              src: #{src}
              dest: #{dest}
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)

    status.success?.should be_true
    File.read(dest).should eq("AMD\n")
  ensure
    File.delete(playbook) if playbook && File.exists?(playbook)
    File.delete(src) if src && File.exists?(src)
    File.delete(dest) if dest && File.exists?(dest)
  end
end
