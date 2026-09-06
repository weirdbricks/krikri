require "../spec_helper"
require "file_utils"

# Runs the compiled binary against a real playbook - template_destpath
# is injected by TemplateActionPlugin's own controller-side rendering
# path, which needs the real `template:` action end to end to exercise.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")

describe "template:'s template_destpath magic var" do
  it "exposes the task's own (already-rendered) dest: as template_destpath inside the template" do
    # Real bug found in a 150-role overnight round (inmotionhosting.
    # monit): its own templates/etc/systemd/restart.conf.j2 starts with
    # `# {{ template_destpath }}` - a common convention for stamping a
    # template's destination as a comment for auditability. Real
    # Ansible's template action plugin has injected template_destpath
    # (alongside template_host/template_path/template_fullpath/
    # template_run_date, all already implemented here) since 2.8;
    # krikri had every OTHER one of these magic vars but not this one,
    # so any template referencing it failed "Failed to render template:
    # 'template_destpath' is undefined".
    dir = File.tempname("template-destpath-spec")
    Dir.mkdir_p(dir)
    src = File.join(dir, "tpl.j2")
    dest = File.join(dir, "rendered-out.conf")
    playbook = File.join(dir, "site.yml")
    File.write(src, "# {{ template_destpath }}\nhello\n")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - ansible.builtin.template:
              src: #{src}
              dest: #{dest}
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", "/dev/null", playbook], output: output, error: output)

    status.success?.should be_true
    File.read(dest).should eq("# #{dest}\nhello\n")
  ensure
    FileUtils.rm_rf(dir) if dir
  end
end
