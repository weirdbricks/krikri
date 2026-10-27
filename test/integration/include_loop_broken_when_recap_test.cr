require "file_utils"
require "../minitest_helper"

# A looped include_tasks: whose `when:` raises (ansible-core 2.19's
# broken-conditional error) must recap ONE failure for the whole task, not
# one per raising item. Ansible evaluates the include's condition
# per item and prints a `failed: ... (item=...)` line for each, but the
# executor aggregates the loop into a single failed task result - three
# item-failure lines on screen, failed=1 in the PLAY RECAP (verified live
# against ansible-core 2.19.11). krikri booked each item's
# swallow_when_error separately: recap failed=3 where real recaps
# failed=1 (sbaerlocher.qemu-guest-agent round 970558, via its
# arillso.repositories dependency's looped "include subtasks repository").
#
# With ignore_errors: the same aggregation applies - one ok+ignored pair,
# not one per item (also verified live, same setup).
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(__DIR__, "..", "fixtures", "inventory-explicit-localhost.ini")

private def run_playbook(files : Hash(String, String))
  dir = File.tempname("include-loop-when-error")
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

private def looped_broken_when_playbook(ignore_errors : Bool)
  suffix = ignore_errors ? "\n      ignore_errors: true" : ""
  {
    "subtasks/apt.yml" => <<-YAML,
      - name: dummy included task
        ansible.builtin.debug:
          msg: included
      YAML
    "site.yml" => <<-YAML,
      - name: target
        hosts: localhost
        connection: local
        gather_facts: false
        vars:
          repositories:
            ubuntu:
              - name: a
                repo: r1
              - name: b
                repo: r2
              - name: c
                repo: r3
        tasks:
          - name: include subtasks repository
            ansible.builtin.include_tasks: "subtasks/apt.yml"
            loop_control:
              loop_var: loop_repository
            loop: "{{ repositories['ubuntu'] }}"
            when: "repositories['ubuntu'] | default(false)"#{suffix}
      YAML
  }
end

describe "looped include_tasks with a raising when: recaps one failure" do
  it "recaps failed=1 (not one per raising item) and keeps the per-item lines" do
    status, output = run_playbook(looped_broken_when_playbook(false))

    status.exit_code.must_equal(2)
    output.must_include("Conditionals must have a boolean result")
    # ansible-core 2.19.11's loop-item failure line shape (live-
    # verified for this exact playbook): `failed: [host] (item=...) =>
    # {...}` - "failed:", item before the =>, never "fatal:".
    output.must_include("failed: [localhost] (item=")
    output.must_include("failed=1")
    output.wont_include("failed=2")
    output.wont_include("failed=3")
  end

  it "books one ok+ignored pair under ignore_errors: (not one per item)" do
    status, output = run_playbook(looped_broken_when_playbook(true))

    status.exit_code.must_equal(0)
    output.must_include("...ignoring")
    output.must_include("ignored=1")
    output.wont_include("ignored=2")
    output.wont_include("ignored=3")
    output.wont_include("failed=1")
  end

  # ansible-core 2.19.11 (live-verified, issue #627): before the per-item
  # lines real prints the two-level [ERROR] chain ONCE, its "caused by"
  # Origin on the tested value's DEFINING site - the start of the
  # `ubuntu:` sequence in the play vars (fixture line 8, the `-` at
  # column 9) - not on the when: token the compound branch used to give.
  # Each item's failed dump carries the loop bindings
  # (ansible_loop_var + the item under loop_repository), alphabetical.
  it "prints the [ERROR] chain once at the defining site and loop bindings per item" do
    status, output = run_playbook(looped_broken_when_playbook(false))

    status.exit_code.must_equal(2)
    # One chain block only, regardless of how many items raised.
    output.scan("[ERROR]: Task failed: Conditional result (True) was derived from value of type 'list'").size.must_equal(1)
    # The defining site of the subscripted pass-through value: the
    # sequence start of repositories['ubuntu'] in the play vars.
    output.must_match(/was derived from value of type 'list' at '[^']*site\.yml:8:9'\. Conditionals must have a boolean result\./)
    # The chain's task-level Origin is the include task's `- name:` line;
    # the caused-by Origin is the when: value token.
    output.must_match(/Task failed\.\nOrigin: [^\n]*site\.yml:15:7\n/)
    output.must_match(/<<< caused by >>>\n\nConditional result \(True\) was derived from value of type 'list' at '[^']*site\.yml:8:9'/)
    output.must_match(/Origin: [^\n]*site\.yml:20:13\n/)
    output.scan("ALLOW_BROKEN_CONDITIONALS").size.must_equal(1)
    # Per-item failed dumps carry the loop bindings, keys alphabetical.
    output.scan(/"ansible_loop_var": "loop_repository"/).size.must_equal(3)
    output.must_include("{\"ansible_loop_var\": \"loop_repository\", \"changed\": false, \"loop_repository\": {\"name\": \"a\", \"repo\": \"r1\"}, \"msg\": \"Task failed: ")
    output.must_include("{\"ansible_loop_var\": \"loop_repository\", \"changed\": false, \"loop_repository\": {\"name\": \"b\", \"repo\": \"r2\"}, \"msg\": \"Task failed: ")
    output.must_include("{\"ansible_loop_var\": \"loop_repository\", \"changed\": false, \"loop_repository\": {\"name\": \"c\", \"repo\": \"r3\"}, \"msg\": \"Task failed: ")
  end
end
