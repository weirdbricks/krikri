require "../spec_helper"
require "../../src/krikri/variable_substitutor/filter_engine"
require "../../src/krikri/jinja_filters"
require "../../src/krikri/krikri_jinja_filters"

private def render(source : String, vars : Hash(String, JSON::Any) = {} of String => JSON::Any,
                   host_context : KrikriJinja::HostContext? = nil) : String
  KrikriJinja.render(source, vars, host_context: host_context)
end

describe Krikri::KrikriJinjaFilters do
  it "registers pytruthy with Python truthiness" do
    render("{{ value | pytruthy }}", {"value" => JSON::Any.new("")}).should eq("False")
    render("{{ value | pytruthy }}", {"value" => JSON.parse("[]")}).should eq("False")
    render("{{ value | pytruthy }}", {"value" => JSON::Any.new(0_i64)}).should eq("False")
    render("{{ value | pytruthy }}", {"value" => JSON::Any.new("0")}).should eq("True")
  end

  it "registers bool with Ansible's string coercion" do
    render("{{ 'yes' | bool }}").should eq("True")
    render("{{ 'false' | bool }}").should eq("False")
    render("{{ 1 | bool }}").should eq("False")
  end

  it "registers ternary with the optional none value" do
    render("{{ 'a' | ternary('yes', 'no') }}").should eq("yes")
    render("{{ '' | ternary('yes', 'no') }}").should eq("no")
    render("{{ none | ternary('yes', 'no', 'fallback') }}").should eq("fallback")
    render("{{ none | ternary('yes', 'no') }}").should eq("no")
  end

  it "registers comment with the plain style default" do
    render("{{ 'managed' | comment }}").should eq("#\n# managed\n#")
    render("{{ 'managed' | comment('c') }}").should eq("//\n// managed\n//")
  end

  it "registers to_nice_json with sorted keys by default" do
    render("{{ value | to_nice_json }}", {"value" => JSON.parse(%({"b": 1, "a": 2}))})
      .should eq("{\n    \"a\": 2,\n    \"b\": 1\n}")
  end

  it "registers the string/collection shaping filters" do
    render("{{ 'hello' | b64encode }}").should eq("aGVsbG8=")
    render("{{ 'aGVsbG8=' | b64decode }}").should eq("hello")
    render("{{ 'a/b/c' | basename }}").should eq("c")
    render("{{ 'a/b/c' | dirname }}").should eq("a/b")
    render("{{ 'hello' | md5 }}").should eq("5d41402abc4b2a76b9719d911017c592")
    render("{{ 'hello' | sha1 }}").should eq("aaf4c61ddcc5e8a2dabede0f3b482cd9aea9434d")
    render("{{ 'hello' | checksum }}").should eq("aaf4c61ddcc5e8a2dabede0f3b482cd9aea9434d")
    render("{{ '255.255.255.0' | netmask_to_cidr }}").should eq("24")
    render("{{ 'a.txt' | splitext | join('.') }}").should eq("a..txt")
    render("{{ ['/a/b', '/a/c'] | commonpath }}").should eq("/a")
    render("{{ '1.00 KB' | human_to_bytes }}").should eq("1024")
  end

  it "registers the collection filters and Ansible value helpers" do
    render("{{ {'a': 1, 'b': 2} | omit('a') | tojson }}").should eq(%({"b": 2}))
    render("{{ [] | mandatory }}").should eq("[]")
    render("{{ 'x' | type_debug }}").should eq("str")
    render("{{ [3, 1, 2] | sort | intersect([2, 1]) | join(',') }}").should eq("1,2")
    render("{{ [1, 2, 3] | difference([2]) | join(',') }}").should eq("1,3")
    render("{{ [1, 2] | union([2, 3]) | join(',') }}").should eq("1,2,3")
    render("{{ [1, 2] | product(['a', 'b']) | map('join') | join(' ') }}").should eq("1a 1b 2a 2b")
    render("{{ ['a/b', 'c'] | path_join }}").should eq("a/b/c")
    render("{{ 'a,b' | split(',') | join('|') }}").should eq("a|b")
  end

  it "registers the ipaddr family, jmespath, and conversion filters" do
    render("{{ '192.168.1.0/24' | ipaddr('net') }}").should eq("192.168.1.0/24")
    render("{{ '192.168.1.10' | ipaddr('address') }}").should eq("192.168.1.10")
    render("{{ '10.0.0.0/8' | ipmath(1) }}").should eq("10.0.0.1")
    render("{{ data | json_query('a.b') }}", {"data" => JSON.parse(%({"a": {"b": 7}}))}).should eq("7")
    render("{{ '{\"a\": 1}' | from_json | tojson }}").should eq(%({"a": 1}))
    render("{{ 'a: 1' | from_yaml | tojson }}").should eq(%({"a": 1}))
    render("{{ {'a': 1} | to_yaml }}").should eq("a: 1")
  end

  it "resolves register-result tests against the host context scope" do
    vars = Hash(String, JSON::Any).new
    vars["copy"] = JSON.parse(%({"failed": true, "changed": false, "msg": "boom"}))
    context = Krikri::JinjaHostContext.new(vars)

    render("{{ copy is failed }}", vars, host_context: context).should eq("True")
    render("{{ copy is succeeded }}", vars, host_context: context).should eq("False")
    render("{{ copy is changed }}", vars, host_context: context).should eq("False")
    render("{{ missing_result is failed }}", vars, host_context: context).should eq("False")
  end

  it "delegates the remaining Ansible filters to Krikri's own implementations" do
    vars = Hash(String, JSON::Any).new
    vars["nested"] = JSON.parse(%([["a", "b"], ["c"]]))
    context = Krikri::JinjaHostContext.new(vars)

    render("{{ nested | flatten | join(',') }}", vars, host_context: context).should eq("a,b,c")
    render("{{ 'a-b' | regex_replace('-', '_') }}", vars, host_context: context).should eq("a_b")
    render("{{ {'a': 1} | dict2items | first | tojson }}", vars, host_context: context)
      .should eq(%({"key": "a", "value": 1}))
    render("{{ [{'k': 1, 'v': 'x'}] | items2dict('k', 'v') | tojson }}", vars, host_context: context)
      .should eq(%({"1": "x"}))
  end
