require "../minitest_helper"

private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")

# Round 29878277, issue 245 (klingac.ansible_role_envfiles, rocky): a
# list default whose element is one bare `{{ dict_var }}` span contains
# a real dict in Ansible once the variable is templated, and that dict's
# own values (still-templated strings referencing further role defaults)
# are recursively rendered with it. krikri used to stringify the element
# into its JSON text (the `debug var:` dump) and to hand loop items back
# with literal `{{ }}` text in every nested leaf.
describe "issue 245 templated list element rendering (templated_list_element_test.cr)" do
  # The play mirrors the bug's own shape: the list element is one bare
  # `{{ l_default }}` span and l_default's values are themselves
  # templates. Two tasks produce the two observed divergences (the
  # `debug var:` list holding a stringified dict, and the loop item
  # bound with literal `{{ }}` text); the literal-container msg task
  # covers the same leaf rule on the msg wire path.
  private def write_and_run : String
    root = PluginSpecHelper.tmp_path("templated_list_element")
    Dir.mkdir_p(root)
    playbook = File.join(root, "site.yml")
    File.write(playbook, <<-YAML)
      ---
      - hosts: localhost
        connection: local
        gather_facts: false
        vars:
          d_path: /tmp/issue-245/envfile-out.txt
          d_mode: 600
          l_default:
            path: "{{ d_path }}"
            mode: "{{ d_mode }}"
            cfg: {}
          l_list:
            - "{{ l_default }}"
        tasks:
          - debug:
              var: l_list
          - debug:
              msg: "{{ item }}"
            loop: "{{ l_list }}"
          - debug:
              msg: ["{{ l_default }}"]
      YAML

    out_io = IO::Memory.new
    err_io = IO::Memory.new
    status = Process.run(BINARY, ["-i", "localhost,", playbook], output: out_io, error: err_io)
    status.success?.must_equal true, "playbook failed: #{err_io}"
    out_io.to_s
  end

  it "keeps a bare-template list element a real (rendered) dict in debug var:" do
    out = write_and_run
    out.includes?("\"path\": \"/tmp/issue-245/envfile-out.txt\"").must_equal true,
      "the element's nested template never rendered: #{out}"
    # The stringified-JSON signature: a real dict element drops the
    # escaped `\"path\":` quote form a stringified element carries.
    out.includes?("l_list").must_equal true
    out.includes?("\\\"path\\\"").must_equal false,
      "the list element collapsed back into a JSON string: #{out}"
  end

  it "binds fully rendered loop items, not the raw nested templates" do
    # ansible prints item={'path': ..., 'mode': 600, 'cfg': {}} with every
    # nested leaf RENDERED (verified live vs 2.19.11); the old item was the
    # raw dict with literal `{{ d_path }}` text. The msg itself - the
    # now-real dict - must show the rendered values too.
    out = write_and_run
    out.includes?("(item={'path': '/tmp/issue-245/envfile-out.txt', 'mode': 600, 'cfg': {}})").must_equal true,
      "the loop item header held unrendered nested templates: #{out}"
    out.includes?("'path': '{{ d_path }}'").must_equal false,
      "the loop item is still bound with raw template text: #{out}"
    out.includes?("    \"msg\": {\n        \"cfg\": {},\n        \"mode\": 600,\n        \"path\": \"/tmp/issue-245/envfile-out.txt\"\n    }").must_equal true,
      "the msg did not show the structured dict: #{out}"
  end

  it "keeps a literal msg list's whole-span element a structured dict" do
    # `msg: ["{{ l_default }}"]` - each element is its own template and a
    # single-span element keeps the native dict (the same rule the var:
    # path passes); the old per-leaf substitute stringified it.
    out = write_and_run
    out.includes?("            \"mode\": 600,\n            \"path\": \"/tmp/issue-245/envfile-out.txt\"\n        }").must_equal true,
      "the literal msg element stringified: #{out}"
    out.includes?("msg").must_equal true
  end
end
