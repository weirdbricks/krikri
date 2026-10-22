require "../minitest_helper"

# Issue #239 - a loop source that IS defined but has the wrong shape
# (`loop: "{{ sensu_backend.namespaces }}"` over a `sensu_backend: {}`
# dict) fails with "object of type 'dict' has no attribute 'namespaces'",
# and the "<<< caused by >>>" stanza must pin its Origin at the loop
# VALUE token exactly like the 'is undefined' case does (live-verified
# vs ansible-core 2.19.11). The loop key is written AFTER a
# block-sequence module param here (argv:'s items) - the locator used to
# stop at those nested `- ` lines as if they were the next task and
# never find the key at all, for the undefined case too.

private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "test", "fixtures", "inventory-explicit-localhost.ini")

describe "loop type-error cause stanza origin" do
  it "pins the cause Origin at the loop value token after a block-sequence param" do
    pb = PluginSpecHelper.tmp_path("loop-attr-origin", "pb.yml")
    FileUtils.mkdir_p(File.dirname(pb))
    File.write(pb, <<-YAML)
      ---
      - hosts: localhost
        connection: local
        gather_facts: false
        vars:
          sensu_backend: {}
        tasks:
          - name: Create ns
            command:
              argv:
                - "true"
                - "{{ item }}"
            loop: "{{ sensu_backend.namespaces }}"
            ignore_errors: "true"
      YAML

    stdout = IO::Memory.new
    Process.run(BINARY, ["-i", INVENTORY, pb], output: stdout, error: Process::Redirect::Inherit)
    text = stdout.to_s

    text.must_include("[ERROR]: Task failed: object of type 'dict' has no attribute 'namespaces'")
    text.must_include("<<< caused by >>>")
    # The cause stanza's Origin sits at the loop VALUE token: line 13,
    # the opening quote's column (6-space indent + `loop: `).
    text.must_include("object of type 'dict' has no attribute 'namespaces'\nOrigin: #{pb}:13:13")
    # Same excerpt layout as the 'is undefined' case: 2 preceding source
    # lines, numbered, plus the caret under column 13.
    text.must_include("11           - \"true\"\n12           - \"{{ item }}\"\n13       loop: \"{{ sensu_backend.namespaces }}\"\n               ^ column 13")
  end

  it "pins the cause Origin for an undefined loop source after a block-sequence param too" do
    pb = PluginSpecHelper.tmp_path("loop-undef-origin", "pb.yml")
    FileUtils.mkdir_p(File.dirname(pb))
    File.write(pb, <<-YAML)
      ---
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: T
            command:
              argv:
                - "true"
                - "{{ item }}"
            loop: "{{ nope }}"
            ignore_errors: "true"
      YAML

    stdout = IO::Memory.new
    Process.run(BINARY, ["-i", INVENTORY, pb], output: stdout, error: Process::Redirect::Inherit)
    text = stdout.to_s

    text.must_include("[ERROR]: Task failed: 'nope' is undefined")
    text.must_include("'nope' is undefined\nOrigin: #{pb}:11:13")
    text.must_include(" 9           - \"true\"\n10           - \"{{ item }}\"\n11       loop: \"{{ nope }}\"\n               ^ column 13")
  end
end
