require "../spec_helper"
require "file_utils"

# Runs the compiled binary against a real playbook - the bug is in
# TemplateActionPlugin's Crinja loader setup, which needs a real nested
# templates/ directory and {% include %} to exercise cleanly.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "spec", "fixtures", "inventory-explicit-localhost.ini")

describe "template:'s {% include %} resolves against the role's templates/ root, not just the CWD" do
  it "finds a bare-filename {% include %} target that lives beside the including template, several directories under templates/" do
    # Real bug found benchmarking Oefenweb.haproxy (round 196): its
    # haproxy.cfg.j2 (at templates/etc/haproxy/haproxy.cfg.j2) does
    # `{% include 'global.cfg.j2' %}` - a bare filename, resolved by
    # real Ansible's own Jinja2 FileSystemLoader against the role's
    # templates/ directory (and everything under it), so a sibling file
    # in the SAME subdirectory as the including template resolves fine
    # regardless of how deep it is. Crinja's default loader only
    # searches the process CWD (the work dir), so this failed with
    # "template global.cfg.j2 could not be found by
    # FileSystemLoader(<work dir>)" while real ansible-playbook
    # rc=0'd. Fixed in template_action_plugin.cr by rooting the Crinja
    # loader's searchpath at the including template's own directory,
    # walking up to and including the role's templates/ root.
    src_dir = File.tempname("template-include-search-path-role")
    Dir.mkdir_p(File.join(src_dir, "roles", "myrole", "templates", "etc", "haproxy"))
    Dir.mkdir_p(File.join(src_dir, "roles", "myrole", "tasks"))
    File.write(File.join(src_dir, "roles", "myrole", "templates", "etc", "haproxy", "haproxy.cfg.j2"), <<-J2)
      top
      {% include 'global.cfg.j2' %}
      bottom
      J2
    File.write(File.join(src_dir, "roles", "myrole", "templates", "etc", "haproxy", "global.cfg.j2"), "middle\n")
    File.write(File.join(src_dir, "roles", "myrole", "tasks", "main.yml"), <<-YAML)
      - name: render
        template:
          src: etc/haproxy/haproxy.cfg.j2
          dest: #{File.join(src_dir, "out.cfg")}
      YAML

    playbook = File.join(src_dir, "pb.yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        roles:
          - myrole
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output, chdir: src_dir)

    status.success?.should be_true
    output.to_s.should_not contain("could not be found")
    File.read(File.join(src_dir, "out.cfg")).should eq("top\nmiddlebottom\n")
  ensure
    FileUtils.rm_rf(src_dir) if src_dir
  end
end
