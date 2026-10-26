require "../minitest_helper"

# Ansible/Jinja2 compile the whole template before any of it renders, so
# every filter name in the file is resolved at COMPILE time: an unknown
# filter fails the template task even when the branch holding it never
# executes (an `{% if false %}` branch, an `{% if %}` over an empty list -
# issue #651, live-verified vs 2.19.11). The engine itself only raises when
# a filter node is evaluated, so before this the dead branch passed
# silently and the task reported changed where real fails.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "test", "fixtures", "inventory-explicit-localhost.ini")

describe "template compiles filter names in never-executed branches" do
  it "fails the template task for an unknown filter inside a dead {% if %} branch" do
    src = File.tempname("dead-branch-unknown-filter", ".j2")
    dest = File.tempname("dead-branch-unknown-filter-dest")
    playbook = File.tempname("dead-branch-unknown-filter", ".yml")
    File.write(src, <<-J2)
      {% if false %}
      {{ name | ansible.netcommon.ipaddr('revdns') }}
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
    text = output.to_s

    status.success?.must_equal(false)
    text.must_include("Syntax error in template: No filter named 'ansible.netcommon.ipaddr'.")
    text.wont_include("Failed to render template")
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
