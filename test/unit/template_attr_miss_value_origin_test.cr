require "../minitest_helper"

# Issue #451 (chris1984.motd) - the template action's attribute-miss crash
# ("object of type 'dict' has no attribute 'iteritems'") raised while
# rendering a VARIABLE's own template value (a role default read through
# `{{ motd_content }}` in the .j2 file) used to lose the "<<< caused by >>>"
# stanza's Origin to the template file, because the undefined-chain scan
# only matched the "'x' is undefined" message shape. Real ansible-core
# 2.19.11 points that Origin at the failing VALUE's definition
# (defaults/main.yml, caret at the value token), while a miss that happens
# in the TEMPLATE FILE itself keeps the template-file Origin - both
# live-verified against 2.19.11.

private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")

describe "template attribute-miss value origin" do
  it "pins the caused-by Origin at the failing value's definition" do
    src_dir = PluginSpecHelper.tmp_path("template-attr-miss-origin", "role")
    Dir.mkdir_p(File.join(src_dir, "roles", "amtest", "defaults"))
    Dir.mkdir_p(File.join(src_dir, "roles", "amtest", "tasks"))
    Dir.mkdir_p(File.join(src_dir, "roles", "amtest", "templates"))
    defaults = File.join(src_dir, "roles", "amtest", "defaults", "main.yml")
    File.write(defaults, <<-YAML)
      ---
      hostname: myhost
      info:
        - " A: ": "{{ hostname }}"
      motd_content: |
        {% for item in info %}
        {% for key, value in item.iteritems() %}
        {{ key }}{{ value }}
        {% endfor %}
        {% endfor %}
      YAML
    File.write(File.join(src_dir, "roles", "amtest", "templates", "motd.j2"), "{{ motd_content }}\n")
    File.write(File.join(src_dir, "roles", "amtest", "tasks", "main.yml"), <<-YAML)
      ---
      - name: Set MOTD on remote machine
        ansible.builtin.template:
          src: motd.j2
          dest: #{File.join(src_dir, "out.txt")}
      YAML
    playbook = File.join(src_dir, "pb.yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        roles:
          - amtest
      YAML

    stdout = IO::Memory.new
    Process.run(BINARY, ["-i", File.join(__DIR__, "..", "fixtures", "inventory-localhost-local.ini"), playbook], output: stdout, error: Process::Redirect::Inherit)
    text = stdout.to_s

    text.must_include("[ERROR]: Task failed: object of type 'dict' has no attribute 'iteritems'")
    text.must_include("<<< caused by >>>")
    # The value token's own start mark: `motd_content: |` puts the block
    # scalar indicator at column 15, the same position real 2.19.11's
    # caret lands on for the repro role.
    text.must_include("object of type 'dict' has no attribute 'iteritems'\nOrigin: #{defaults}:5:15")
  end

  it "keeps the template-file Origin when the miss is in the template itself" do
    src_dir = PluginSpecHelper.tmp_path("template-attr-miss-file", "role")
    Dir.mkdir_p(File.join(src_dir, "roles", "amtest2", "defaults"))
    Dir.mkdir_p(File.join(src_dir, "roles", "amtest2", "tasks"))
    Dir.mkdir_p(File.join(src_dir, "roles", "amtest2", "templates"))
    File.write(File.join(src_dir, "roles", "amtest2", "defaults", "main.yml"), <<-YAML)
      ---
      info:
        - name: one
      YAML
    template = File.join(src_dir, "roles", "amtest2", "templates", "motd.j2")
    File.write(template, "{{ info[0].nope }}\n")
    File.write(File.join(src_dir, "roles", "amtest2", "tasks", "main.yml"), <<-YAML)
      ---
      - name: Set MOTD on remote machine
        ansible.builtin.template:
          src: motd.j2
          dest: #{File.join(src_dir, "out.txt")}
      YAML
    playbook = File.join(src_dir, "pb.yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        roles:
          - amtest2
      YAML

    stdout = IO::Memory.new
    Process.run(BINARY, ["-i", File.join(__DIR__, "..", "fixtures", "inventory-localhost-local.ini"), playbook], output: stdout, error: Process::Redirect::Inherit)
    text = stdout.to_s

    text.must_include("[ERROR]: Task failed: object of type 'dict' has no attribute 'nope'")
    # No var layer holds a template value failing this way, so the scan
    # must not hijack the crash-shape default: the template file itself.
    text.must_include("object of type 'dict' has no attribute 'nope'\nOrigin: #{template}")
  end
end