end

# Expected values below were live-verified against ansible-core 2.19.
describe "Krikri::KrikriJinjaFilters Ansible tests and remaining filters" do
  it "registers the version, regex, and collection tests" do
    render("{{ '8.9p1' is version('8.10', '<') }}").should eq("True")
    render("{{ 'Port 22' is match('Port') }} {{ 'a Port' is match('Port') }} {{ 'a Port' is search('Port') }}")
      .should eq("True False True")
    render("{{ [1, 2] is subset([1, 2, 3]) }} {{ [1, 2, 3] is superset([3]) }} {{ [1, 2] is contains(2) }}")
      .should eq("True True True")
    render("{{ ['a', 'Port 1'] | select('search', '^Port ') | list }}").should eq("['Port 1']")
  end

  it "treats abs as the path test" do
    render("{{ '/etc/x' is abs }} {{ 'x' is abs }}").should eq("True False")
  end

  it "resolves collection-qualified filter and test names" do
    render("{{ 'a.b' | ansible.builtin.regex_search('b') }} {{ 'x' is ansible.builtin.search('x') }}")
      .should eq("b True")
  end

  it "registers to_json, zip, subelements, and root" do
    render("{{ {'a': 1} | to_json }}").should eq(%({"a": 1}))
    render("{{ ['a', 'b'] | zip([1, 2]) | list }}").should eq("[['a', 1], ['b', 2]]")
    render("{{ users | subelements('keys') | length }}",
      {"users" => JSON.parse(%([{"name": "root", "keys": ["k1", "k2"]}, {"name": "bob", "keys": ["k3"]}]))})
      .should eq("3")
    render("{{ '/etc/hosts' | root }}").should eq("/")
  end

  it "shuffles with Python's seeded permutation" do
    render("{{ [1, 2, 3, 4, 5] | shuffle(seed='host1') | join(',') }}").should eq("5,3,1,2,4")
    render("{{ [1, 2, 3, 4, 5] | shuffle(seed=42) | join(',') }}").should eq("4,2,3,5,1")
    render("{{ 'abcdef' | shuffle(seed='x') | join }}").should eq("ebadcf")
  end

  it "raises on first/last of an empty sequence" do
    expect_raises(KrikriJinja::TemplateError, "No first item, sequence was empty.") do
      render("{{ [] | first }}")
    end
  end

  it "maps items2dict's key_name field to the key" do
    render("{{ [{'k': 'a', 'v': 1}] | items2dict(key_name='k', value_name='v') }}").should eq("{'a': 1}")
    expect_raises(KrikriJinja::TemplateError, "items2dict requires each dictionary in the list to contain the keys 'k' and 'v'") do
      render("{{ [{'k': 1}] | items2dict(key_name='k', value_name='v') }}")
    end
  end
end
