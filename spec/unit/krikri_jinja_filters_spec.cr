require "../spec_helper"
require "../../src/krikri/variable_substitutor/filter_engine"
require "../../src/krikri/krikri_jinja_filters"

private def render(source : String, vars : Hash(String, JSON::Any) = {} of String => JSON::Any) : String
  KrikriJinja.render(source, vars)
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
end
