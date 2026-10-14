require "../minitest_helper"
require "../../src/krikri/playbook_parser"

# ansible's parse_kv decodes backslash escapes in free-form `k=v` tokens, so
# `debug: msg="{{ s.split('\n') }}"` reaches the template with a real newline
# (jsecchiero.cowsay). The YAML dict form is decoded by YAML, and command:/
# shell: free-form text (_raw_params) stays undecoded.
describe "Krikri::PlaybookParser (playbook_parser_kv_escape_decode_test.cr)" do
  it "decodes \\n inside a free-form k=v value" do
    pb = Krikri::PlaybookParser.parse_string(<<-'YAML')
      - hosts: all
        gather_facts: false
        tasks:
          - debug: msg="{{ s.split('\n') }}"
      YAML
    pb.plays[0].tasks[0].params["msg"].must_equal("{{ s.split('\n') }}")
  end

  it "keeps unknown escapes like C:\\Users verbatim" do
    pb = Krikri::PlaybookParser.parse_string(<<-YAML)
      - hosts: all
        gather_facts: false
        tasks:
          - debug: msg=C:\\Users
      YAML
    pb.plays[0].tasks[0].params["msg"].must_equal("C:\\Users")
  end
end
