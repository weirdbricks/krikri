require "digest/sha1"
require "../minitest_helper"

# `copy:`/`template:` with an explicitly NULL `content:` - a YAML null
# arriving either as a bare `content:` or as a whole-span
# `content: "{{ nullvar }}"` whose variable holds a null (the ossec
# role's bare `ossec_agent_client_pass:` default is the shape that found
# this). Every expectation below was probed against ansible-playbook
# 2.19.11 under -c local.
#
# Ansible's action plugins read content with `.get('content', None)` and
# gate on `is None`, so a null content is NOT "given" - unlike an empty
# string, which is a legitimate whole-file value (spec'd separately in
# copy_empty_content_test.cr). The engine's param wire is strings-only:
# the executor marks the null-ness with NONE_SENTINEL, and the
# required/conflict checks (and the src inliner) must consult it - the
# sentinel demotes to "" on the plugin side, where the plugin's own
# #explicit_null_param? restores the distinction.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "test", "fixtures", "inventory-explicit-localhost.ini")

private def run_playbook(tasks : String) : {String, String}
  scratch = PluginSpecHelper.tmp_path("copy-null-content")
  FileUtils.mkdir_p(scratch)
  # A fixed plain-text source (no Jinja tags - a real .j2 body would get
  # rendered, so the src-path expectations below compare against this
  # exact content)
  src_file = File.join(scratch, "source.txt")
  File.write(src_file, "hello from the src path\n")
  playbook = File.join(scratch, "play.yml")
  File.write(playbook, "- hosts: localhost\n  connection: local\n  gather_facts: false\n  vars:\n    nullvar:\n    emptystring: \"\"\n  tasks:\n" + tasks)
  output = IO::Memory.new
  Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output, chdir: scratch)
  {output.to_s, scratch}
end

describe "copy: null content is not provided" do
  it "fails src (or content) is required for a whole-span null template with no src" do
    output, scratch = run_playbook(<<-YAML)
          - copy:
              dest: out-null-content
              content: "{{ nullvar }}"
            ignore_errors: true
    YAML

    output.must_include(%(fatal: [localhost]: FAILED! => {"changed": false, "msg": "src (or content) is required"}))
    File.exists?(File.join(scratch, "out-null-content")).must_equal(false)
  end

  it "fails the same way for a bare YAML null content:" do
    output, scratch = run_playbook(<<-YAML)
          - copy:
              dest: out-bare-null
              content:
            ignore_errors: true
    YAML

    output.must_include(%("msg": "src (or content) is required"))
    File.exists?(File.join(scratch, "out-bare-null")).must_equal(false)
  end

  it "still writes a real empty file for an empty-string content template" do
    # The contrast that must keep working: an empty string is a
    # legitimate file body (geerlingguy.sanoid's own
    # `content: "{{ sanoid_conf }}"` with `sanoid_conf: ""`), only the
    # null is "not provided".
    output, scratch = run_playbook(<<-YAML)
          - copy:
              dest: out-empty-content
              content: "{{ emptystring }}"
            ignore_errors: true
    YAML

    output.wont_include("src (or content) is required")
    File.read(File.join(scratch, "out-empty-content")).must_equal("")
  end

  it "runs the src path when a real src accompanies a null content" do
    # `source and content is not None` gates the mutual-exclusion error,
    # so a null content leaves src alone instead of conflicting with it -
    # and the src path, not an inlined-content copy, must run.
    output, scratch = run_playbook(<<-YAML)
          - copy:
              dest: out-src-with-null-content
              src: #{PluginSpecHelper.tmp_path("copy-null-content", "source.txt")}
              content: "{{ nullvar }}"
            ignore_errors: true
    YAML

    output.wont_include("mutually exclusive")
    output.wont_include("src (or content) is required")
    File.read(File.join(scratch, "out-src-with-null-content")).must_equal("hello from the src path\n")
  end

  it "fails template's src and dest are required for a null content with no src" do
    # template.py never reads content at all (`source is None or dest is
    # None` is its whole required check), so a null content must not
    # satisfy it either.
    output, scratch = run_playbook(<<-YAML)
          - template:
              dest: out-template-null-content
              content: "{{ nullvar }}"
            ignore_errors: true
    YAML

    output.must_include(%("msg": "src and dest are required"))
    File.exists?(File.join(scratch, "out-template-null-content")).must_equal(false)
  end

  it "still renders through the src path when a template carries a null content" do
    output, scratch = run_playbook(<<-YAML)
          - template:
              dest: out-template-src-with-null-content
              src: #{PluginSpecHelper.tmp_path("copy-null-content", "source.txt")}
              content: "{{ nullvar }}"
            ignore_errors: true
    YAML

    output.wont_include("src and dest are required")
    File.read(File.join(scratch, "out-template-src-with-null-content")).must_equal("hello from the src path\n")
  end
end
