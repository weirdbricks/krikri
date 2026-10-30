require "../minitest_helper"
require "file_utils"

# Runs the compiled binary against a real playbook.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "test", "fixtures", "inventory-explicit-localhost.ini")

# Ansible's template task diff reports the CONTROLLER-side staged copy of
# the rendered template as its after-header: the template action plugin
# writes the render into ~/.ansible/tmp/ansible-local-<pid><rand>/tmp<rand>/<src
# basename> and the copy action's _get_diff_data uses that path (its src)
# verbatim - never the resolved role template path (live-verified vs
# 2.19.11 on martin-micimo.haproxy, issue #566; the random parts are what
# krikri-role-tester's Compare masks). krikri synthesizes the same-shaped
# path since it hands the rendered content to the module directly.
describe "template diff after-header" do
  it "reports ansible's staged controller temp path, not the source template path" do
    src = PluginSpecHelper.tmp_path("diff-header.j2")
    dest = PluginSpecHelper.tmp_path("diff-header-out.txt")
    File.write(src, "hello\n")
    File.delete(dest) if File.exists?(dest)

    playbook = PluginSpecHelper.tmp_path("diff-header.yml")
    File.write(playbook,
      "- name: repro\n" +
      "  hosts: localhost\n" +
      "  gather_facts: false\n" +
      "  tasks:\n" +
      "    - name: template with diff\n" +
      "      ansible.builtin.template:\n" +
      "        src: #{src}\n" +
      "        dest: #{dest}\n" +
      "      diff: true\n" +
      "      ignore_errors: true\n")

    output = IO::Memory.new
    Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)
    out = output.to_s

    after_line = out.lines.find(&.starts_with?("+++ after: "))
    after_line.wont_be_nil
    header = after_line.not_nil!.lchop("+++ after: ")
    # The staged path shape (two tempfile.mkdtemp calls): the basename is
    # the template's own, the two random components match Python
    # tempfile's character set.
    header.must_match(/^#{Regex.escape(Path.home.to_s)}\/\.ansible\/tmp\/ansible-local-\d+[a-z0-9_]{8}\/tmp[a-z0-9_]{8}\/#{Regex.escape(File.basename(src))}$/)
    out.must_include("changed: [localhost]")
  ensure
    File.delete(playbook) if playbook && File.exists?(playbook)
    File.delete(src) if src && File.exists?(src)
    File.delete(dest) if dest && File.exists?(dest)
  end
end
