require "../spec_helper"
require "../../src/krikri/variable_substitutor/filter_core"

# The ONE shared implementation for the string/path filter family (was
# two independently-maintained copies - Crinja-side in jinja_filters.cr,
# JSON::Any-side in filter_engine.cr - with regex_replace already
# drifted: the Crinja copy used Crystal's native gsub backref expansion,
# the engine copy a hand-rolled `\\d` substitution).
describe Krikri::VariableSubstitutor::FilterCore do
  it "regex_replace substitutes every match with backreferences" do
    Krikri::VariableSubstitutor::FilterCore.regex_replace("v1.12.1", "^v?([0-9.]+)$", "\\1")
      .should eq("1.12.1")
    Krikri::VariableSubstitutor::FilterCore.regex_replace("a-b-c", "-", "+")
      .should eq("a+b+c")
  end

  it "regex_replace renders a non-participating group as empty" do
    Krikri::VariableSubstitutor::FilterCore.regex_replace("abc", "(x)|(abc)", "\\1\\2")
      .should eq("abc")
  end

  it "regex_escape escapes special characters" do
    Krikri::VariableSubstitutor::FilterCore.regex_escape("a.b*c")
      .should eq(Regex.escape("a.b*c"))
  end

  it "normpath collapses . and .. without absolutizing" do
    core = Krikri::VariableSubstitutor::FilterCore
    core.normpath("/a/./b//c").should eq("/a/b/c")
    core.normpath("a/../b").should eq("b")
    core.normpath("../a").should eq("../a")
    core.normpath("").should eq(".")
  end

  it "splitext splits root and extension Python-style" do
    core = Krikri::VariableSubstitutor::FilterCore
    core.splitext("/etc/nginx/nginx.conf").should eq({"/etc/nginx/nginx", ".conf"})
    core.splitext("/etc/nginx/nginx").should eq({"/etc/nginx/nginx", ""})
  end

  it "commonpath finds the longest shared SEGMENT prefix" do
    core = Krikri::VariableSubstitutor::FilterCore
    core.commonpath(["/var/log/nginx", "/var/log/redis"]).should eq("/var/log")
    core.commonpath(["/var/log/a", "/var/lib/b"]).should eq("/var")
    core.commonpath([] of String).should eq("")
    # not a character prefix: "common" != "commondir"
    # not a character prefix: "common" != "commondir" -> only the
    # root segment is shared
    core.commonpath(["/common", "/commondir"]).should eq("/")
  end

  it "path_join resets on absolute components" do
    core = Krikri::VariableSubstitutor::FilterCore
    core.path_join(["a", "b", "c"]).should eq("a/b/c")
    core.path_join(["a", "/etc", "c"]).should eq("/etc/c")
  end

  it "expandvars leaves unset variables as-is" do
    core = Krikri::VariableSubstitutor::FilterCore
    core.expandvars("no vars here").should eq("no vars here")
    # $KRIKRI_SURELY_UNSET must survive untouched (Python's own behavior)
    core.expandvars("$KRIKRI_SURELY_UNSET/x").should eq("$KRIKRI_SURELY_UNSET/x")
    core.expandvars("${KRIKRI_SURELY_UNSET}/x").should eq("${KRIKRI_SURELY_UNSET}/x")
  end

  it "type_debug maps to Python type names" do
    core = Krikri::VariableSubstitutor::FilterCore
    core.type_debug(JSON.parse("[1,2]")).should eq("list")
    core.type_debug(JSON.parse(%({"a": 1}))).should eq("dict")
    core.type_debug(JSON.parse("3")).should eq("int")
    core.type_debug(JSON.parse("3.5")).should eq("float")
    core.type_debug(JSON.parse("true")).should eq("bool")
    core.type_debug(JSON.parse("null")).should eq("NoneType")
    core.type_debug(JSON.parse(%("s"))).should eq("str")
  end
end
