require "../minitest_helper"
require "../../src/krikri/variable_substitutor/filter_engine"
require "../../src/krikri/krikri_jinja_filters"

private def render(source : String, vars : Hash(String, JSON::Any) = {} of String => JSON::Any,
                   host_context : KrikriJinja::HostContext? = nil) : String
  KrikriJinja.render(source, vars, host_context: host_context)
end

describe Krikri::KrikriJinjaFilters do
  include RaisesAssertion
  it "registers pytruthy with Python truthiness" do
    render("{{ value | pytruthy }}", {"value" => JSON::Any.new("")}).must_equal("False")
    render("{{ value | pytruthy }}", {"value" => JSON.parse("[]")}).must_equal("False")
    render("{{ value | pytruthy }}", {"value" => JSON::Any.new(0_i64)}).must_equal("False")
    render("{{ value | pytruthy }}", {"value" => JSON::Any.new("0")}).must_equal("True")
  end

  it "registers bool with Ansible's string coercion" do
    render("{{ 'yes' | bool }}").must_equal("True")
    render("{{ 'false' | bool }}").must_equal("False")
    render("{{ 1 | bool }}").must_equal("False")
  end

  it "registers ternary with the optional none value" do
    render("{{ 'a' | ternary('yes', 'no') }}").must_equal("yes")
    render("{{ '' | ternary('yes', 'no') }}").must_equal("no")
    render("{{ none | ternary('yes', 'no', 'fallback') }}").must_equal("fallback")
    render("{{ none | ternary('yes', 'no') }}").must_equal("no")
  end

  it "registers comment with the plain style default" do
    render("{{ 'managed' | comment }}").must_equal("#\n# managed\n#")
    render("{{ 'managed' | comment('c') }}").must_equal("//\n// managed\n//")
  end

  it "registers to_nice_json with sorted keys by default" do
    render("{{ value | to_nice_json }}", {"value" => JSON.parse(%({"b": 1, "a": 2}))})
      .must_equal("{\n    \"a\": 2,\n    \"b\": 1\n}")
  end

  it "registers the string/collection shaping filters" do
    render("{{ 'hello' | b64encode }}").must_equal("aGVsbG8=")
    render("{{ 'aGVsbG8=' | b64decode }}").must_equal("hello")
    render("{{ 'a/b/c' | basename }}").must_equal("c")
    render("{{ 'a/b/c' | dirname }}").must_equal("a/b")
    render("{{ 'hello' | md5 }}").must_equal("5d41402abc4b2a76b9719d911017c592")
    render("{{ 'hello' | sha1 }}").must_equal("aaf4c61ddcc5e8a2dabede0f3b482cd9aea9434d")
    render("{{ 'hello' | checksum }}").must_equal("aaf4c61ddcc5e8a2dabede0f3b482cd9aea9434d")
    render("{{ '255.255.255.0' | netmask_to_cidr }}").must_equal("24")
    render("{{ 'a.txt' | splitext | join('.') }}").must_equal("a..txt")
    render("{{ ['/a/b', '/a/c'] | commonpath }}").must_equal("/a")
    render("{{ '1.00 KB' | human_to_bytes }}").must_equal("1024")
  end

  it "registers the collection filters and Ansible value helpers" do
    render("{{ {'a': 1, 'b': 2} | omit('a') | tojson }}").must_equal(%({"b": 2}))
    render("{{ [] | mandatory }}").must_equal("[]")
    render("{{ 'x' | type_debug }}").must_equal("str")
    render("{{ [3, 1, 2] | sort | intersect([2, 1]) | join(',') }}").must_equal("1,2")
    render("{{ [1, 2, 3] | difference([2]) | join(',') }}").must_equal("1,3")
    render("{{ [1, 2] | union([2, 3]) | join(',') }}").must_equal("1,2,3")
    render("{{ [1, 2] | product(['a', 'b']) | map('join') | join(' ') }}").must_equal("1a 1b 2a 2b")
    render("{{ ['a/b', 'c'] | path_join }}").must_equal("a/b/c")
    render("{{ 'a,b' | split(',') | join('|') }}").must_equal("a|b")
  end

  it "registers the ipaddr family, jmespath, and conversion filters" do
    render("{{ '192.168.1.0/24' | ipaddr('net') }}").must_equal("192.168.1.0/24")
    render("{{ '192.168.1.10' | ipaddr('address') }}").must_equal("192.168.1.10")
    render("{{ '10.0.0.0/8' | ipmath(1) }}").must_equal("10.0.0.1")
    render("{{ data | json_query('a.b') }}", {"data" => JSON.parse(%({"a": {"b": 7}}))}).must_equal("7")
    render("{{ '{\"a\": 1}' | from_json | tojson }}").must_equal(%({"a": 1}))
    render("{{ 'a: 1' | from_yaml | tojson }}").must_equal(%({"a": 1}))
    render("{{ {'a': 1} | to_yaml }}").must_equal("a: 1")
  end

  it "resolves register-result tests against the host context scope" do
    vars = Hash(String, JSON::Any).new
    vars["copy"] = JSON.parse(%({"failed": true, "changed": false, "msg": "boom"}))
    context = Krikri::JinjaHostContext.new(vars)

    render("{{ copy is failed }}", vars, host_context: context).must_equal("True")
    render("{{ copy is succeeded }}", vars, host_context: context).must_equal("False")
    render("{{ copy is changed }}", vars, host_context: context).must_equal("False")
    render("{{ missing_result is failed }}", vars, host_context: context).must_equal("False")
  end

  it "delegates the remaining Ansible filters to Krikri's own implementations" do
    vars = Hash(String, JSON::Any).new
    vars["nested"] = JSON.parse(%([["a", "b"], ["c"]]))
    context = Krikri::JinjaHostContext.new(vars)

    render("{{ nested | flatten | join(',') }}", vars, host_context: context).must_equal("a,b,c")
    render("{{ 'a-b' | regex_replace('-', '_') }}", vars, host_context: context).must_equal("a_b")
    render("{{ {'a': 1} | dict2items | first | tojson }}", vars, host_context: context)
      .must_equal(%({"key": "a", "value": 1}))
    render("{{ [{'k': 1, 'v': 'x'}] | items2dict('k', 'v') | tojson }}", vars, host_context: context)
      .must_equal(%({"1": "x"}))
  end
