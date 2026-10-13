require "../minitest_helper"
require "file_utils"

# The play/task `environment:` KEYWORD is also resolvable as an ordinary
# variable inside task templating (ansible-core 2.19.11, live-verified:
# `debug: msg: "Command = {{ environment }} x"` on a task with no
# `environment:` renders "Command = [] x" - the keyword's empty default -
# instead of raising "'environment' is undefined"). The strict module-arg
# finalization that surfaces the bug lives in the executor's
# build_vars_context, so only a full binary run proves the fix end to end.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "test", "fixtures", "inventory-explicit-localhost.ini")

private def run_playbook(yaml : String)
  playbook = File.tempname("environment-keyword-var", ".yml")
  File.write(playbook, yaml)
  output = IO::Memory.new
  status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)
  {status, output.to_s}
ensure
  File.delete(playbook) if playbook && File.exists?(playbook)
end

describe "environment keyword as a task variable" do
  it "renders the empty default instead of raising 'environment' is undefined" do
    status, output = run_playbook(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: render the keyword default
            ansible.builtin.debug:
              msg: "Command = {{ environment }} x"
      YAML

    status.success?.must_equal(true)
    output.must_include("\"msg\": \"Command = [] x\"")
  end

  it "does not override a user-defined environment variable" do
    status, output = run_playbook(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        vars:
          environment: "user-env-wins"
        tasks:
          - name: render the user value
            ansible.builtin.debug:
              msg: "Command = {{ environment }} x"
      YAML

    status.success?.must_equal(true)
    output.must_include("\"msg\": \"Command = user-env-wins x\"")
  end
end
