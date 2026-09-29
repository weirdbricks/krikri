require "../minitest_helper"

# A task param whose ENTIRE value is one bare `{{ }}` span is natively
# typed the way real Ansible's own module args are (live-verified vs
# ansible-playbook 2.19.11: `apt: name: "{{ pkg_list }}"` with a real
# list var looks up the clean ELEMENTS - "No package matching
# 'probe-pkg-one'" - and `debug: msg: "{{ pkg_list }}"` prints a real
# list), so the plugin wire carries the double-quoted JSON container
# form. Previously it carried Python-repr text, forcing every
# list-param plugin to "repair" single-quoted repr back into a
# container - a repair that also swallowed values that merely LOOK
# like a repr (a literal `name: "['a']"` string, or a block tag's
# rendered output - both plain strings in real Ansible) into
# containers real Ansible never had. Mixed text keeps the repr form
# (live-verified: `msg: "pre {{ list }} post"` prints
# "pre ['a', 'b'] post").
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "test", "fixtures", "inventory-explicit-localhost.ini")

private def run_playbook(yaml : String)
  playbook = File.tempname("whole-span-wire", ".yml")
  File.write(playbook, yaml)
  output = IO::Memory.new
  status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)
  {status, output.to_s}
ensure
  File.delete(playbook) if playbook && File.exists?(playbook)
end

describe "whole-span `{{ }}` module args carry the JSON container wire form" do
  it "renders a whole-value list var as double-quoted JSON (not Python repr)" do
    status, output = run_playbook(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        vars:
          pkg_list: ['probe-pkg-one', 'probe-pkg-two']
        tasks:
          - name: show
            ansible.builtin.debug:
              msg: "{{ pkg_list }}"
      YAML

    status.success?.must_equal(true)
    # Real ansible-core 2.19.11 (live-captured, non-tty) pretty-prints the
    # native container msg across lines:
    #   "msg": [
    #       "probe-pkg-one",
    #       "probe-pkg-two"
    #   ]
    # - the double-quoted JSON element form, never Python repr.
    output.must_include("\"msg\": [")
    output.must_include("\"probe-pkg-one\"")
    output.must_include("\"probe-pkg-two\"")
    output.wont_include("['probe-pkg-one', 'probe-pkg-two']")
  end

  it "keeps mixed text in Python repr form (real Ansible's display rendering)" do
    status, output = run_playbook(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        vars:
          pkg_list: ['probe-pkg-one', 'probe-pkg-two']
        tasks:
          - name: show
            ansible.builtin.debug:
              msg: "pre {{ pkg_list }} post"
      YAML

    status.success?.must_equal(true)
    output.must_include("pre ['probe-pkg-one', 'probe-pkg-two'] post")
  end

  it "keeps a block-tag's repr-looking output a plain string" do
    # Same bug class as the block-tag native-typing fix (0.9.1039,
    # HanXHX.debian_bootstrap): block-tag output is never natively
    # typed, so even at the module-arg boundary it stays the literal
    # string - no re-parse on either side of the wire.
    status, output = run_playbook(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: show
            ansible.builtin.debug:
              msg: "{{ pkg_list }}"
            vars:
              pkg_list: "{% if false %}{{ x }}{% else %}['dummy']{% endif %}"
      YAML

    status.success?.must_equal(true)
    output.must_include("['dummy']")
    output.wont_include("[\"dummy\"]")
  end

  it "keeps a literal repr-looking string value a plain string" do
    status, output = run_playbook(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        vars:
          repr_string: "['a', 'b']"
        tasks:
          - name: show
            ansible.builtin.debug:
              msg: "{{ repr_string }}"
      YAML

    status.success?.must_equal(true)
    # `is string` semantics: real Ansible keeps this a str (live-
    # verified alongside the set_fact shapes) - the wire text is the
    # string itself, never re-parsed into a container.
    output.must_include("['a', 'b']")
  end

  it "renders a whole-value empty-list var as the empty JSON container text" do
    # The same text the parser now stringifies a LITERAL empty list to
    # (parse_module_params's empty-list branch), so templated and
    # literal empty lists are indistinguishable - both "no packages"
    # for a list param, never the ambiguous "".
    status, output = run_playbook(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        vars:
          maybe_empty: "{{ missing_var | default([]) }}"
        tasks:
          - name: show
            ansible.builtin.debug:
              msg: "{{ maybe_empty }}"
      YAML

    status.success?.must_equal(true)
    output.must_include("[]")
  end

  it "stringifies a literal empty list param to \"[]\" (distinguishable from an empty string)" do
    # Real Ansible (live-verified vs ansible-playbook 2.19.11 in check
    # mode): `apt: {name: []}` is "no packages" (cache update only),
    # while `apt: {name: ""}` hard-fails "No package matching '' is
    # available" - the empty-list-vs-empty-string distinction survives
    # the String-valued plugin wire via this "[]" text.
    status, output = run_playbook(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: show
            ansible.builtin.debug:
              msg: []
      YAML

    status.success?.must_equal(true)
    output.wont_include("Nothing to do")
    output.must_include("[]")
  end
end
