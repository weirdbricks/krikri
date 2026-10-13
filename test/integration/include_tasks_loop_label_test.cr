require "file_utils"
require "../minitest_helper"

# A looped include_tasks: with loop_control: label: used to print the whole
# raw item dict on its per-iteration `included:` line - ansible renders the
# label there like it does for every other looped task's result line
# (live-verified against ansible-core 2.19: `included: x.yml for host =>
# (item=config-manager)` for `loop: [{name: config-manager}, ...]` with
# `label: "{{ item.name }}"`).
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")

private def run_play(playbook : String, extra_files : Hash(String, String) = {} of String => String) : {Int32, String}
  dir = File.tempname("inc-loop-label")
  Dir.mkdir_p(dir)
  File.write(File.join(dir, "inv.ini"), "localhost ansible_connection=local\n")
  extra_files.each { |name, content| File.write(File.join(dir, name), content) }
  File.write(File.join(dir, "pb.yml"), playbook)

  stdout_io = IO::Memory.new
  status = Process.run(BINARY, ["-i", "inv.ini", "pb.yml"], output: stdout_io, error: stdout_io, chdir: dir)
  {status.exit_code, stdout_io.to_s}
ensure
  FileUtils.rm_rf(dir) if dir && Dir.exists?(dir)
end

describe "looped include_tasks: loop_control.label" do
  it "shows the rendered label, not the raw dict, on the included: line" do
    code, output = run_play(<<-YAML, {"x.yml" => "- name: inner\n  ansible.builtin.debug: {msg: ran}\n"})
      - hosts: all
        gather_facts: false
        tasks:
          - name: looped include
            ansible.builtin.include_tasks: x.yml
            loop:
              - {name: config-manager}
              - {name: firewalld}
            loop_control:
              label: "{{ item.name }}"
      YAML

    code.must_equal(0)
    output.must_match(/included: .*x\.yml for localhost => \(item=config-manager\)/)
    output.must_match(/included: .*x\.yml for localhost => \(item=firewalld\)/)
    # The raw dict must not leak onto the included: line (the bug's old
    # output showed the whole item there).
    output.scan(/included: .*item=[^\n]*/).each do |match|
      match[0].wont_match(/item=\{/)
    end
  end

  it "shows the rendered label on a looped handler include's included: line too" do
    code, output = run_play(<<-YAML, {"inc2.yml" => "- name: h2\n  ansible.builtin.debug: {msg: two2}\n"})
      - hosts: all
        gather_facts: false
        tasks:
          - name: trigger
            ansible.builtin.command: /bin/true
            changed_when: true
            notify: looped include
        handlers:
          - name: looped include
            ansible.builtin.include_tasks: "inc2.yml"
            loop:
              - {name: alpha}
              - {name: beta}
            loop_control:
              label: "{{ item.name }}"
      YAML

    code.must_equal(0)
    output.must_match(/included: .*inc2\.yml for localhost => \(item=alpha\)/)
    output.must_match(/included: .*inc2\.yml for localhost => \(item=beta\)/)
    output.scan(/included: .*item=[^\n]*/).each do |match|
      match[0].wont_match(/item=\{/)
    end
  end
end
