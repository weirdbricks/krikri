require "../minitest_helper"
require "file_utils"

# Runs the compiled binary against a real playbook.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "test", "fixtures", "inventory-explicit-localhost.ini")

# Real's copy and template ACTION plugins read `follow` themselves with
# boolean(value, strict=False) and pass the COERCED boolean to the copy
# module, so a `follow:` spelling real would reject never fails the task -
# and what does fail it is the typo'd option that sits next to it. Under
# --check the copy spec never runs at all. All live-verified vs 2.19.11
# (this engine used to fail both with a bool-conversion error).
# The playbook lives in the per-test scratch dir (playbook_dir), and the
# dests below are relative to it.
private def delete_dest(name : String) : Nil
  path = File.join(PluginSpecHelper.tmp_path(""), name)
  File.delete(path) if File.exists?(path)
end

describe "template/copy: follow is read by the action plugin" do
  it "deploys with an unrecognised follow and reports a typo'd key instead" do
    src = PluginSpecHelper.tmp_path("follow-src.j2")
    File.write(src, "hello\n")

    playbook = PluginSpecHelper.tmp_path("follow-probe.yml")
    File.write(playbook, <<-YAML)
      - name: repro
        hosts: localhost
        gather_facts: false
        tasks:
          - name: bad follow plus a typo'd key
            ansible.builtin.template:
              src: #{src}
              dest: "{{ playbook_dir }}/follow-typo"
              follow: hcsjhk
              gropu: root
            ignore_errors: true
    YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)

    status.success?.must_equal(true, output.to_s)
    out = output.to_s
    out.must_include("Unsupported parameters for (ansible.legacy.copy) module: gropu.")
    out.wont_include("argument 'follow' is of type str")
  ensure
    File.delete(playbook) if playbook && File.exists?(playbook)
    delete_dest("follow-typo")
  end

  it "deploys the template when follow is the only wrong-typed option" do
    src = PluginSpecHelper.tmp_path("follow-src2.j2")
    dest = PluginSpecHelper.tmp_path("follow-ok.txt")
    File.write(src, "hello\n")
    File.delete(dest) if File.exists?(dest)

    playbook = PluginSpecHelper.tmp_path("follow-probe2.yml")
    File.write(playbook, <<-YAML)
      - name: repro
        hosts: localhost
        gather_facts: false
        tasks:
          - name: bad follow alone
            ansible.builtin.template:
              src: #{src}
              dest: #{dest}
              follow: hcsjhk
    YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)

    status.success?.must_equal(true)
    output.to_s.must_include("changed: [localhost]")
    output.to_s.wont_include("ERROR")
    File.read(dest).must_equal("hello\n")
  ensure
    File.delete(playbook) if playbook && File.exists?(playbook)
    File.delete(dest) if dest && File.exists?(dest)
  end

  it "runs no copy spec check at all under --check" do
    src = PluginSpecHelper.tmp_path("follow-src3.j2")
    File.write(src, "hello\n")

    playbook = PluginSpecHelper.tmp_path("follow-probe3.yml")
    File.write(playbook, <<-YAML)
      - name: repro
        hosts: localhost
        gather_facts: false
        tasks:
          - name: wrong-typed backup under check mode
            ansible.builtin.template:
              src: #{src}
              dest: "{{ playbook_dir }}/follow-check"
              backup: notabool
    YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, playbook, "--check"], output: output, error: output)

    status.success?.must_equal(true, output.to_s)
    out = output.to_s
    out.must_include("changed: [localhost]")
    out.wont_include("argument 'backup' is of type str")
  ensure
    File.delete(playbook) if playbook && File.exists?(playbook)
    delete_dest("follow-check")
  end
end
