require "../minitest_helper"
require "../../src/krikri/py_dump"

# Expected strings captured from ansible-core 2.19.11 (to_json, to_nice_json,
# to_yaml, to_nice_yaml over the same values).
describe Krikri::PyDump do
  it "dumps json like json.dumps" do
    v = JSON.parse(%({"b": 2, "a": "é"}))
    Krikri::PyDump.json(v).must_equal(%({"b": 2, "a": "\\u00e9"}))
    Krikri::PyDump.json(v, 4, true).must_equal("{\n    \"a\": \"\\u00e9\",\n    \"b\": 2\n}")
    Krikri::PyDump.json(JSON.parse("[]"), 4, true).must_equal("[]")
  end

  it "dumps yaml like PyYAML" do
    Krikri::PyDump.yaml(JSON.parse(%({"b": 2, "a": 1}))).must_equal("{a: 1, b: 2}\n")
    Krikri::PyDump.yaml(JSON.parse(%(["123", "yes", "a b", ""]))).must_equal("['123', 'yes', a b, '']\n")
    Krikri::PyDump.yaml(JSON.parse(%([{"k": "v"}, [4, 5]])), 4, false).must_equal("-   k: v\n-   - 4\n    - 5\n")
  end

  # Ansible's to_yaml writes through libyaml, which emits no "..." after a
  # root plain scalar (live: to_yaml(None) == "null\n", to_yaml("x") == "x\n").
  it "writes no document-end marker after a root plain scalar" do
    Krikri::PyDump.yaml(JSON::Any.new(nil)).must_equal("null\n")
    Krikri::PyDump.yaml(JSON::Any.new("x")).must_equal("x\n")
  end
end
