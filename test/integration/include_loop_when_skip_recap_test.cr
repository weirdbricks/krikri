require "file_utils"
require "../minitest_helper"

# A looped include_tasks: whose per-item `when:` is false must recap the
# whole looped task ONCE, like Ansible recaps any looped task - not
# once per skipped item. The per-item "skipping: => (item=...)" lines are
# display only; the recap books skipped=1 when EVERY iteration was
# when:-skipped (plus the bare trailing "skipping:" line Ansible prints for
# that shape, byte-verified against ansible-core 2.19.11), and skipped=0
# once any iteration actually ran. krikri booked one skipped per item,
# because run_include_tasks_once's own when:-false branch incremented the
# counter directly even when the looped caller had deferred the stats to
# it: konstruktoid.hardening's looped "Ensure restrict compilers access
# via DNF post-transaction-actions Plugin" (when:-gated on RedHat, so
# every item skips on a Debian host) recapped skipped=110 where real
# ansible-playbook said 101 (rounds 999040/999050) - the extra 9 being
# exactly this task's loop iterations.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(__DIR__, "..", "fixtures", "inventory-explicit-localhost.ini")

private def run_playbook(files : Hash(String, String))
  dir = File.tempname("include-loop-when-skip")
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

describe "a looped include_tasks: whose when: is false recaps once, not per item" do
  it "recaps skipped=1 (not one per skipped item) when every item's when: is false" do
    status, output = run_playbook({
      "subtasks/dummy.yml" => <<-YAML,
        - name: dummy included task
          ansible.builtin.debug:
            msg: included
        YAML
      "site.yml"           => <<-YAML,
        - name: target
          hosts: localhost
          connection: local
          gather_facts: false
          vars:
            flag: false
            items: [a, b, c]
          tasks:
            - name: looped include all skipped
              ansible.builtin.include_tasks: subtasks/dummy.yml
              loop: "{{ items }}"
              when: flag
        YAML
    })

    status.success?.must_equal true
    # One recap entry for the whole looped task, like Ansible.
    output.must_include("skipped=1")
    output.wont_include("skipped=2")
    output.wont_include("skipped=3")
    # The per-item skipping lines are still displayed, one per item, plus
    # the bare trailing line Ansible prints for the all-skipped shape.
    output.must_include("skipping: [localhost] => (item=a) ")
    output.must_include("skipping: [localhost] => (item=b) ")
    output.must_include("skipping: [localhost] => (item=c) ")
    output.must_include("\nskipping: [localhost]\n")
    # Nothing from the included file ever ran.
    output.wont_include("included:")
    output.wont_include("dummy included task")
  end

  it "recaps skipped=0 once any iteration actually ran (mixed when: verdicts)" do
    status, output = run_playbook({
      "subtasks/dummy.yml" => <<-YAML,
        - name: dummy included task
          ansible.builtin.debug:
            msg: included
        YAML
      "site.yml"           => <<-YAML,
        - name: target
          hosts: localhost
          connection: local
          gather_facts: false
          vars:
            items: [a, b, c]
          tasks:
            - name: looped include mixed
              ansible.builtin.include_tasks: subtasks/dummy.yml
              loop: "{{ items }}"
              when: item != 'b'
        YAML
    })

    status.success?.must_equal true
    # The two executed iterations recap as ok (include + included task
    # each), and the skipped item must add NO skipped= entry.
    output.must_include("ok=4")
    output.must_include("skipped=0")
    output.must_include("skipping: [localhost] => (item=b) ")
  end

  it "still recaps skipped=1 for a plain (non-looped) when:-skipped include_tasks:" do
    status, output = run_playbook({
      "subtasks/dummy.yml" => <<-YAML,
        - name: dummy included task
          ansible.builtin.debug:
            msg: included
        YAML
      "site.yml"           => <<-YAML,
        - name: target
          hosts: localhost
          connection: local
          gather_facts: false
          vars:
            flag: false
          tasks:
            - name: plain include skipped
              ansible.builtin.include_tasks: subtasks/dummy.yml
              when: flag
        YAML
    })

    status.success?.must_equal true
    output.must_include("skipped=1")
    output.must_include("skipping: [localhost]")
  end
end
