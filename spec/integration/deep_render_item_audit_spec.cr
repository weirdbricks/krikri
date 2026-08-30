require "../spec_helper"

# Runs the compiled binary against a real playbook (not --check mode,
# real localhost connection) since this bug is specifically about
# TaskExecutor#deep_render_item, a private method not reachable from a
# unit spec without constructing a whole TaskExecutor.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "spec", "fixtures", "inventory-explicit-localhost.ini")

describe "loop: item whose native-type value is itself unrendered Jinja" do
  it "falls through to full substitution rather than handing back literal unparsed {{ }} text" do
    # Proactive audit (2026-08-11), not found via a real-host round:
    # after finding 5 independent copies of the recursive-re-templating
    # bug across rounds 2-3, grepped every remaining VariableLookup#
    # resolve call site in the engine. deep_render_item's own native-
    # type-preservation fast path (loop: "{{ some_var }}" resolving to
    # the variable's real JSON type rather than a stringified value) was
    # one of them: if the resolved value's OWN raw form was itself still
    # unrendered Jinja (a role default computed from another default),
    # it was returned as-is - handing the literal, unparsed "{{ ... }}"
    # text to the task as `item` instead of falling through to the
    # #substitute path just below, which actually renders it.
    playbook = File.tempname("deep-render-item-audit", ".yml")
    File.write(playbook, <<-YAML)
      - name: repro
        hosts: localhost
        gather_facts: false
        vars:
          templated_default: "{{ real_value }}"
          real_value: 42
        tasks:
          # Two elements, not one - a single-element list holding one
          # bare {{ }} span is real Ansible's own with_items: flatten-
          # one-level idiom (a SEPARATE mechanism, find_loop_template in
          # playbook_parser.cr) and would exercise that instead of this
          # fix.
          - name: t
            ansible.builtin.debug:
              msg: "{{ item }}"
            loop:
              - "{{ templated_default }}"
              - "literal"
            register: result
          - name: assert
            ansible.builtin.assert:
              that:
                - result.results[0].msg == "42"
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)

    # The assert task itself is the real check (msg == "42", the fully
    # re-rendered native value) - not asserting on the whole output,
    # since the loop item's own cosmetic display label ("=> (item=...)")
    # is a separate, unrelated concern that legitimately still shows the
    # raw template text.
    status.success?.should be_true
    output.to_s.should contain("All assertions passed")
  ensure
    File.delete(playbook) if playbook && File.exists?(playbook)
  end

  it "preserves native Hash typing through TWO levels of indirection, in a 2+-element loop" do
    # Real bug found benchmarking buluma.confluence (round 165, WITH
    # batching enabled - though confirmed to reproduce identically with
    # --no-batching too, not actually batching-specific): geerlingguy/
    # buluma's own common `release -> version -> download-dict` idiom -
    # `confluence_download: "{{ _confluence_download[confluence_version]
    # }}"`, itself resolving to ANOTHER unrendered "{{ }}" string (one
    # level of indirection deep already) - handled correctly by the fix
    # above for a single loop item, but the ABOVE fix only ever
    # re-resolved ONE level (returning the still-templated intermediate
    # string as-is once its raw wasn't a plain non-template value),
    # never re-checking whether THAT intermediate result itself still
    # needed a second pass. `item` ended up bound to the STRINGIFIED
    # dict text (having fallen through to the generic, always-
    # stringifying #substitute path) instead of a real Hash, so `item.
    # checksum` (a genuine nested-hash dotted lookup two tasks later)
    # correctly reported "undefined" against a value that was never
    # actually a Hash to begin with. Only surfaces with 2+ loop items -
    # a single-element array of one bare `{{ }}` expression takes an
    # entirely different, already-correct path via #find_loop_template's
    # own single-element special case (see the test above).
    playbook = File.tempname("deep-render-item-two-level", ".yml")
    File.write(playbook, <<-YAML)
      - name: repro
        hosts: localhost
        gather_facts: false
        vars:
          _inner:
            key1:
              greeting: hello
          outer_key: key1
          middle: "{{ _inner[outer_key] }}"
          middle2: "{{ _inner[outer_key] }}"
        tasks:
          - name: t
            ansible.builtin.debug:
              msg: "{{ item.greeting | default('MISSING') }}"
            loop:
              - "{{ middle }}"
              - "{{ middle2 }}"
            register: result
          - name: assert
            ansible.builtin.assert:
              that:
                - result.results[0].msg == "hello"
                - result.results[1].msg == "hello"
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)

    status.success?.should be_true
    output.to_s.should contain("All assertions passed")
  ensure
    File.delete(playbook) if playbook && File.exists?(playbook)
  end
end
