require "../minitest_helper"
require "file_utils"

# The [ERROR] console shapes + registered msgs of loop sources that ARE
# defined but resolve to the wrong type, live-verified against
# ansible-core 2.19.11 (round 5410000, badsectorlabs.ludus_vulhub; local
# 2.19.11 probes re-confirmed every shape below):
#
# - a defined-null `loop:` fails the task with its own bare [ERROR]
#   block ("The `loop` value must resolve to a 'list', not 'NoneType'.")
#   whose Origin points at the loop keyword's VALUE token (not the task
#   name, not the `loop:` key itself), plus the fixed tail line
#   "Provide a list of items/templates, or a template resolving to a
#   list." - and the registered fatal msg is the BARE text, with no
#   "Task failed:" prefix and no "Module failed:" middle;
# - that type error is NEVER when:-shielded (real fails the task even
#   behind `when: false`, where the same when: skips an UNDEFINED
#   source);
# - same verdict inside a block: whose own when: is false, and behind an
#   include_tasks:;
# - a `with_dict:` over a null rides the lookup plugin's own type
#   refusal channel ("The lookup plugin 'dict' failed: ... got 'None'
#   of type <class 'NoneType'>)", Origin: <unknown> + invoke_lookup()),
#   also with a bare registered msg;
# - a `with_items:` over a null keeps real's own scalar-wrapping
#   leniency (one iteration with item=None, success).
#
# This engine used to (a) treat the defined-null loop as empty and skip
# (when:-shielding swallowed the type error) and (b) print the
# triple-wrapped "Task failed: Module failed: Task failed: ..." chain
# with the prefixed registered msg where real prints the bare block.

private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "test", "fixtures", "inventory-explicit-localhost.ini")

private PLAY_HEADER = [
  "---",
  "- hosts: localhost",
  "  gather_facts: false",
  "  connection: local",
  "  vars:",
  "    nullv: null",
  "    usef: false",
  "  tasks:",
]

# A second task after the failing one - the play halts at the failure and
# `msg: AFTER` must never appear.
private AFTER_TASK = ["    - ansible.builtin.debug:", "        msg: AFTER"]

