require "../minitest_helper"

# Jinja2's compiler only resolves a filter name at COMPILE time when its
# frame is not soft: a filter whose nearest enclosing construct is an if
# branch or a conditional expression is deferred (compiler.py's
# _filter_test_common fails only "when not frame.soft_frame") and real
# ansible-core 2.19.11 passes the template task unless the branch actually
# executes - then it fails with the render-time wording. A for resets the
# frame (Frame.inner() resets soft_frame), so a for nested in a dead if,
# or a for over an empty list, still fails at compile time (issue #660).
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "test", "fixtures", "inventory-explicit-localhost.ini")

describe "template compiles filter names in never-executed branches" do
  it "passes the template task for an unknown filter inside a dead {% if %} branch" do
    src = File.tempname("dead-branch-unknown-filter", ".j2")
    dest = File.tempname("dead-branch-unknown-filter-dest")
    playbook = File.tempname("dead-branch-unknown-filter", ".yml")
    File.write(src, <<-J2)
      {% if false %}
      {{ name | krikri_verify_nofilter_xyz }}
      {% endif %}
      static-marker
      J2

    File.write(playbook, <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        vars:
          name: something
        tasks:
          - template:
              src: #{src}
              dest: #{dest}
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)
    text = output.to_s

    status.success?.must_equal(true)
    text.wont_include("No filter named")
    File.read(dest).must_include("static-marker")
  ensure
    File.delete(playbook) if playbook && File.exists?(playbook)
    File.delete(src) if src && File.exists?(src)
    File.delete(dest) if dest && File.exists?(dest)
  end

  it "passes the template task for an unknown filter in a dead conditional expression arm" do
    src = File.tempname("dead-condexpr-unknown-filter", ".j2")
    dest = File.tempname("dead-condexpr-unknown-filter-dest")
    playbook = File.tempname("dead-condexpr-unknown-filter", ".yml")
    File.write(src, <<-J2)
      x = {{ 'a' | krikri_verify_nofilter_xyz if cond else 'b' }}
      J2

    File.write(playbook, <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        vars:
          cond: false
        tasks:
          - template:
              src: #{src}
              dest: #{dest}
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)
    text = output.to_s

    status.success?.must_equal(true)
    text.wont_include("No filter named")
    File.read(dest).must_include("x = b")
  ensure
    File.delete(playbook) if playbook && File.exists?(playbook)
    File.delete(src) if src && File.exists?(src)
    File.delete(dest) if dest && File.exists?(dest)
  end

  it "fails the template task with the render wording when the dead if branch is taken" do
    src = File.tempname("live-branch-unknown-filter", ".j2")
    dest = File.tempname("live-branch-unknown-filter-dest")
    playbook = File.tempname("live-branch-unknown-filter", ".yml")
    File.write(src, <<-J2)
      {% if cond %}x = {{ 'a' | krikri_verify_nofilter_xyz }}{% endif %}
      J2

    File.write(playbook, <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        vars:
          cond: true
        tasks:
          - template:
              src: #{src}
              dest: #{dest}
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)
    text = output.to_s

    status.success?.must_equal(false)
    text.must_include("Error rendering template: No filter named 'krikri_verify_nofilter_xyz' found.")
    text.wont_include("Syntax error in template: No filter named")
    File.exists?(dest).must_equal(false)
  ensure
    File.delete(playbook) if playbook && File.exists?(playbook)
    File.delete(src) if src && File.exists?(src)
    File.delete(dest) if dest && File.exists?(dest)
  end

  it "fails the template task at compile time for a for nested in a dead {% if %} branch" do
    src = File.tempname("dead-if-live-for-unknown-filter", ".j2")
    dest = File.tempname("dead-if-live-for-unknown-filter-dest")
    playbook = File.tempname("dead-if-live-for-unknown-filter", ".yml")
    File.write(src, <<-J2)
      {% if cond %}{% for x in [1] %}{{ x | krikri_verify_nofilter_xyz }}{% endfor %}{% endif %}
      J2

    File.write(playbook, <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        vars:
          cond: false
        tasks:
          - template:
              src: #{src}
              dest: #{dest}
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)
    text = output.to_s

    status.success?.must_equal(false)
    text.must_include("Syntax error in template: No filter named 'krikri_verify_nofilter_xyz'.")
    text.wont_include("Error rendering template")
    File.exists?(dest).must_equal(false)
  ensure
    File.delete(playbook) if playbook && File.exists?(playbook)
    File.delete(src) if src && File.exists?(src)
    File.delete(dest) if dest && File.exists?(dest)
  end

  it "fails the template task at compile time for an unknown filter in a for over an empty list" do
    src = File.tempname("empty-for-unknown-filter", ".j2")
    dest = File.tempname("empty-for-unknown-filter-dest")
    playbook = File.tempname("empty-for-unknown-filter", ".yml")
    File.write(src, <<-J2)
      {% for x in empty_list %}ping = {{ x | krikri_verify_nofilter_xyz }}{% endfor %}
      J2

    File.write(playbook, <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        vars:
          empty_list: []
        tasks:
          - template:
              src: #{src}
              dest: #{dest}
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)
    text = output.to_s

    status.success?.must_equal(false)
    text.must_include("Syntax error in template: No filter named 'krikri_verify_nofilter_xyz'.")
    File.exists?(dest).must_equal(false)
  ensure
    File.delete(playbook) if playbook && File.exists?(playbook)
    File.delete(src) if src && File.exists?(src)
    File.delete(dest) if dest && File.exists?(dest)
  end

  it "fails the template task at compile time for a top-level collection-qualified unknown filter" do
    src = File.tempname("toplevel-unknown-filter", ".j2")
    dest = File.tempname("toplevel-unknown-filter-dest")
    playbook = File.tempname("toplevel-unknown-filter", ".yml")
    File.write(src, <<-J2)
      rev = {{ name | ansible.netcommon.ipaddr('revdns') }}
      J2

    File.write(playbook, <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        vars:
          name: something
        tasks:
          - template:
              src: #{src}
              dest: #{dest}
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)
    text = output.to_s

    status.success?.must_equal(false)
    text.must_include("Syntax error in template: No filter named 'ansible.netcommon.ipaddr'.")
    text.wont_include("Error rendering template")
    File.exists?(dest).must_equal(false)
  ensure
    File.delete(playbook) if playbook && File.exists?(playbook)
    File.delete(src) if src && File.exists?(src)
    File.delete(dest) if dest && File.exists?(dest)
  end

  it "still renders a known filter in the same dead-branch position" do
    src = File.tempname("dead-branch-known-filter", ".j2")
    dest = File.tempname("dead-branch-known-filter-dest")
    playbook = File.tempname("dead-branch-known-filter", ".yml")
    File.write(src, <<-J2)
      {% if false %}
      {{ name | upper }}
      {% endif %}
      static-marker
      J2

    File.write(playbook, <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - template:
              src: #{src}
              dest: #{dest}
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)

    status.success?.must_equal(true)
    File.read(dest).must_include("static-marker")
  ensure
    File.delete(playbook) if playbook && File.exists?(playbook)
    File.delete(src) if src && File.exists?(src)
    File.delete(dest) if dest && File.exists?(dest)
  end
end
