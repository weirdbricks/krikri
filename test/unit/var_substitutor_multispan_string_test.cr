require "../minitest_helper"
require "../../src/krikri/variable_substitutor"

# GitHub issue #282 (timorunge.custom_nginx, round round29879659): a
# variable whose value is a MULTI-segment template
# (`"{{ dirs }} + {{ extra | default(omit) }}"`, two `{{ }}` spans with
# literal text between them) used to be re-templated into the FIRST
# span's own native value (`['a', 'b']`, the ` + {{ extra }}` remainder
# dropped whole). Real ansible-core 2.19 renders such a value as a plain
# STR - a Jinja render of mixed text, whose interpolation of a container
# is Python's repr - so `{{ all }}` prints "['a', 'b'] + ['c']" and
# `{{ all | hash('sha1') }}` hashes THAT text, while a whole
# single-span value keeps native typing (Rerender.whole_span_structured
# convention). The shape mirrors the role's own
# `custom_nginx_all_directories`; the var name is generic so the test
# stays about the shape, not the role.
describe "Krikri::VariableSubstitutor (var_substitutor_multispan_string_test.cr)" do
  def subject_vars : Hash(String, JSON::Any)
    v = Hash(String, JSON::Any).new
    v["dirs"] = JSON.parse(%(["a", "b"]))
    v["extra"] = JSON.parse(%(["c"]))
    v["all"] = JSON::Any.new("{{ dirs }} + {{ extra | default(omit) }}")
    v
  end

  it "resolves a multi-span combined-list var to the rendered string, not the first span's list" do
    subst = Krikri::VarSubstitutor.new(vars: subject_vars, host_name: "h")
    subst.substitute("{{ all }}").must_equal("['a', 'b'] + ['c']")
  end

  it "hashes the multi-span var's rendered string through the filter chain" do
    subst = Krikri::VarSubstitutor.new(vars: subject_vars, host_name: "h")
    # sha1 of the plain-str render "['a', 'b'] + ['c']" (the role's
    # checksum_catalog.yml.j2 hashes exactly this text, so the string has
    # to match ansible byte for byte - live-verified vs 2.19.11).
    subst.substitute("{{ all | hash('sha1') }}").must_equal("bac1a7aa5263c1c20a46a06dc30cb1498382e276")
  end

  it "keeps a whole-single-span var reference natively typed" do
    v = subject_vars
    v["lists"] = JSON::Any.new("{{ [dirs, extra] }}")
    subst = Krikri::VarSubstitutor.new(vars: v, host_name: "h")
    # Native typing convention (Rerender.whole_span_structured): one whole
    # span is the expression's own value - here the nested Jinja list
    # literal - so the shape is untouched.
    subst.substitute("{{ lists }}").must_equal([["a", "b"], ["c"]].to_json)
  end

  it "flattens a string operand to its characters like ansible" do
    subst = Krikri::VarSubstitutor.new(vars: subject_vars, host_name: "h")
    # Flatten iterates whatever container it receives (python `for element
    # in mylist`): a str operand iterates to characters, exactly like the
    # real `loop:
    # "{{ custom_nginx_all_directories | flatten(levels=1) }}"` of the
    # issue's role once the var is the proper string (live-verified vs
    # 2.19.11, one item per character).
    subst.substitute("{{ all | flatten(levels=1) }}")
      .must_equal(["[", "'", "a", "'", ",", " ", "'", "b", "'", "]", " ", "+", " ", "[", "'", "c", "'", "]"].to_json)
  end

  # The repr path's container elements can THEMSELVES be templates (same
  # role's own shape:`dirs: ["{{ prefix }}", "{{ prefix }}/build"]` against
  # `prefix: /usr/local/nginx`): ansible's templar resolves a var REFERENCE
  # (`{{ dirs }}`) recursively, rendering each nested string first, so the
  # mixed-text repr carries the rendered values
  # (`['/usr/local/nginx', ...]`), never raw `{{ prefix }}` text. krikri's
  # plain-reference fast path used to hand the stored container straight to
  # the repr serializer with its nested templates still unrendered (the
  # string-element branch re-rendered; only the container branch was
  # missing), so flatten(levels=1) then iterated CHARACTERS of raw
  # template text.
  def nested_vars : Hash(String, JSON::Any)
    v = Hash(String, JSON::Any).new
    v["prefix"] = JSON.parse(%("/usr/local/nginx"))
    v["dirs"] = JSON.parse(%(["{{ prefix }}", "{{ prefix }}/build"]))
    v["extra"] = JSON.parse(%([]))
    v["all"] = JSON::Any.new("{{ dirs }} + {{ extra | default(omit) }}")
    v
  end

  it "deep-renders nested templates in the repr span's container value" do
    subst = Krikri::VarSubstitutor.new(vars: nested_vars, host_name: "h")
    subst.substitute("{{ all }}").must_equal("['/usr/local/nginx', '/usr/local/nginx/build'] + []")
  end

  it "hashes the repr text built from nested-template elements" do
    subst = Krikri::VarSubstitutor.new(vars: nested_vars, host_name: "h")
    # sha1 of the repr text an actual ansible render produces for the same
    # vars (the role hashes this text into checksum_catalog.yml.j2).
    subst.substitute("{{ all | hash('sha1') }}").must_equal("73b40b3c844ae374b2d44e658f2ae41db9861f5b")
  end

  # The remaining half of issue #282: whole-single-span LIST vars hashed
  # as their own native container (the multi-span `all` above resolves to
  # a plain str first, these do not). The role's checksum_catalog.yml.j2
  # also hashes `dirs`/`opts` list vars whose ELEMENTS are themselves
  # templates (`["--prefix={{ prefix }}", "--with-compat"]` against
  # `prefix: /usr/local/nginx`). Ansible's hash filter
  # (plugins/filter/core.py) digests to_bytes(str(container)) of the
  # already-templated native value - Python's str() is the repr form
  # (`['--prefix=/usr/local/nginx', '--with-compat']`, single quotes,
  # ", " separators), while krikri's own as_string used the internal
  # JSON spelling (`["--prefix=/usr/local/nginx","--with-compat"]`), so
  # every such sha1 diverged byte for byte. The hashes below are real
  # ansible 2.19's outputs for this exact shape (live-verified).
  def templated_list_vars : Hash(String, JSON::Any)
    v = Hash(String, JSON::Any).new
    v["prefix"] = JSON.parse(%("/usr/local/nginx"))
    v["dirs"] = JSON.parse(%(["{{ prefix }}", "{{ prefix }}/build"]))
    v["opts"] = JSON.parse(%(["--prefix={{ prefix }}", "--with-compat"]))
    v
  end

  it "hashes a templated-element list var as python's str() repr" do
    subst = Krikri::VarSubstitutor.new(vars: templated_list_vars, host_name: "h")
    subst.substitute("{{ dirs | hash('sha1') }}")
      .must_equal("1fa5f5943b88f88a0d668ef525481169a254303e")
    subst.substitute("{{ opts | hash('sha1') }}")
      .must_equal("694d7c687f85a3f2f3088031e387543c71b17f0c")
  end

  # str()/repr() descend into nested containers as well - a plan-level
  # var like timorunge.custom_nginx's `patches`/inline dicts with
  # templated values has to hash the same nested-repr text ansible does,
  # on the same single-site fix (the hash filter case, shared with the
  # .j2 engine via the delegate registration); without the recursion a
  # two-level dict hashed only its top-level JSON text differently.
  def templated_nested_vars : Hash(String, JSON::Any)
    v = templated_list_vars
    v["cfg"] = JSON.parse(%({"one": ["{{ prefix }}", "plain"], "two": {"x": "--prefix={{ prefix }}"}}))
    v
  end

  it "hashes a nested templated dict/list as python's str() repr" do
    subst = Krikri::VarSubstitutor.new(vars: templated_nested_vars, host_name: "h")
    subst.substitute("{{ cfg | hash('sha1') }}")
      .must_equal("14aa1c43eb36593f66995e1f9b715fb586d8ad17")
  end
end
