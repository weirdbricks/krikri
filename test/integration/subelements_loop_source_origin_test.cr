require "../minitest_helper"

# Issue #291 - a with_subelements: loop source given as a block sequence
# whose first element is an undefined variable fails with real ansible
# printing a "<<< caused by >>>" Origin pinned at the FIRST list element's
# VALUE token (the opening quote), with the usual 2-preceding-lines
# excerpt + caret. The with_* parser branches record their sources in
# their own task fields, so the loop-source locator used to fall back to
# the generic `loop:` kind, never found the `with_subelements:` key line,
# and the cause stanza printed with no Origin at all (live-verified vs
# ansible-core 2.19.11). The templated-entry array forms of
# with_nested:/with_together: had the same gap and share the fix; the
# with_flattened spellings can't be located this way (both spellings
# collapse into one task field) and filetree sources never raise the
# undefined/type-error messages the locator's callers guard on, so neither
# gets a test here.

private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "test", "fixtures", "inventory-explicit-localhost.ini")

private def run_playbook(pb : String)
  stdout = IO::Memory.new
  Process.run(BINARY, ["-i", INVENTORY, pb], output: stdout, error: Process::Redirect::Inherit)
  stdout.to_s
end

describe "with_subelements loop source cause stanza origin" do
  it "pins a with_subelements block sequence at the failing element" do
    pb = PluginSpecHelper.tmp_path("subelements-undef-origin", "pb.yml")
    FileUtils.mkdir_p(File.dirname(pb))
    File.write(pb, <<-YAML)
      ---
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: Create DNS records
            ansible.builtin.debug:
              msg: "{{ item.1.name }}"
            with_subelements:
              - "{{ cloudflare_dns_records }}"
              - records
      YAML

    text = run_playbook(pb)

    text.must_include("[ERROR]: Task failed: 'cloudflare_dns_records' is undefined")
    text.must_include("<<< caused by >>>")
    # The cause stanza's Origin sits at the FIRST element's value token:
    # line 10, column 11 (8-space indent + `- ` + the opening quote).
    text.must_include("'cloudflare_dns_records' is undefined\nOrigin: #{pb}:10:11")
    text.must_include(" 8         msg: \"{{ item.1.name }}\"\n 9       with_subelements:\n10         - \"{{ cloudflare_dns_records }}\"\n             ^ column 11")
  end

  it "pins a templated-entry with_nested array at the failing element" do
    pb = PluginSpecHelper.tmp_path("nested-undef-origin", "pb.yml")
    FileUtils.mkdir_p(File.dirname(pb))
    File.write(pb, <<-YAML)
      ---
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: Nested combos
            ansible.builtin.debug:
              msg: "{{ item }}"
            with_nested:
              - "{{ nope_nested }}"
              - [1]
      YAML

    text = run_playbook(pb)

    text.must_include("[ERROR]: Task failed: 'nope_nested' is undefined")
    text.must_include("'nope_nested' is undefined\nOrigin: #{pb}:10:11")
  end

  it "pins a templated-entry with_together array at the failing element" do
    pb = PluginSpecHelper.tmp_path("together-undef-origin", "pb.yml")
    FileUtils.mkdir_p(File.dirname(pb))
    File.write(pb, <<-YAML)
      ---
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: Together pairs
            ansible.builtin.debug:
              msg: "{{ item }}"
            with_together:
              - "{{ nope_together }}"
              - [1, 2]
      YAML

    text = run_playbook(pb)

    text.must_include("[ERROR]: Task failed: 'nope_together' is undefined")
    text.must_include("'nope_together' is undefined\nOrigin: #{pb}:10:11")
  end
end
