require "../minitest_helper"
require "file_utils"

# assert: with an undefined variable in that: prints Ansible 2.19.11's two-level
# [ERROR] block whose second Origin points at the failing that: item
# (live-compared byte for byte with ansible-playbook via
# scripts/output_parity.sh on the same playbook).
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "test", "fixtures", "inventory-explicit-localhost.ini")

describe "assert that: conditional error block" do
  it "points the caused-by Origin at the failing list item and inline scalar" do
    playbook = File.tempname("assert-that-block", ".yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        gather_facts: false
        vars:
          ok_var: true
        tasks:
          - name: second item undefined
            ansible.builtin.assert:
              that:
                - ok_var
                - nope_two
            ignore_errors: true
          - name: inline form
            ansible.builtin.assert:
              that: nope_four
            ignore_errors: true
      YAML
    output = IO::Memory.new
    Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)
    text = output.to_s

    text.must_include("[ERROR]: Task failed: Error while evaluating conditional: 'nope_two' is undefined")
    text.must_include("<<< caused by >>>")
    # list item: "- nope_two" on line 10, scalar at column 13 (heredoc keeps
    # 2 spaces of indent the playbook text carries)
    text.must_include("Origin: #{playbook}:10:13")
    # inline form: `that: nope_four` on line 14, scalar at column 15
    text.must_include("Origin: #{playbook}:14:15")
    text.must_include("^ column 13")
    text.must_include("^ column 15")
  ensure
    File.delete(playbook) if playbook && File.exists?(playbook)
  end

  # A looped assert:'s failing that: is the ACTION's failure, not a
  # conditional-evaluation one, so real prints that chain once even when the
  # task carries a `when:` (issue #1645: standardtech_bot.substrate_deployer's
  # imported `when:` made a second, differently-Origin'd chain appear). The
  # loop's per-item chain emitter used to decide on the msg's wording, which
  # the action's failure shares, and printed a bogus block pinned at the
  # when: token as well.
  it "prints one chain for a looped that: syntax error under a when:" do
    playbook = PluginSpecHelper.tmp_path("playbook.yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: looped that syntax error
            ansible.builtin.assert:
              quiet: true
              that: "{{ item }} is defined"
            when: true
            loop:
              - one
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)

    status.exit_code.must_equal(2)
    text = output.to_s
    location = File.expand_path(playbook)
    text.scan("[ERROR]: ").size.must_equal(1)
    text.must_include("Origin: #{location}:5:7")
    text.must_include("Origin: #{location}:8:15")
    text.wont_include("Origin: #{location}:9:13")

    File.delete(playbook) if File.exists?(playbook)
  end
end
