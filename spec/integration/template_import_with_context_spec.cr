require "../spec_helper"
require "file_utils"

# Runs the compiled binary against a real playbook - the bug is in the
# vendored Crinja fork's {% import %} tag parser, which needs the real
# TemplateActionPlugin rendering path to exercise cleanly.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")

describe "template:'s {% import 'x.j2' with context %} modifier" do
  it "renders a template using import ... with context without a parse error" do
    # Real bug found in a 150-role overnight round (manala.influxdb):
    # its own config template does `{%- import '_macros.j2' as macros
    # with context -%}` - real Jinja2's `with context`/`without
    # context` modifier, never parsed at all by the vendored Crinja
    # fork ("Did not expect any more tokens, found: IDENTIFIER:with").
    # Fixed in fork release crystal-play-0.9.29.
    dir = File.tempname("template-import-with-context-spec")
    Dir.mkdir_p(dir)
    macros_src = File.join(dir, "_macros.j2")
    tpl_src = File.join(dir, "config.j2")
    dest = File.join(dir, "config.out")
    playbook = File.join(dir, "site.yml")
    File.write(macros_src, "{% macro greet() %}hello{% endmacro %}\n")
    File.write(tpl_src, "{%- import '_macros.j2' as macros with context -%}\n{{ macros.greet() }}\n")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - ansible.builtin.template:
              src: #{tpl_src}
              dest: #{dest}
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", "/dev/null", playbook], output: output, error: output)

    status.success?.should be_true
    File.read(dest).strip.should eq("hello")
  ensure
    FileUtils.rm_rf(dir) if dir
  end
end