describe "loop: source typing errors" do
  # Writes the playbook (plus optional same-directory sidecar files) and
  # runs it. Returns (success?, output, playbook path).
  private def run_play_file(yaml : String, sidecars : Hash(String, String) = {} of String => String) : {Bool, String, String}
    path = PluginSpecHelper.tmp_path("loop-typing-error-#{Random::Secure.hex(4)}.yml")
    File.write(path, yaml)
    dir = File.dirname(path)
    sidecars.each { |name, content| File.write(File.join(dir, name), content) }
    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, path], output: output, error: output, input: IO::Memory.new)
    {status.success?, output.to_s, File.expand_path(path)}
  ensure
    File.delete(path) if path && File.exists?(path)
    sidecars.try &.each do |name, _|
      file = File.join(File.dirname(path.not_nil!), name)
      File.delete(file) if File.exists?(file)
    end
  end

  # The standard single-task play - the `loop:` value token lands at
  # line 12, column 9 (6-space task-key indent, the round's own role
  # task shape), so the context/caret block is fully predictable.
  it "prints real's exact bare [ERROR] block + tail and registers the bare msg for a defined-null loop" do
    success, output, path = run_play_file((PLAY_HEADER + [
      "    - name: null loop task",
      "      ansible.builtin.debug:",
      "        msg: \"static text\"",
      "      loop: \"{{ nullv }}\"",
    ] + AFTER_TASK).join("\n") + "\n")

    success.must_equal(false)
    output.must_include(
      "[ERROR]: The `loop` value must resolve to a 'list', not 'NoneType'.\n" \
      "Origin: #{path}:12:13\n" \
      "\n" \
      "10       ansible.builtin.debug:\n" \
      "11         msg: \"static text\"\n" \
      "12       loop: \"{{ nullv }}\"\n" \
      "               ^ column 13\n" \
      "\n" \
      "Provide a list of items/templates, or a template resolving to a list.\n")
    output.must_include("fatal: [localhost]: FAILED! => {\"msg\": \"The `loop` value must resolve to a 'list', not 'NoneType'.\"}")
    output.wont_include("Task failed: The `loop` value")
    output.wont_include("Module failed: The `loop` value")
    output.must_include("failed=1")
    output.wont_include("AFTER")
  end

  # Behind `when: false`: real still fails - the loop keyword's type
  # error is raised at task finalization, before any when: verdict
  # (while the same when: skips an UNDEFINED source - the next test).
  it "fails a defined-null loop even behind when: false" do
    success, output, _ = run_play_file((PLAY_HEADER + [
      "    - name: null loop behind when",
      "      ansible.builtin.debug:",
      "        msg: \"static text\"",
      "      loop: \"{{ nullv }}\"",
      "      when: usef",
    ] + AFTER_TASK).join("\n") + "\n")

    success.must_equal(false)
    output.must_include("The `loop` value must resolve to a 'list', not 'NoneType'.")
    output.must_include("Provide a list of items/templates, or a template resolving to a list.")
    output.must_include("fatal: [localhost]: FAILED! => {\"msg\": \"The `loop` value must resolve to a 'list', not 'NoneType'.\"}")
    output.wont_include("AFTER")
  end

  # Regression: an UNDEFINED loop source behind when: false still skips
  # (round174 scenario 7) - the un-shielding is scoped to the type
  # error, the undefined reference keeps its when:-consulted channel.
  it "still skips an undefined loop behind when: false" do
    success, output, _ = run_play_file((PLAY_HEADER + [
      "    - name: undefined loop behind when",
      "      ansible.builtin.debug:",
      "        msg: \"static text\"",
      "      loop: \"{{ nope }}\"",
      "      when: usef",
    ] + AFTER_TASK).join("\n") + "\n")

    success.must_equal(true)
    output.must_include("skipping: [localhost]")
    output.must_include("AFTER")
    output.must_include("failed=0")
  end

  # A null loop inside a BLOCK whose when: is false (inherited False):
  # real fails the child with the same shape, never skipping.
  it "fails a defined-null loop inside a when:-false block" do
    success, output, _ = run_play_file((PLAY_HEADER + [
      "    - block:",
      "        - name: null loop in block",
      "          ansible.builtin.debug:",
      "            msg: \"static text\"",
      "          loop: \"{{ nullv }}\"",
      "      when: false",
    ] + AFTER_TASK).join("\n") + "\n")

    success.must_equal(false)
    output.must_include("The `loop` value must resolve to a 'list', not 'NoneType'.")
    output.must_include("fatal: [localhost]: FAILED! => {\"msg\": \"The `loop` value must resolve to a 'list', not 'NoneType'.\"}")
    output.wont_include("AFTER")
  end

  # include_tasks: with a null loop: - real fails the include task
  # itself, before any included file is entered (same Origin shape).
  it "fails a defined-null include_tasks: loop" do
    success, output, _ = run_play_file((PLAY_HEADER + [
      "    - name: null include loop",
      "      ansible.builtin.include_tasks: included-tasks.yml",
      "      loop: \"{{ nullv }}\"",
    ] + AFTER_TASK).join("\n") + "\n",
      {"included-tasks.yml" => "---\n- name: child\n  ansible.builtin.debug:\n    msg: child\n"})

    success.must_equal(false)
    output.must_include("The `loop` value must resolve to a 'list', not 'NoneType'.")
    output.must_include("Provide a list of items/templates, or a template resolving to a list.")
    output.must_include("fatal: [localhost]: FAILED! => {\"msg\": \"The `loop` value must resolve to a 'list', not 'NoneType'.\"}")
    output.wont_include("msg: child")
  end

  # A non-list scalar loop: source (here the `usef: false` bool, a
  # defined value like the round's NoneType source) keeps its own
  # non-list type error, now bare with the same block shape (the
  # wording family was already pinned by loop_source_list_type_test).
  it "gives a scalar loop: the bare msg and the same [ERROR] shape" do
    success, output, _ = run_play_file((PLAY_HEADER + [
      "    - name: scalar loop task",
      "      ansible.builtin.debug:",
      "        msg: \"static text\"",
      "      loop: \"{{ usef }}\"",
    ] + AFTER_TASK).join("\n") + "\n")

    success.must_equal(false)
    output.must_include("The `loop` value must resolve to a 'list', not 'bool'.")
    output.must_include("Provide a list of items/templates, or a template resolving to a list.")
    output.must_include("fatal: [localhost]: FAILED! => {\"msg\": \"The `loop` value must resolve to a 'list', not 'bool'.\"}")
    output.wont_include("Task failed: The `loop` value")
  end

  # with_dict: keeps the lookup plugin's own type-refusal channel
  # (NOT the `loop:` TypeError block): Origin: <unknown> +
  # invoke_lookup(), bare registered msg, failed=1.
  it "fails a with_dict: over a defined null with the dict lookup's own refusal shape" do
    success, output, _ = run_play_file((PLAY_HEADER + [
      "    - name: null dict loop",
      "      ansible.builtin.debug:",
      "        msg: \"{{ item.key }}\"",
      "      with_dict: \"{{ nullv }}\"",
    ] + AFTER_TASK).join("\n") + "\n")

    success.must_equal(false)
    output.must_include(
      "[ERROR]: The lookup plugin 'dict' failed: the 'dict' lookup plugin expects a dictionary, got 'None' of type <class 'NoneType'>)")
    output.must_include("Origin: <unknown>")
    output.must_include("invoke_lookup()")
    output.must_include(
      "fatal: [localhost]: FAILED! => {\"msg\": \"The lookup plugin 'dict' failed: the 'dict' lookup plugin expects a dictionary, got 'None' of type <class 'NoneType'>)\"}")
    output.wont_include("Task failed: The lookup plugin 'dict' failed")
    output.must_include("failed=1")
    output.wont_include("AFTER")
  end

  # with_items:'s own scalar-wrapping leniency survives: a defined null
  # is one iteration with item=None, success, not a failure.
  it "keeps with_items:'s scalar-wrapping for a defined null" do
    success, output, _ = run_play_file((PLAY_HEADER + [
      "    - name: null items loop",
      "      ansible.builtin.debug:",
      "        msg: \"{{ item }}\"",
      "      with_items: \"{{ nullv }}\"",
    ] + AFTER_TASK).join("\n") + "\n")

    success.must_equal(true)
    output.must_include("ok: [localhost] => (item=None)")
    output.must_include("AFTER")
    output.must_include("failed=0")
    output.wont_include("must resolve to a 'list'")
  end

