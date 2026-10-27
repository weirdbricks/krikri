require "../minitest_helper"

# `tags: "{{ stack_tags | combine({'Description': null_var + int_var + '
# volume'}) }}"` with a null (None) var plus an int var - the `+` falls
# through from the hand-rolled evaluator to krikri-jinja's own evaluator
# (the dict literal rides the engine), which raises its own TemplateError
# ("unsupported operands for +: Nil and Int64"). Real ansible-core 2.19.11
# (verified live, sansible.aws_volume's cloudformation tags) fails the
# task in Python's TypeError shape through the module-arg finalization
# chain:
#
#   "Task failed: Finalization of task args for 'MOD' failed: Error while
#   resolving value for 'KEY': Error rendering template: unsupported
#   operand type(s) for +: 'NoneType' and '_AnsibleTaggedInt'"
#
# - never the engine's raw "line 0: unsupported operands for ..." text.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "test", "fixtures", "inventory-explicit-localhost.ini")

private def run_playbook(yaml : String)
  playbook = File.tempname("operand-type-finalization", ".yml")
  File.write(playbook, yaml)
  output = IO::Memory.new
  status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)
  {status, output.to_s}
ensure
  File.delete(playbook) if playbook && File.exists?(playbook)
end

describe "module-arg operand TypeError from the jinja engine" do
  it "fails the finalization chain in ansible's Python TypeError wording" do
    status, output = run_playbook(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        vars:
          sansible_aws_volume_name: null
          sansible_aws_volume_id: 1
          sansible_aws_volume_stack_tags: {}
        tasks:
          - name: Combine tags like sansible.aws_volume
            ansible.builtin.stat:
              path: "{{ sansible_aws_volume_stack_tags | combine({ 'Description': sansible_aws_volume_name + sansible_aws_volume_id + ' volume' }) }}"
      YAML

    status.success?.must_equal(false)
    output.must_include("Error while resolving value for 'path': Error rendering template: unsupported operand type(s) for +: 'NoneType' and '_AnsibleTaggedInt'")
    output.wont_include("line 0:")
    output.wont_include("unsupported operands for")
  end
end
