require "../minitest_helper"
require "file_utils"

# Check mode is gated at the ACTION layer for uri: its Ansible action
# plugin sets _supports_check_mode = False, so ActionBase.run raises
# AnsibleActionSkip before the action plugin body - i.e. before the
# controller-side src: staging and before the module's own argument-spec
# validation. krikri used to run those first, so an unconvertible bool:
# (or an unresolvable src:) failed the task under --check where Ansible
# skips (live-verified vs ansible-core 2.21.6).
private PROJECT_ROOT_URI_SKIP = File.expand_path("../..", __DIR__)
private BINARY_URI_SKIP       = File.join(PROJECT_ROOT_URI_SKIP, "bin", "krikri-playbook")
private INVENTORY_URI_SKIP    = File.join(__DIR__, "..", "fixtures", "inventory-explicit-localhost.ini")

private def uri_skip_playbook(yaml : String, args : Array(String) = [] of String)
  playbook = File.tempname("uri-check-mode-action-skip", ".yml")
  File.write(playbook, yaml)
  output = IO::Memory.new
  status = Process.run(BINARY_URI_SKIP, ["-i", INVENTORY_URI_SKIP, playbook] + args, output: output, error: output)
  {status, output.to_s}
ensure
  File.delete(playbook) if playbook && File.exists?(playbook)
end

describe "uri check mode action skip" do
  it "skips before validating an unconvertible bool: under --check" do
    status, output = uri_skip_playbook(<<-YAML, ["--check"])
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: bad bool
            ansible.builtin.uri:
              url: http://127.0.0.1:1/text
              remote_src: utmcwq
            register: bad_bool
            ignore_errors: true
          - name: dump
            ansible.builtin.debug:
              msg: "{{ bad_bool | to_json }}"
      YAML

    status.exit_code.must_equal(0)
    output.must_include("skipping: [localhost]")
    output.must_include("This action (ansible.builtin.uri) does not support check mode.")
    output.must_include("skipped=1")
  end

  it "skips before the controller-side src: lookup under --check" do
    status, output = uri_skip_playbook(<<-YAML, ["--check"])
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: unresolvable src
            ansible.builtin.uri:
              url: http://127.0.0.1:1/text
              src: /nonexistent/krikri-uri-check-mode/src.txt
            ignore_errors: true
      YAML

    status.exit_code.must_equal(0)
    output.must_include("skipping: [localhost]")
    output.wont_include("Could not find or access")
  end

  # Issue #1076: a uri task carrying BOTH body: and src: is rejected by the
  # module's own mutually_exclusive check outside check mode, yet the
  # action-layer skip fires ahead of that check, so under --check the task
  # skips. The skipped result keeps failed: false, i.e. `is succeeded` is
  # TRUE, which is why the reported playbook's `when: ... is succeeded`
  # task still ran (live-verified vs ansible-core 2.21.6).
  it "skips before the module's mutually_exclusive check under --check" do
    src = PluginSpecHelper.tmp_path("uri-check-mode-body-src-#{Random::Secure.hex(4)}.txt")
    File.write(src, "body")
    playbook = <<-YAML
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: body and src together
            ansible.builtin.uri:
              url: http://127.0.0.1:1/text
              src: #{src}
              body: pbixke
              remote_src: false
            register: resp
          - name: follow-up
            ansible.builtin.debug:
              msg: FOLLOW-UP RAN
            when: resp is succeeded
      YAML

    status, output = uri_skip_playbook(playbook, ["--check"])
    status.exit_code.must_equal(0)
    output.must_include("skipping: [localhost]")
    output.wont_include("mutually exclusive")
    output.must_include("FOLLOW-UP RAN")

    # ... and without --check the very same pair is rejected, so the skip
    # above is the action layer's, not a missing check.
    status, output = uri_skip_playbook(playbook)
    status.exit_code.must_equal(2)
    output.must_include("parameters are mutually exclusive: body|src")
  end

  it "still fails an unconvertible bool: outside check mode" do
    status, output = uri_skip_playbook(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: bad bool
            ansible.builtin.uri:
              url: http://127.0.0.1:1/text
              remote_src: utmcwq
      YAML

    status.exit_code.must_equal(2)
    output.must_include("argument 'remote_src' is of type str and we were unable to convert to bool")
  end
end
