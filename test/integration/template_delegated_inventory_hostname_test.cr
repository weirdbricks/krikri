require "../minitest_helper"
require "file_utils"

# Runs the compiled binary against a real playbook - inventory_hostname
# under delegation is set by TemplateActionPlugin's controller-side vars
# preparation, which needs the real `template:` action end to end.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")

describe "template:'s inventory_hostname under delegate_to" do
  it "keeps the play host's inventory name when the task delegates to localhost" do
    # Real ansible's observed behaviour (issue #727): delegate_to:
    # localhost re-points the task's execution at the controller, but
    # inventory_hostname is NOT rewritten - a template rendered under
    # delegation still sees the play's own host name. krikri was
    # overwriting inventory_hostname with the delegated host's name,
    # so `{{ inventory_hostname }}` rendered "localhost" instead of
    # "testhost".
    dir = File.tempname("template-delegated-invhost")
    Dir.mkdir_p(dir)
    src = File.join(dir, "tpl.j2")
    dest = File.join(dir, "rendered-out.conf")
    inventory = File.join(dir, "inventory")
    playbook = File.join(dir, "site.yml")
    File.write(src, "{{ inventory_hostname }}\n")
    File.write(inventory, "testhost ansible_connection=local\n")
    File.write(playbook, <<-YAML)
      - hosts: testhost
        gather_facts: false
        tasks:
          - ansible.builtin.template:
              src: #{src}
              dest: #{dest}
            delegate_to: localhost
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", inventory, playbook], output: output, error: output)

    status.success?.must_equal(true)
    File.read(dest).must_equal("testhost\n")
  ensure
    FileUtils.rm_rf(dir) if dir
  end
end
