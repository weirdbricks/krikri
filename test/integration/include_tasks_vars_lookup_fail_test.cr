require "../minitest_helper"

# include_tasks' own vars: value whose lookup FAILS (issue #354) must
# survive to the task that consumes it inside the included file:
# ansible-core's lazy var templating leaves even a failing lookup's value
# in place, so the include itself succeeds and the failure only surfaces
# at the USE site as "Error while resolving value for 'pname': The
# lookup plugin 'file' failed: ...". render_task_vars's generic rescue
# used to delete the key on any raise, so the same set_fact saw a plain
# undefined name ("'cur_version' is undefined") and reported a bug that
# was never the one that happened.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(__DIR__, "..", "fixtures", "inventory-explicit-localhost.ini")

describe "include_tasks vars: value whose lookup fails" do
  it "fails the consuming task with the real lookup error, never an undefined-name error" do
    scratch = PluginSpecHelper.tmp_path("include-tasks-lookup-fail")
    FileUtils.mkdir_p(scratch)
    File.write(File.join(scratch, "tasks.yml"), <<-YAML)
      - name: use the version var
        ansible.builtin.set_fact:
          pname: "x_{{ cur_version }}"
      YAML
    playbook = File.join(scratch, "play.yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: include tasks
            ansible.builtin.include_tasks: tasks.yml
            vars:
              cur_version: "{{ lookup('file', '/nonexistent/PKGBUILD') | regex_search('[Vv]ersion=[0-9.]+') | join('') }}"
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output, chdir: scratch)

    status.success?.must_equal(false)
    status.exit_code.must_equal(2)
    output.to_s.must_include("Error while resolving value for 'pname': The lookup plugin 'file' failed")
    output.to_s.wont_include("is undefined")
    output.to_s.must_include("failed=1")
  end
end
