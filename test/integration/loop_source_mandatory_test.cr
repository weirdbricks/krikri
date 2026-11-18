require "../minitest_helper"

# `undefined | mandatory` inside a loop SOURCE is not the plain
# undefined-variable class: ansible hands the undefined value to the
# mandatory FILTER PLUGIN, whose wrapper fails the loop source with the
# filter's own message. Real prints that as a bare [ERROR] line with the
# loop keyword's VALUE token as Origin - no "Task failed:" prefix, no
# "Provide a list of items/templates" tail - and the fatal result keeps
# the same bare msg (live-verified vs 2.21.6 in check mode, issue #1528;
# stuvusIT.reverse_proxy's `with_items: "{{ proxy_domains | mandatory }}"`).
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "test", "fixtures", "inventory-explicit-localhost.ini")

private def run_loop_mandatory_playbook(yaml : String, check : Bool)
  playbook = File.tempname("loop-mandatory", ".yml")
  File.write(playbook, yaml)
  args = ["-i", INVENTORY, playbook]
  args << "--check" if check
  output = IO::Memory.new
  status = Process.run(BINARY, args, output: output, error: output)
  {status, output.to_s}
ensure
  File.delete(playbook) if playbook && File.exists?(playbook)
end

private def assert_loop_mandatory_failure(status, output)
  status.exit_code.must_equal(2)
  output.must_include("[ERROR]: The filter plugin 'ansible.builtin.mandatory' failed: Mandatory variable 'proxy_domains' not defined.")
  output.must_include("fatal: [localhost]: FAILED! => {\"msg\": \"The filter plugin 'ansible.builtin.mandatory' failed: Mandatory variable 'proxy_domains' not defined.\"}")
  output.must_match(/Origin: .*loop-mandatory.*\.yml:8:19/)
  output.must_include(%(with_items: "{{ proxy_domains | mandatory }}"))
  output.wont_include("Task failed:")
  output.wont_include("Provide a list of items/templates")
  output.wont_include("Unhandled exception")
end

describe "mandatory in loop source: filter-plugin failure" do
  it "prints the filter-plugin wording in check mode" do
    status, output = run_loop_mandatory_playbook(<<-YAML, check: true)
      ---
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - ansible.builtin.debug:
              msg: "{{ item }}"
            with_items: "{{ proxy_domains | mandatory }}"
      YAML
    assert_loop_mandatory_failure(status, output)
  end

  it "prints the filter-plugin wording in a real run too" do
    status, output = run_loop_mandatory_playbook(<<-YAML, check: false)
      ---
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - ansible.builtin.debug:
              msg: "{{ item }}"
            with_items: "{{ proxy_domains | mandatory }}"
      YAML
    assert_loop_mandatory_failure(status, output)
  end
end
