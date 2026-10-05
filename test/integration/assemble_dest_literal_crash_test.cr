require "../minitest_helper"
require "file_utils"

# Runs the compiled binary against a real playbook.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "test", "fixtures", "inventory-explicit-localhost.ini")

# Ansible's assemble action plugin assembles the fragments on the controller
# when remote_src is present and falsy, and it expands the destination's
# user path (`dest = self._remote_expand_user(dest)`) before it ever hands
# the task to the copy module - so a non-string YAML literal dest crashes
# the ACTION there and that crash is what the task reports. The copy
# module's own spec checks (a typo'd option, a wrong-typed option) run
# only after that, so they must not be the message the task fails with
# (live-verified vs 2.19.11, all of the below).
describe "assemble: non-string dest crash ordering" do
  it "crashes on the dest expand before the copy module's spec checks" do
    fragments = PluginSpecHelper.tmp_path("assemble-crash-frags")
    FileUtils.rm_rf(fragments)
    Dir.mkdir_p(fragments)
    File.write(File.join(fragments, "a"), "one\n")

    playbook = PluginSpecHelper.tmp_path("assemble-crash.yml")
    File.write(playbook, <<-YAML)
      - name: repro
        hosts: localhost
        gather_facts: false
        tasks:
          - name: int dest plus a typo'd option
            ansible.builtin.assemble:
              src: #{fragments}
              dest: 77
              remote_src: "false"
              ignore_hidden: gvkaws
              avlidate: /bin/true %s
            ignore_errors: true
          - name: bool dest plus a typo'd option
            ansible.builtin.assemble:
              src: #{fragments}
              dest: false
              remote_src: "false"
              gorup: root
            ignore_errors: true
          - name: int dest, wrong-typed option
            ansible.builtin.assemble:
              src: #{fragments}
              dest: 77
              remote_src: "false"
              follow: notabool
            ignore_errors: true
    YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)

    status.success?.must_equal(true)
    out = output.to_s
    out.must_include("Task failed: '_AnsibleTaggedInt' object has no attribute 'startswith'")
    # A bool literal is not tagged, so it names the plain type.
    out.must_include("Task failed: 'bool' object has no attribute 'startswith'")
    # Neither the typo'd option nor the wrong-typed follow is reported.
    out.wont_include("Unsupported parameters")
    out.wont_include("unable to convert to bool")
  ensure
    File.delete(playbook) if playbook && File.exists?(playbook)
  end
end
