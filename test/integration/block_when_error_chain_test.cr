require "../minitest_helper"
require "file_utils"

# A block's own scalar `when:` is inherited by EVERY task under
# block:/rescue:/always:, so real ansible-core 2.19's two-level [ERROR]
# chain still prints when the block's FIRST child fails that inherited
# conditional - with the "caused by" Origin pinned at the BLOCK's when:
# VALUE token, not at the child's own file where no `when:` exists (issue
# #570). The run-time merge alone (inherit_when_condition) couldn't
# produce it: the parser must hand the executor the block's when: token
# position the same way the static-import path does.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")

describe "when: block-inherited conditional failure chain" do
  it "prints real's chain with the block's when: token Origin" do
    root = PluginSpecHelper.tmp_path("block-when-chain")
    playbook = File.join(root, "pb.yml")
    FileUtils.mkdir_p(root)
    File.write(playbook, <<-YAML)
      ---
      - hosts: localhost
        gather_facts: false
        connection: local
        tasks:
          - name: block conditional
            block:
              - name: first inner task
                debug:
                  msg: hi
              - name: second inner task
                debug:
                  msg: there
            when: ansible_network_os == 'nxos'
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", "localhost,", playbook],
      output: output, error: output, input: IO::Memory.new)

    text = output.to_s
    status.success?.must_equal(false)
    text.must_include("[ERROR]: Task failed: Error while evaluating conditional: 'ansible_network_os' is undefined")
    # first link: the failing child's own mapping - real labels the fatal
    # line with the child's `- name:` token (column 11 = right after
    # `        - `)
    text.must_include("Task failed.\nOrigin: #{playbook}:8:11\n\n6     - name: block conditional\n7       block:\n8         - name: first inner task\n            ^ column 11")
    # second link: the BLOCK's when: VALUE token (column 13 = right after
    # `      when: `), not the child's file where no `when:` sits
    text.must_include("<<< caused by >>>\n\nError while evaluating conditional: 'ansible_network_os' is undefined\nOrigin: #{playbook}:14:13\n\n12           debug:\n13             msg: there\n14       when: ansible_network_os == 'nxos'\n               ^ column 13")
    text.must_include("fatal: [localhost]: FAILED! => {\"msg\": \"Task failed: Error while evaluating conditional: 'ansible_network_os' is undefined\"}")
    text.wont_include("Unhandled exception")
  ensure
    FileUtils.rm_rf(root) if root
  end
end
