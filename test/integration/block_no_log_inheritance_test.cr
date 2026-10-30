require "../minitest_helper"

private BNL_ROOT = File.expand_path("../..", __DIR__)
private BNL_BIN  = File.join(BNL_ROOT, "bin", "krikri-playbook")
private BNL_INV  = File.join(BNL_ROOT, "test", "fixtures", "inventory-explicit-localhost.ini")

# Real resolves no_log: through the parent chain: a looped member of a
# block-level no_log: block prints `(item=(censored due to no_log))`
# (claranet.mariadb's encryption-at-rest block).
describe "block-level no_log inheritance" do
  it "censors loop items of a skipped looped task inside a no_log block" do
    playbook = File.tempname("block-no-log", ".yml")
    File.write(playbook, <<-YAML)
      - name: repro
        hosts: localhost
        gather_facts: false
        tasks:
          - name: hidden block
            block:
              - name: looped member
                set_fact:
                  x: "{{ item }}"
                loop: [1, 2]
            when: false
            no_log: "{{ not (dbg | default(false)) }}"
      YAML

    stdout = IO::Memory.new
    Process.run(BNL_BIN, ["-i", BNL_INV, playbook], output: stdout, error: IO::Memory.new)
    out = stdout.to_s

    out.must_include("skipping: [localhost] => (item=(censored due to no_log))")
    out.wont_include("(item=1)")
  ensure
    File.delete(playbook) if playbook && File.exists?(playbook)
  end
end
