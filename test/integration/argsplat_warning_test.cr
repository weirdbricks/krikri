require "../minitest_helper"

# Real ansible-core 2.19.11's console warning for a task whose module args
# are a SINGLE all-template string (`copy: "{{ some_dict }}"`),
# live-verified against 2.19.11 - every expectation below is real's own
# output with tmp paths masked.
#
# Real's trigger (ansible/playbook/task.py post_validate +
# ansible/_internal/_task.py TaskArgsFinalizer) is NOT "renders to a dict":
# it is "the module does not take free-form params AND the string args
# STARTS AND ENDS with a Jinja delimiter". So:
#   - `copy: "{{ d }}"`, a `vars:`-defined dict, a loop item, a block or
#     role task - all warn
#   - `command: "{{ cmd }}"` (free-form module) - no warning
#   - `{path: "{{ p }}"}` (templated VALUES) - no warning
#   - `when: false` - no warning (finalization never runs)
#   - `no_log:` does NOT suppress it; `ignore_errors:`/`check_mode:` don't
#     either
#   - ONE warning per task occurrence: 2 hosts and a 2-item loop still
#     print it once
# The Origin points at the first character OF the scalar - inside the
# quotes for a quoted value (column 29 for a 6-space-indented
# `ansible.builtin.copy: "{{ d }}"`, single or double quotes alike).

private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "test", "fixtures", "inventory-explicit-localhost.ini")

private WARNING_LINE = "[WARNING]: Using a template for task args is unsafe in some situations " \
                       "(see https://docs.ansible.com/ansible/devel/reference_appendices/faq.html#argsplat-unsafe)."

private DICT_VARS = [
  "  vars:",
  "    some_dict:",
  "      content: hello",
] of String

# Appends a `dest:` line to the vars block pointing at a private,
# never-reused path. Every test that runs a copy through some_dict needs
# its OWN dest: they all run concurrently under `-- -p 4`, and two tests
# writing the same file race (one re-creates the file between the other's
# delete and its own copy, flipping that task's result from changed to
# ok). Unique per test also means no test has to delete the dest at all.
private def dict_vars_for(tag : String) : Array(String)
  DICT_VARS + ["      dest: #{private_dest(tag)}"]
end

private def private_dest(tag : String) : String
  "/tmp/argsplat-warning-#{tag}-#{Random::Secure.hex(6)}.txt"
end

private PLAY_HEADER = [
  "- hosts: localhost",
  "  gather_facts: false",
  "  connection: local",
]

# `tasks` are task lines already indented for the play's `tasks:` list;
# `vars_lines` (optional) are already-indented play-level lines (the
# `vars:` block).
private def run_play(tasks : Array(String), vars_lines : Array(String) = [] of String) : {Bool, String}
  playbook = File.tempname("argsplat-warning", ".yml")
  body = PLAY_HEADER.dup
  body.concat(vars_lines)
  body << "  tasks:"
  body.concat(tasks)
  File.write(playbook, body.join("\n") + "\n")
  output = IO::Memory.new
  status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output, input: IO::Memory.new)
  {status.success?, output.to_s}
ensure
  File.delete(playbook) if playbook && File.exists?(playbook)
end

private def warning_count(output : String) : Int32
  output.scan(WARNING_LINE).size
end

# The warning's Origin LINE:COL, nil when the task printed no warning.
private def warning_origin(output : String) : Tuple(String, String)?
  idx = output.index(WARNING_LINE)
  return nil unless idx
  match = output[(idx + WARNING_LINE.size)..].to_s.match(/Origin: .*\.yml:(\d+):(\d+)\n/)
  match ? {match[1], match[2]} : nil
end

