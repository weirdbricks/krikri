require "../minitest_helper"

private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "spec", "fixtures", "inventory-explicit-localhost.ini")

private def run_playbook(yaml : String)
  playbook = File.tempname("until-list-retry", ".yml")
  File.write(playbook, yaml)
  output = IO::Memory.new
  status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)
  {status, output.to_s}
ensure
  File.delete(playbook) if playbook && File.exists?(playbook)
end

# Real Ansible accepts a LIST of until: clauses (ANDed together, each
# evaluated against the registered result). The parser used to stringify
# such a list as its literal to_s ("[moodle_download is succeeded]"), which
# the conditional evaluator read as var name "[moodle_download]" - never
# resolvable - so the until: retry loop never saw its exit condition and ran
# every configured attempt. The final attempt's now-idempotent, changed:
# false result then replaced attempt 1's real changed: true, both in the
# registered var and on the displayed line/recap (found via round 979035,
# buluma.moodle's "Download moodle archive" get_url task, where real
# ansible-playbook reported changed and krikri reported ok on a fresh host).
describe "until: list-form retry loop" do
  it "stops after the first successful attempt, keeping its changed status" do
    counter = File.tempname("until-list-attempts")
    File.delete(counter) if File.exists?(counter)

    begin
      status, output = run_playbook(<<-YAML)
        - hosts: localhost
          connection: local
          gather_facts: false
          tasks:
            - name: attempt counter
              ansible.builtin.command:
                argv: ["sh", "-c", "echo attempt >> #{counter}"]
              register: result
              retries: 3
              until:
                - result is succeeded
        YAML

      status.success?.must_equal(true)
      # One attempt = one counter line; the old bug retried all 3 attempts
      # (with the default 5s delay between them) because the exit condition
      # never evaluated true.
      File.read_lines(counter).size.must_equal(1)
      # The reported status must be attempt 1's own, not a later rerun's.
      output.must_include("changed: [localhost]")
      output.wont_include("ok: [localhost]")
    ensure
      File.delete(counter) if counter && File.exists?(counter)
    end
  end
end
