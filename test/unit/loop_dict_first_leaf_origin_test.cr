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
    Process.run(BINARY, ["-i", File.join(__DIR__, "..", "fixtures", "inventory-localhost-local.ini"), playbook], output: stdout, error: Process::Redirect::Inherit)
    text = stdout.to_s

    text.must_include("[ERROR]: Task failed: 'CD_UNDEFINED_ENV' is undefined")
    text.must_include("<<< caused by >>>")
    # First failing leaf in document order: line 8, the item's value
    # token (6-space indent + "- " puts the quote at column 9), same
    # value-token convention real's 18:9 uses for the repro role.
    text.must_include("'CD_UNDEFINED_ENV' is undefined\nOrigin: #{defaults}:8:9")
  end
end

# Issue #387 (T2L.php): a with_dict source subscripted with a NON-string
# key - the loop item itself, an empty dict (`php_configuration[{}]`) -
# must fail with ansible's truthiness-gated wording: a falsy key falls
# through Jinja's "no element" branch carrying the lazy dict wrapper's
# full dotted class path, NOT the templar's "object of type 'dict' has
# no attribute" rewording with the stringified key (live-verified vs
# 2.19.11).
describe "dict subscript miss with a non-string key" do
  it "words a falsy dict-key miss with the lazy template dict class" do
    src_dir = PluginSpecHelper.tmp_path("lazy-dict-nonstring-key", "role")
    Dir.mkdir_p(File.join(src_dir, "roles", "rdtest", "defaults"))
    Dir.mkdir_p(File.join(src_dir, "roles", "rdtest", "tasks"))
    File.write(File.join(src_dir, "roles", "rdtest", "defaults", "main.yml"), <<-YAML)
      ---
      php_configuration:
        phpini:
          upload_max_filesize: "20M"
      YAML
    File.write(File.join(src_dir, "roles", "rdtest", "tasks", "main.yml"), <<-YAML)
      ---
      - name: Configure PHP, section {{ php_configuration_section }}
        ansible.builtin.debug:
          msg: "x"
        vars:
          php_configuration_section: {}
        with_dict: "{{ php_configuration[php_configuration_section] }}"
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
    status = Process.run(BINARY, ["-i", File.join(__DIR__, "..", "fixtures", "inventory-localhost-local.ini"), playbook], output: stdout, error: Process::Redirect::Inherit)
    text = stdout.to_s

    status.exit_code.must_equal(2)
    text.must_include("[ERROR]: Task failed: ansible._internal._templating._lazy_containers._AnsibleLazyTemplateDict object has no element {}")
    text.wont_include("object of type 'dict' has no attribute '{}'")
  end
end