describe "argsplat warning" do
  it "warns with an Origin at the templated args scalar for a vars-defined dict" do
    success, output = run_play([
      "    - name: templated args",
      "      ansible.builtin.copy: \"{{ some_dict }}\"",
    ], dict_vars_for("varsdict"))
    success.must_equal(true, output)
    warning_count(output).must_equal(1)

    origin = warning_origin(output)
    origin.not_nil!.must_equal({"10", "29"})
    output.includes?("^ column 29").must_equal(true)
    output.includes?("changed: [localhost]").must_equal(true)
  end

  it "does not warn for templated dict VALUES" do
    success, output = run_play([
      "    - name: templated value",
      "      ansible.builtin.copy:",
      "        content: hello",
      "        dest: /tmp/argsplat-warning-values.txt",
    ])
    success.must_equal(true, output)
    warning_count(output).must_equal(0)
  end

  it "does not warn for a free-form module given a templated string" do
    success, output = run_play([
      "    - name: free form",
      "      ansible.builtin.command: \"{{ cmd }}\"",
    ], ["  vars:", "    cmd: /bin/true"])
    success.must_equal(true, output)
    warning_count(output).must_equal(0)
  end

  it "does not warn for a when-false skipped task" do
    success, output = run_play([
      "    - name: skipped",
      "      ansible.builtin.copy: \"{{ some_dict }}\"",
      "      when: false",
    ], dict_vars_for("whenfalse"))
    success.must_equal(true, output)
    warning_count(output).must_equal(0)
    output.includes?("skipping: [localhost]").must_equal(true)
  end

  it "warns once for a loop task, not once per item" do
    success, output = run_play([
      "    - name: looped",
      "      ansible.builtin.copy: \"{{ item }}\"",
      "      loop:",
      "        - {content: one, dest: /tmp/argsplat-warning-loop1.txt}",
      "        - {content: two, dest: /tmp/argsplat-warning-loop2.txt}",
    ])
    success.must_equal(true, output)
    warning_count(output).must_equal(1)
  end

  it "warns under no_log, ignore_errors and check_mode alike" do
    success, output = run_play([
      "    - name: no_log",
      "      ansible.builtin.copy: \"{{ some_dict }}\"",
      "      no_log: true",
      "    - name: ignore_errors",
      "      ansible.builtin.copy: \"{{ some_dict }}\"",
      "      ignore_errors: true",
      "    - name: check_mode",
      "      ansible.builtin.copy: \"{{ some_dict }}\"",
      "      check_mode: true",
    ], dict_vars_for("nolog"))
    success.must_equal(true, output)
    warning_count(output).must_equal(3)
  end

  it "warns for single-quoted and non-FQCN module calls at the same column" do
    success, output = run_play([
      "    - name: single quoted",
      "      ansible.builtin.copy: '{{ some_dict }}'",
      "    - name: short name",
      "      copy: \"{{ some_dict }}\"",
    ], dict_vars_for("quotes"))
    success.must_equal(true, output)
    warning_count(output).must_equal(2)
    # One past the opening quote, whichever quote was used; the short
    # module name simply makes that column smaller.
    output.scan(/Origin: .*\.yml:(\d+):(\d+)\n/).map(&.[2].to_i).must_equal([29, 13])
  end

  it "does not warn for a folded value that is not all one template" do
    success, output = run_play([
      "    - name: folded",
      "      ansible.builtin.copy: >",
      "        {{ some_dict }}",
      "      ignore_errors: true",
    ], dict_vars_for("folded"))
    success.must_equal(true, output)
    warning_count(output).must_equal(0)
  end

  it "warns for a templated args task nested in a block" do
    success, output = run_play([
      "    - name: enclosing block",
      "      block:",
      "        - name: nested",
      "          ansible.builtin.copy: \"{{ some_dict }}\"",
    ], dict_vars_for("nested"))
    success.must_equal(true, output)
    warning_count(output).must_equal(1)
    warning_origin(output).not_nil!.must_equal({"12", "33"})
  end

  # Real's is_possibly_all_template also accepts the `{% ... %}` and
  # `{# ... #}` delimiter pairs (live-verified vs 2.19.11: `copy: "{% if
  # true %}{{ some_dict }}{% endif %}"` and `copy: "{# c #}{{ some_dict }}"`
  # both print the identical argsplat warning block at the same Origin and
  # then resolve the WHOLE string as one template to the dict - the copy
  # succeeds). krikri warns identically (same once-per-task rule, same
  # text) but deliberately does NOT widen its whole-args resolution, which
  # only ever drove `{{ }}`, so such a value keeps resolving through the
  # free-form k=v path and the copy fails with real's own "src (or
  # content) is required" - the warning is the parity surface here.
  it "warns for a {% block %}-delimited string args" do
    success, output = run_play([
      "    - name: block delimiters",
      "      ansible.builtin.copy: \"{% if true %}{{ some_dict }}{% endif %}\"",
    ], dict_vars_for("block"))
    success.must_equal(false)
    warning_count(output).must_equal(1)
    warning_origin(output).not_nil!.must_equal({"10", "29"})
    output.includes?("src (or content) is required").must_equal(true)
  end

  it "warns for a {# comment #}-delimited string args" do
    success, output = run_play([
      "    - name: comment delimiters",
      "      ansible.builtin.copy: \"{# c #}{{ some_dict }}\"",
    ], dict_vars_for("comment"))
    success.must_equal(false)
    warning_count(output).must_equal(1)
    warning_origin(output).not_nil!.must_equal({"10", "29"})
  end

  it "does not warn for a when-false block-delimited string args task" do
    success, output = run_play([
      "    - name: skipped block args",
      "      ansible.builtin.copy: \"{% if true %}{{ some_dict }}{% endif %}\"",
      "      when: false",
    ], dict_vars_for("blockskip"))
    success.must_equal(true, output)
    warning_count(output).must_equal(0)
    output.includes?("skipping: [localhost]").must_equal(true)
  end

  it "warns once for a looped block-delimited string args task" do
    success, output = run_play([
      "    - name: looped block args",
      "      ansible.builtin.copy: \"{% if true %}{{ item }}{% endif %}\"",
      "      loop:",
      "        - {content: one}",
      "        - {content: two}",
    ])
    success.must_equal(false)
    warning_count(output).must_equal(1)
  end

  it "does not warn for a free-form module given a block-delimited string" do
    success, output = run_play([
      "    - name: free form block args",
      "      ansible.builtin.command: \"{% if true %}echo hi{% endif %}\"",
    ])
    # The literal command text fails in real too (free-form modules take
    # the string verbatim); only the WARNING count is the parity surface.
    warning_count(output).must_equal(0)
  end
end
