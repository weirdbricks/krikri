require "../minitest_helper"

# Issue #359 - a with_dict/loop source reaching a dict-of-lists role
# default whose list leaves EACH fail with the same undefined-name
# message used to lose the caused-by Origin to an unrelated var that
# references the same name: the exactly-one-failing-leaf rule rejected
# the dict-of-lists as ambiguous and the unique-but-unrelated var won.
# Real ansible-playbook templates the loop source itself in document
# order and stops at the FIRST failing leaf, so the "<<< caused by >>>"
# stanza must pin its Origin at that leaf's position in
# defaults/main.yml (live-verified vs ansible-core 2.19.11,
# Rheinwerk.update_sshd_config shape).

private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")

describe "loop source dict-of-lists first failing leaf origin" do
  it "pins the caused-by Origin at the first failing leaf, not an unrelated var" do
    src_dir = PluginSpecHelper.tmp_path("loop-dict-first-leaf", "role")
    Dir.mkdir_p(File.join(src_dir, "roles", "rdtest", "defaults"))
    Dir.mkdir_p(File.join(src_dir, "roles", "rdtest", "tasks"))
    defaults = File.join(src_dir, "roles", "rdtest", "defaults", "main.yml")
    File.write(defaults, <<-YAML)
      ---
      _sshd_krl:
        s3_key: "cd.{{ CD_UNDEFINED_ENV }}"

      _sshd_principals:
        mappings:
          cd-admin:
            - "{{ CD_UNDEFINED_ENV }}"
            - "also {{ CD_UNDEFINED_ENV }}"
      YAML
    File.write(File.join(src_dir, "roles", "rdtest", "tasks", "main.yml"), <<-YAML)
      ---
      - name: Show principals
        ansible.builtin.debug:
          msg: "{{ item }}"
        with_dict: "{{ _sshd_principals.mappings }}"
        ignore_errors: "true"
      YAML
    playbook = File.join(src_dir, "pb.yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        roles:
          - rdtest
      YAML

    stdout = IO::Memory.new
    Process.run(BINARY, ["-i", "localhost,", playbook], output: stdout, error: Process::Redirect::Inherit)
    text = stdout.to_s

    text.must_include("[ERROR]: Task failed: 'CD_UNDEFINED_ENV' is undefined")
    text.must_include("<<< caused by >>>")
    # First failing leaf in document order: line 8, the item's value
    # token (6-space indent + "- " puts the quote at column 9), same
    # value-token convention real's 18:9 uses for the repro role.
    text.must_include("'CD_UNDEFINED_ENV' is undefined\nOrigin: #{defaults}:8:9")
  end
end
