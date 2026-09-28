require "file_utils"
require "../minitest_helper"

# An include_tasks: whose included file fails to LOAD (not a task inside it
# failing) must recap the include task itself as failed= only. Real Ansible
# credits no `ok` for it - the include never completed - verified live
# against ansible-core 2.19.11 with a minimal include_tasks: ->
# import_role: missing-role repro: both the looped and non-looped shapes
# recap ok=0 failed=1 (round 979000 buluma.tomcat: its instance.yml pulls
# in the buluma.service dependency via import_role:, and with that role not
# installed krikri recapped ok=46 failed=1 where real Ansible recaps
# ok=45 failed=1 - the include was credited ok at include-entry time and
# then fail_include booked failed on top).
#
# The non-looped shape goes through execute_include_tasks_multi (the
# batched path handles even a single host), the looped shape through
# execute_include_tasks's per-iteration run_include_tasks_once - so both
# fixed credit sites are covered.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(__DIR__, "..", "fixtures", "inventory-explicit-localhost.ini")

private def run_playbook(files : Hash(String, String))
  dir = File.tempname("include-load-failure-recap")
  Dir.mkdir(dir)
  playbook = File.join(dir, "site.yml")
  files.each do |rel, content|
    path = File.join(dir, rel)
    File.dirname(path).tap { |parent| Dir.mkdir_p(parent) }
    File.write(path, content)
  end
  output = IO::Memory.new
  status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)
  {status, output.to_s}
ensure
  FileUtils.rm_rf(dir) if dir && File.exists?(dir)
end

private def broken_instance_file
  <<-YAML
    - name: pulls in a dependency role nothing installed
      ansible.builtin.import_role:
        name: buluma.service_not_installed_anywhere
      vars:
        service_list: []
    YAML
end

describe "include_tasks: whose included file fails to load" do
  it "recaps the include task as failed only, never ok+failed (non-looped, batched path)" do
    status, output = run_playbook({
      "instance.yml" => broken_instance_file,
      "site.yml"     => <<-YAML,
        - name: target
          hosts: localhost
          connection: local
          gather_facts: false
          tasks:
            - name: include broken
              ansible.builtin.include_tasks: instance.yml
            - name: after
              ansible.builtin.debug:
                msg: never reached
        YAML
    })

    status.exit_code.must_equal(2)
    output.must_include("Failed to load included tasks")
    output.wont_include("never reached")
    output.must_include("ok=0  changed=0  unreachable=0  failed=1")
  end

  it "recaps the include task as failed only, never ok+failed (looped, per-iteration path)" do
    status, output = run_playbook({
      "instance.yml" => broken_instance_file,
      "site.yml"     => <<-YAML,
        - name: target
          hosts: localhost
          connection: local
          gather_facts: false
          tasks:
            - name: Loop over instances
              ansible.builtin.include_tasks: instance.yml
              loop:
                - tomcat
              loop_control:
                loop_var: instance
        YAML
    })

    status.exit_code.must_equal(2)
    output.must_include("Failed to load included tasks")
    output.must_include("ok=0  changed=0  unreachable=0  failed=1")
  end

  it "still credits ok for an include whose file loads cleanly (the non-failure shape is unchanged)" do
    status, output = run_playbook({
      "instance.yml" => <<-YAML,
        - name: dummy included task
          ansible.builtin.debug:
            msg: included
        YAML
      "site.yml" => <<-YAML,
        - name: target
          hosts: localhost
          connection: local
          gather_facts: false
          tasks:
            - name: include good
              ansible.builtin.include_tasks: instance.yml
        YAML
    })

    status.exit_code.must_equal(0)
    output.must_include("included")
    output.must_include("ok=2  changed=0  unreachable=0  failed=0")
  end
end
