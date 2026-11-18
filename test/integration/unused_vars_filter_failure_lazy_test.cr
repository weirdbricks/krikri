require "../minitest_helper"
require "file_utils"

# amtega.gitlab_projects_fact (issue #1561, round29917453): its own block
# `vars:` builds `gitlab_projects_fact_last_link` out of a result the role
# never registers, so `| last` runs over an empty sequence. ansible-core
# templates a vars: value only at the render that CONSUMES it, so that
# unused value never raises at all; krikri rendered every task/block vars:
# value eagerly and failed the task with "No last item, sequence was
# empty." instead of letting the role's real (module-side) failure show.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "test", "fixtures", "inventory-explicit-localhost.ini")

describe "a vars: value real ansible never renders cannot fail the task" do
  it "runs a block's and its own task's unused raising vars: values through to success" do
    tempdir = File.tempname("unused-raising-vars").tap { |dir| Dir.mkdir(dir) }
    playbook = File.join(tempdir, "site.yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - block:
              - name: block member with an unregistered-result var in scope
                ansible.builtin.debug:
                  msg: block ran
            vars:
              last_link: >-
                {{ never_registered_result.link.split("<")
                   | list
                   | select("search", "rel=.last.")
                   | list
                   | last }}
          - name: task with its own unused raising var
            ansible.builtin.debug:
              msg: task ran
            vars:
              first_item: "{{ [] | first }}"
      YAML
    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)
    text = output.to_s

    status.success?.must_equal(true, text)
    text.must_include("block ran")
    text.must_include("task ran")
    text.wont_include("No last item, sequence was empty.")
    text.wont_include("No first item, sequence was empty.")
    text.must_include("ok=2")
  ensure
    FileUtils.rm_rf(tempdir) if tempdir
  end

  it "still fails the arg that actually consumes the raising value, with the finalization chain" do
    tempdir = File.tempname("consumed-raising-task-var").tap { |dir| Dir.mkdir(dir) }
    playbook = File.join(tempdir, "site.yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: consume the raising task var
            ansible.builtin.debug:
              msg: "{{ last_link }}"
            vars:
              last_link: "{{ [] | last }}"
      YAML
    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)
    text = output.to_s

    status.exit_code.must_equal(2)
    text.wont_include("Unhandled exception")
    text.must_include("fatal: [localhost]: FAILED! => {\"msg\": \"Task failed: Finalization of task args for 'ansible.builtin.debug' failed: Error while resolving value for 'msg': No last item, sequence was empty.\"}")
  ensure
    FileUtils.rm_rf(tempdir) if tempdir
  end
end
