require "../minitest_helper"

# A set_fact argument key using one of ansible-core's reserved variable
# names warns at the moment the fact is applied: "[WARNING]: Found
# variable using reserved name 'X'." + the key's own Origin block,
# printed on stderr immediately before that task's ok: line (real warns
# from vars/manager.py set_host_facts; live-verified vs 2.19).
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "test", "fixtures", "inventory-explicit-localhost.ini")

describe "set_fact reserved variable name warning" do
  it "warns for a reserved-name set_fact key before the ok line" do
    playbook = File.tempname("reserved-set-fact", ".yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        gather_facts: false
        tasks:
          - name: Set OS version fact
            set_fact:
              el_version: "9"
              tags:
                - sdc
      YAML
    output = IO::Memory.new
    Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)
    text = output.to_s

    text.must_include("[WARNING]: Found variable using reserved name 'tags'.")
    text.must_include("Origin: #{playbook}:7:9")
    # the warning precedes the task's ok line (same stderr-then-ok order
    # real produces) and prints exactly once
    warn_at = text.index("Found variable using reserved name 'tags'")
    ok_at = text.index("ok: [localhost]")
    (warn_at && ok_at && warn_at < ok_at).must_equal(true)
    text.scan("Found variable using reserved name 'tags'").size.must_equal(1)
  ensure
    File.delete(playbook) if playbook && File.exists?(playbook)
  end

  it "does not warn for non-reserved set_fact keys" do
    playbook = File.tempname("reserved-set-fact-clean", ".yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        gather_facts: false
        tasks:
          - name: Set plain fact
            set_fact:
              el_version: "9"
              my_tags: "x"
      YAML
    output = IO::Memory.new
    Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)
    refute(output.to_s.includes?("Found variable using reserved name"))
  ensure
    File.delete(playbook) if playbook && File.exists?(playbook)
  end
end
