require "../minitest_helper"

# Runs the compiled binary against a real playbook (real template
# rendering through TemplateActionPlugin), since this bug is about the
# inline-ternary handling in the template action plugin's rewrite pass.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "test", "fixtures", "inventory-explicit-localhost.ini")

# Round 5460382 (rolehippie.prometheus): the Crinja-era text rewrite
# turned every inline ternary `{{ A if C else B }}` into `C | ternary(A,
# B)`, whose filter arguments are evaluated EAGERLY - so an untaken
# branch containing an invalid expression failed the whole render.
# rolehippie.prometheus's own default.j2 concatenates
# `' --storage.tsdb.retention.size=' + prometheus_tsdb_retention_size`
# guarded by `... if ... | default(false) else ''` where the var
# defaults to null: real Jinja2 (lazy conditional expression) never
# evaluates the untaken branch and renders fine, krikri failed with
# "unsupported operands for +: String and Nil". krikri-jinja parses
# inline ternaries natively and lazily, so the rewrite is gone.
describe "an inline ternary whose untaken branch is an invalid expression" do
  it "skips the untaken branch when the var is defined but null" do
    src = File.tempname("ternary-nil-src", ".j2")
    dest = File.tempname("ternary-nil-dest")
    playbook = File.tempname("ternary-nil", ".yml")
    File.write(src, "ARGS=\"--x{{ 'A' + nilvar if nilvar | default(false) else '' }}--y\"\n")

    File.write(playbook, <<-YAML)
      - name: repro
        hosts: localhost
        gather_facts: false
        vars:
          nilvar: null
        tasks:
          - name: render
            ansible.builtin.template:
              src: #{src}
              dest: #{dest}
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)

    status.success?.must_equal(true)
    File.read(dest).must_equal("ARGS=\"--x--y\"\n")
  ensure
    File.delete(playbook) if playbook && File.exists?(playbook)
    File.delete(src) if src && File.exists?(src)
    File.delete(dest) if dest && File.exists?(dest)
  end

  it "skips the untaken branch when the var is entirely undefined" do
    src = File.tempname("ternary-undef-src", ".j2")
    dest = File.tempname("ternary-undef-dest")
    playbook = File.tempname("ternary-undef", ".yml")
    File.write(src, "ARGS=\"--x{{ 'A' + nowhere_var if nowhere_var | default(false) else '' }}--y\"\n")

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

    status.success?.must_equal(true)
    File.read(dest).must_equal("ARGS=\"--x--y\"\n")
  ensure
    File.delete(playbook) if playbook && File.exists?(playbook)
    File.delete(src) if src && File.exists?(src)
    File.delete(dest) if dest && File.exists?(dest)
  end

  it "still evaluates and takes the branch when the condition is truthy" do
    src = File.tempname("ternary-taken-src", ".j2")
    dest = File.tempname("ternary-taken-dest")
    playbook = File.tempname("ternary-taken", ".yml")
    File.write(src, "ARGS=\"--x{{ 'A' + strvar if strvar | default(false) else '' }}--y\"\n")

    File.write(playbook, <<-YAML)
      - name: repro
        hosts: localhost
        gather_facts: false
        vars:
          strvar: 30d
        tasks:
          - name: render
            ansible.builtin.template:
              src: #{src}
              dest: #{dest}
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)

    status.success?.must_equal(true)
    File.read(dest).must_equal("ARGS=\"--xA30d--y\"\n")
  ensure
    File.delete(playbook) if playbook && File.exists?(playbook)
    File.delete(src) if src && File.exists?(src)
    File.delete(dest) if dest && File.exists?(dest)
  end

  it "renders an else-less ternary as empty when the condition is false" do
    src = File.tempname("ternary-noelse-src", ".j2")
    dest = File.tempname("ternary-noelse-dest")
    playbook = File.tempname("ternary-noelse", ".yml")
    File.write(src, "ARGS=\"--x{{ 'A' if nilvar | default(false) }}--y\"\n")

    File.write(playbook, <<-YAML)
      - name: repro
        hosts: localhost
        gather_facts: false
        vars:
          nilvar: null
        tasks:
          - name: render
            ansible.builtin.template:
              src: #{src}
              dest: #{dest}
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)

    status.success?.must_equal(true)
    File.read(dest).must_equal("ARGS=\"--x--y\"\n")
  ensure
    File.delete(playbook) if playbook && File.exists?(playbook)
    File.delete(src) if src && File.exists?(src)
    File.delete(dest) if dest && File.exists?(dest)
  end
end
