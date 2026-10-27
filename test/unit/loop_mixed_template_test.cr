require "../minitest_helper"

# Issue #573 - a with_items: source that is MIXED literal text plus one
# {{ }} expression ("{{ os | lower }}.yml") used to hit the bare-
# expression evaluator with the whole mixed text, which produced the
# "undefined" sentinel and a spurious "'{{ os | lower }}' is undefined"
# failure. Real ansible-playbook templates the whole loop-source string
# and with_items scalar-wraps the rendered result (live-verified vs
# ansible-playbook 2.19: item=debian.yml). A whole-string single
# expression and a list-wrapped element already worked; this covers the
# mixed shape. An undefined name inside the mixed text must still fail
# strictly (strict: true), not silently iterate.

private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")

describe "loop mixed literal-plus-expression source" do
  it "renders mixed with_items text and iterates the scalar once" do
    src_dir = PluginSpecHelper.tmp_path("loop-mixed-template", "ok")
    Dir.mkdir_p(src_dir)
    playbook = File.join(src_dir, "pb.yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        vars:
          os: Debian
        tasks:
          - name: Show rendered item
            ansible.builtin.debug:
              msg: "{{ item }}"
            with_items: "{{ os | lower }}.yml"
      YAML

    stdout = IO::Memory.new
    Process.run(BINARY, ["-i", "localhost,", playbook], output: stdout, error: Process::Redirect::Inherit)
    text = stdout.to_s

    text.must_include("item=debian.yml")
    text.must_include("\"msg\": \"debian.yml\"")
    text.must_include("failed=0")
  end

  it "fails strictly for an undefined name inside mixed with_items text" do
    src_dir = PluginSpecHelper.tmp_path("loop-mixed-template", "undefined")
    Dir.mkdir_p(src_dir)
    playbook = File.join(src_dir, "pb.yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: Show undefined item
            ansible.builtin.debug:
              msg: "{{ item }}"
            with_items: "{{ nope_undefined }}.yml"
      YAML

    stdout = IO::Memory.new
    Process.run(BINARY, ["-i", "localhost,", playbook], output: stdout, error: Process::Redirect::Inherit)
    text = stdout.to_s

    text.must_include("'nope_undefined' is undefined")
    text.must_include("failed=1")
  end
end
