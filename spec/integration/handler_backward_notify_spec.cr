require "file_utils"
require "../spec_helper"

# A handler notifying a handler that sits EARLIER in definition order.
# Handlers run in definition order, so by the time such a notification
# lands the target has already been passed - and the notification used
# to be dropped entirely, silently skipping a handler the playbook asked
# for.
#
# Real Ansible makes exactly ONE further pass for these. All three
# behaviors below were measured against ansible-core 2.19.4.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "crystal-ansible")

private def handlers_run(playbook : String) : Array(String)
  dir = File.tempname("handler-backward")
  Dir.mkdir_p(dir)
  File.write(File.join(dir, "inv.ini"), "localhost ansible_connection=local\n")
  File.write(File.join(dir, "pb.yml"), playbook)

  stdout_io = IO::Memory.new
  Process.run(BINARY, ["-i", "inv.ini", "pb.yml"], output: stdout_io, error: stdout_io, chdir: dir)
  stdout_io.to_s.scan(/^\s{2}([A-Z][A-Z0-9]*)$/m).map { |mat| mat[1] }
ensure
  FileUtils.rm_rf(dir) if dir && Dir.exists?(dir)
end

describe "handler notifying an earlier handler" do
  it "runs the earlier handler in a second pass" do
    handlers_run(<<-YAML).should eq(["H2", "H1"])
      - hosts: all
        gather_facts: false
        tasks:
          - name: kick
            ansible.builtin.debug: {msg: "t"}
            changed_when: true
            notify: second
        handlers:
          - name: first
            ansible.builtin.debug: {msg: "H1"}
          - name: second
            ansible.builtin.debug: {msg: "H2"}
            changed_when: true
            notify: first
      YAML
  end

  # Forward notification is picked up by the FIRST pass, so the target
  # must not also run again in the second - H1 H2, not H1 H2 H2.
  it "does not double-run a handler notified from ahead of it" do
    handlers_run(<<-YAML).should eq(["H1", "H2"])
      - hosts: all
        gather_facts: false
        tasks:
          - name: kick
            ansible.builtin.debug: {msg: "t"}
            changed_when: true
            notify: first
        handlers:
          - name: first
            ansible.builtin.debug: {msg: "H1"}
            changed_when: true
            notify: second
          - name: second
            ansible.builtin.debug: {msg: "H2"}
      YAML
  end

  # A self-notifying handler runs exactly TWICE - the second pass runs
  # it again, and notifications raised during that pass are dropped.
  # This is also why the notification cannot be detected by diffing the
  # notified set: it is a Set, so re-notifying an already-notified name
  # changes nothing in it.
  it "runs a self-notifying handler exactly twice" do
    handlers_run(<<-YAML).should eq(["LOOPY", "LOOPY"])
      - hosts: all
        gather_facts: false
        tasks:
          - name: kick
            ansible.builtin.debug: {msg: "t"}
            changed_when: true
            notify: loopy
        handlers:
          - name: loopy
            ansible.builtin.debug: {msg: "LOOPY"}
            changed_when: true
            notify: loopy
      YAML
  end

  # A backward CHAIN stops after the one extra pass: C notifies B which
  # notifies A, and A never runs.
  it "stops after one extra pass for a backward chain" do
    handlers_run(<<-YAML).should eq(["C", "B"])
      - hosts: all
        gather_facts: false
        tasks:
          - name: kick
            ansible.builtin.debug: {msg: "t"}
            changed_when: true
            notify: hC
        handlers:
          - name: hA
            ansible.builtin.debug: {msg: "A"}
          - name: hB
            ansible.builtin.debug: {msg: "B"}
            changed_when: true
            notify: hA
          - name: hC
            ansible.builtin.debug: {msg: "C"}
            changed_when: true
            notify: hB
      YAML
  end

  # Guard: an UNCHANGED handler notifying backwards raises nothing.
  it "does not schedule a second pass from an unchanged handler" do
    handlers_run(<<-YAML).should eq(["H2"])
      - hosts: all
        gather_facts: false
        tasks:
          - name: kick
            ansible.builtin.debug: {msg: "t"}
            changed_when: true
            notify: second
        handlers:
          - name: first
            ansible.builtin.debug: {msg: "H1"}
          - name: second
            ansible.builtin.debug: {msg: "H2"}
            changed_when: false
            notify: first
      YAML
  end
end