end

# Expected values below were live-verified against ansible-core 2.19.
describe "Krikri::KrikriJinjaFilters Ansible tests and remaining filters" do
  include RaisesAssertion
  it "registers the version, regex, and collection tests" do
    render("{{ '8.9p1' is version('8.10', '<') }}").must_equal("True")
    render("{{ 'Port 22' is match('Port') }} {{ 'a Port' is match('Port') }} {{ 'a Port' is search('Port') }}")
      .must_equal("True False True")
    render("{{ [1, 2] is subset([1, 2, 3]) }} {{ [1, 2, 3] is superset([3]) }} {{ [1, 2] is contains(2) }}")
      .must_equal("True True True")
    render("{{ ['a', 'Port 1'] | select('search', '^Port ') | list }}").must_equal("['Port 1']")
  end

  it "treats abs as the path test" do
    render("{{ '/etc/x' is abs }} {{ 'x' is abs }}").must_equal("True False")
  end

  it "resolves collection-qualified filter and test names" do
    render("{{ 'a.b' | ansible.builtin.regex_search('b') }} {{ 'x' is ansible.builtin.search('x') }}")
      .must_equal("b True")
  end

  it "registers to_json, zip, subelements, and root" do
    render("{{ {'a': 1} | to_json }}").must_equal(%({"a": 1}))
    render("{{ ['a', 'b'] | zip([1, 2]) | list }}").must_equal("[['a', 1], ['b', 2]]")
    render("{{ users | subelements('keys') | length }}",
      {"users" => JSON.parse(%([{"name": "root", "keys": ["k1", "k2"]}, {"name": "bob", "keys": ["k3"]}]))})
      .must_equal("3")
    render("{{ '/etc/hosts' | root }}").must_equal("/")
  end

  it "shuffles with Python's seeded permutation" do
    render("{{ [1, 2, 3, 4, 5] | shuffle(seed='host1') | join(',') }}").must_equal("5,3,1,2,4")
    render("{{ [1, 2, 3, 4, 5] | shuffle(seed=42) | join(',') }}").must_equal("4,2,3,5,1")
    render("{{ 'abcdef' | shuffle(seed='x') | join }}").must_equal("ebadcf")
  end

  it "raises on first/last of an empty sequence" do
    assert_raises_message(KrikriJinja::TemplateError, "No first item, sequence was empty.") do
      render("{{ [] | first }}")
    end
  end

  it "maps items2dict's key_name field to the key" do
    render("{{ [{'k': 'a', 'v': 1}] | items2dict(key_name='k', value_name='v') }}").must_equal("{'a': 1}")
    assert_raises_message(KrikriJinja::TemplateError, "items2dict requires each dictionary in the list to contain the keys 'k' and 'v'") do
      render("{{ [{'k': 1}] | items2dict(key_name='k', value_name='v') }}")
    end
  end
end
