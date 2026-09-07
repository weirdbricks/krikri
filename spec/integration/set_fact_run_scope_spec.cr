require "../spec_helper"
require "file_utils"

# Real-Ansible parity: `set_fact:` ranks near the top of the precedence
# ladder and persists for the WHOLE RUN - a play-2 play var must not
# shadow a play-1 set_fact. Verified against real ansible-core 2.19.4
# (two-play repro prints play 1's set_fact value in play 2 even though
# play 2 declares a same-named vars: entry); this engine used to reset
# the set_fact store per play and printed play 2's play var instead.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")

describe "set_fact run scope" do
  it "keeps a play-1 set_fact above a play-2 play var of the same name" do
    Dir.mkdir_p(File.join(PROJECT_ROOT, "spec", "tmp"))
    playbook = File.join(PROJECT_ROOT, "spec", "tmp", "setfact-run-scope.yml")
    File.write(playbook, <<-YAML)
      - hosts: all
        connection: local
        gather_facts: false
        tasks:
          - name: play 1 set_fact
            ansible.builtin.set_fact:
              shared_var: "from-play-1-setfact"

      - hosts: all
        connection: local
        gather_facts: false
        vars:
          shared_var: "play-2-playvar"
        tasks:
          - name: read it in play 2
            ansible.builtin.debug:
              var: shared_var
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", "localhost,", playbook], output: output, error: output)
    captured = output.to_s

    status.success?.should be_true, captured
    captured.should contain("from-play-1-setfact"), captured
    captured.should_not contain("play-2-playvar"), captured
  end
end
