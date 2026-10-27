require "../minitest_helper"
require "file_utils"

# A looped handler's per-item lines show loop_control.label, not the raw
# item dict - ansible's callback renders the label for handler-loop
# iterations exactly like regular-task loops (verified live against
# ansible-playbook 2.19.11: both the when-false skipping line and the
# executed ok line carry `(item=<label>)`). Krikri's handler path used
# the raw item repr instead (issue #617).
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "test", "fixtures", "inventory-explicit-localhost.ini")

describe "handler loop_control.label rendering (handler_loop_label_test.cr)" do
  it "shows the rendered label on a when-false handler loop's skipping lines" do
    playbook = File.tempname("handler-loop-label-skip", ".yml")
    File.write(playbook, <<-YAML
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - debug:
              msg: "notify"
            changed_when: true
            notify: test handler
          - meta: flush_handlers
        handlers:
          - name: test handler
            debug:
              msg: "handler ran"
            with_items:
              - src: /a
                dest: /etc/a.conf
              - src: /b
                dest: /etc/b.conf
            loop_control:
              label: "{{ item.dest }}"
            when: false
      YAML
    )
    output = IO::Memory.new
    Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)
    text = output.to_s
    text.must_include("skipping: [localhost] => (item=/etc/a.conf)")
    text.includes?("item={'src'").must_equal(false)
  ensure
    File.delete(playbook) if playbook && File.exists?(playbook)
  end

  it "shows the rendered label on an executed handler loop's ok lines" do
    playbook = File.tempname("handler-loop-label-ok", ".yml")
    File.write(playbook, <<-YAML
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - debug:
              msg: "notify"
            changed_when: true
            notify: test handler
          - meta: flush_handlers
        handlers:
          - name: test handler
            debug:
              msg: "handler ran"
            with_items:
              - src: /a
                dest: /etc/a.conf
              - src: /b
                dest: /etc/b.conf
            loop_control:
              label: "{{ item.dest }}"
      YAML
    )
    output = IO::Memory.new
    Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)
    text = output.to_s
    text.must_include("ok: [localhost] => (item=/etc/a.conf)")
    text.must_include("ok: [localhost] => (item=/etc/b.conf)")
  ensure
    File.delete(playbook) if playbook && File.exists?(playbook)
  end
end
