require "../minitest_helper"
require "file_utils"

# Pins the recap accounting the #1691 four-way comparison relies on: a
# `meta: flush_handlers` is displayed but never counted in `ok`, while a
# notified handler IS counted. Verified against ansible-core 2.21.6:
# copy(changed)+flush+command(ok, not changed)+handler(changed) recaps
# `ok=3 changed=2`.
# (The #1691 live `ok=11` vs `ok=12` delta was ansible skipping the
# implicit Gathering Facts through its warm pickle fact cache while
# krikri could not read that backend and gathered - not a meta/handler
# count.)
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "test", "fixtures", "inventory-explicit-localhost.ini")

describe "recap accounting for meta: flush_handlers and handlers" do
  it "does not count the flush as ok, but does count the handler it flushes" do
    src_dir = File.tempname("meta-flush-handler-recap")
    Dir.mkdir_p(src_dir)

    playbook = File.join(src_dir, "pb.yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: changed task notifying a handler
            ansible.builtin.copy:
              content: "a\\n"
              dest: #{File.join(src_dir, "a.txt")}
            notify: probe handler
          - name: flush handlers
            ansible.builtin.meta: flush_handlers
          - name: ok task
            ansible.builtin.command: "true"
            changed_when: false
        handlers:
          - name: probe handler
            ansible.builtin.copy:
              content: "b\\n"
              dest: #{File.join(src_dir, "b.txt")}
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output, chdir: src_dir)

    status.success?.must_equal(true)
    output.to_s.must_include("TASK [flush handlers]")
    output.to_s.must_include("RUNNING HANDLER [probe handler]")
    output.to_s.must_match(/ok=3\s+changed=2\s+unreachable=0\s+failed=0\s+skipped=0/)
  ensure
    FileUtils.rm_rf(src_dir) if src_dir
  end
end