# Bare scalar loop sources (janneojala.strongswan round 5410000:
# `with_items: strongswan`; probed vs 2.19.11 2026-10-10):
# - with_items:/with_list: on a bare scalar = ONE literal item
# - loop: on a bare scalar fails the typing check with 'str'
  it "with_items on a bare string loops once with the literal" do
    _ok, output, _pb = run_play_file(<<-YAML)
      - hosts: all
        gather_facts: false
        tasks:
          - ansible.builtin.debug:
              msg: "ITEM|{{ item }}"
            with_items: strongswan
      YAML
    output.must_include("ITEM|strongswan")
  end

  it "with_list on a bare string loops once with the literal" do
    _ok, output, _pb = run_play_file(<<-YAML)
      - hosts: all
        gather_facts: false
        tasks:
          - ansible.builtin.debug:
              msg: "WL|{{ item }}"
            with_list: strongswan
      YAML
    output.must_include("WL|strongswan")
  end

  it "with_items on a bare int loops once with the int" do
    _ok, output, _pb = run_play_file(<<-YAML)
      - hosts: all
        gather_facts: false
        tasks:
          - ansible.builtin.debug:
              msg: "WI|{{ item }}"
            with_items: 5
      YAML
    output.must_include("WI|5")
  end

  it "loop on a bare string fails the typing check with 'str'" do
    _ok, output, _pb = run_play_file(<<-YAML)
      - hosts: all
        gather_facts: false
        tasks:
          - ansible.builtin.debug:
              msg: "LP|{{ item }}"
            loop: strongswan
      YAML
    output.must_include("The `loop` value must resolve to a 'list', not 'str'.")
    output.wont_include("is undefined")
  end
end
