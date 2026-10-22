require "../minitest_helper"
require "file_utils"

# ansible-core 2.19.11's variable storage warns whenever a task param's
# whole-value `{{ ... }}` expression still yields a jinja2 Markup at
# storage time: the `safe` filter produces Markup and the string-shaping
# filters after it leave it one, so storage converts to 'str' and prints
# "[WARNING]: Type 'Markup' is unsupported in variable storage, converting
# to 'str'." with an Origin block at the param's value token - deduped to
# ONE display for a loop's items (live-verified vs 2.19.11, localhost).
# Text around the expression ("{{ d | safe }}/x") never produces a lone
# whole-value Markup, so it does not warn.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "test", "fixtures", "inventory-explicit-localhost.ini")

# The minitest suite gives every test its own tmp_path subtree instead of
# a process-wide /tmp spec dir (see the groupby storage-warning test).
private def tmp_path(name : String) : String
  PluginSpecHelper.tmp_path(name)
end

describe "Markup storage warning for safe-filtered task params" do
  it "warns once at the value token for item|safe|trim, not for text around the expression" do
    playbook = tmp_path("markup-warning.yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        gather_facts: false
        vars:
          d: "abc"
        tasks:
          - debug:
              msg: "{{ item|safe|trim }}"
            with_items:
              - "a"
              - "b"
          - debug:
              msg: "{{ d | safe }}/x"
      YAML

    # The warning goes to stderr (like Ansible's Display) and the play to
    # stdout, drained by independent pipes - asserting each stream on its
    # own buffer pins the real split (same reasoning as the groupby
    # storage-warning test).
    stdout = IO::Memory.new
    stderr = IO::Memory.new
    Process.run(BINARY, ["-i", INVENTORY, playbook],
      output: stdout, error: stderr, chdir: File.dirname(playbook))
    out = stdout.to_s
    warnings = stderr.to_s

    # both tasks ran (rendered values match ansible's localhost run)
    out.must_include("abc/x")
    out.must_include("\"msg\": \"a\"")
    out.must_include("\"msg\": \"b\"")
    # exactly one warning: the looped task's msg param (both items share
    # the param's origin), nothing for the text-around-expression task
    warnings.scan("Type 'Markup' is unsupported in variable storage").size.must_equal(1)
    warnings.must_include("[WARNING]: Type 'Markup' is unsupported in variable storage, converting to 'str'.")
    # Origin at the value token's first char - the opening quote of the
    # quoted block-style msg value (line 7, col 14 in the written file)
    warnings.must_include("Origin: #{playbook}:7:14")
    warnings.must_include("^ column 14")
  end
end
