require "../minitest_helper"

# ansible-core 2.19.11's console warning for a task whose module args
# are a SINGLE all-template string (`copy: "{{ some_dict }}"`),
# live-verified against 2.19.11 - every expectation below is Ansible's own
# output with tmp paths masked.
#
# Ansible's trigger (the Ansible module post_validate +
# the Ansible module TaskArgsFinalizer) is NOT "renders to a dict":
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
# The Origin points at the first character of the scalar itself: the
# opening quote for a quoted value (column 29 for a 6-space-indented
# `ansible.builtin.copy: "{{ d }}"`, single or double quotes alike).
# When nothing follows the module key's colon, the value starts on a
# line of its own and the Origin reports THAT line, again at the
# value's first non-space character - a role task like
# `  htpasswd:` + 4-space-indented `    "{{ item }}"` reports Origin
# 5:5 (live-verified against 2.19.11, issue #292).

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

# Like run_play, but with a `handlers:` section whose handler is notified
# by the play's only task, and with stderr kept separate: the argsplat
# warning is the one thing a handler path can print that no stdout line
# would reveal, and the parity claim under test is specifically about
# Ansible's stderr.
private def run_play_with_handler(tasks : Array(String), handler_lines : Array(String)) : {Bool, String, String}
  playbook = File.tempname("argsplat-warning-handler", ".yml")
  body = PLAY_HEADER.dup
  body.concat(dict_vars_for("handlerdict"))
  body << "  tasks:"
  body.concat(tasks)
  body << "  handlers:"
  body.concat(handler_lines)
  File.write(playbook, body.join("\n") + "\n")
  stdout = IO::Memory.new
  stderr = IO::Memory.new
  status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: stdout, error: stderr, input: IO::Memory.new)
  {status.success?, stdout.to_s, stderr.to_s}
ensure
  File.delete(playbook) if playbook && File.exists?(playbook)
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

  it "warns with an Origin on the block-style value line when nothing follows the module key" do
    success, output = run_play([
      "    - name: block style",
      "      ansible.builtin.copy:",
      "        \"{{ some_dict }}\"",
    ], dict_vars_for("blockline"))
    success.must_equal(true, output)
    warning_count(output).must_equal(1)

    # The value line is line 11 here (task name 9, module key 10) and
    # the quote is its first non-space character: ansible's caret is
    # under the quote, not the `"`-after-colon column of the key line.
    origin = warning_origin(output)
    origin.not_nil!.must_equal({"11", "9"})
    output.includes?("^ column 9").must_equal(true)
    output.includes?("changed: [localhost]").must_equal(true)
  end

  it "skips a blank line when locating the block-style value line for an Origin" do
    success, output = run_play([
      "    - name: blank between",
      "      ansible.builtin.copy:",
      "",
      "        \"{{ some_dict }}\"",
    ], dict_vars_for("blockblank"))
    success.must_equal(true, output)
    warning_count(output).must_equal(1)

    origin = warning_origin(output)
    origin.not_nil!.must_equal({"12", "9"})
    output.includes?("^ column 9").must_equal(true)
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

  # Real ansible-core 2.19.11 prints no argsplat warning for a templated
  # string whose content is pure key=value (its parse_kv split leaves no
  # free-form `_raw_params` text, so no bare string layer reaches the
  # TaskArgsFinalizer): `set_fact: "{{ x }}={{ 'v' }}"` is silent, while
  # `debug: "{{ d }}"` warns.
  it "does not warn for a templated string made only of key=value pairs" do
    success, output = run_play([
      "    - name: kv templated args",
      "      ansible.builtin.set_fact: \"{{ kv_key }}={{ 'kv value' }}\"",
    ], ["  vars:", "    kv_key: kv_fact"])
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

  # Ansible's is_possibly_all_template also accepts the `{% ... %}` and
  # `{# ... #}` delimiter pairs (live-verified vs 2.19.11: `copy: "{% if
  # true %}{{ some_dict }}{% endif %}"` and `copy: "{# c #}{{ some_dict }}"`
  # both print the identical argsplat warning block at the same Origin and
  # then resolve the WHOLE string as one template to the dict - the copy
  # succeeds). krikri warns identically (same once-per-task rule, same
  # text) but deliberately does NOT widen its whole-args resolution, which
  # only ever drove `{{ }}`, so such a value keeps resolving through the
  # free-form k=v path and the copy fails with Ansible's own "src (or
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
    _, output = run_play([
      "    - name: free form block args",
      "      ansible.builtin.command: \"{% if true %}echo hi{% endif %}\"",
    ])
    # The literal command text fails in real too (free-form modules take
    # the string verbatim); only the WARNING count is the parity surface.
    warning_count(output).must_equal(0)
  end

  # A handler's args are finalized like a task's, so Ansible warns there too -
  # the handler path built its params without the same wrapping the task
  # path does, so the warning never fired for a notified handler.
  it "warns once for a notified handler with templated args" do
    success, stdout, stderr = run_play_with_handler([
      "    - name: notify handler",
      "      ansible.builtin.command: /bin/true",
      "      notify: templated args handler",
    ], [
      "    - name: templated args handler",
      "      ansible.builtin.copy: \"{{ some_dict }}\"",
    ])
    success.must_equal(true, stdout + stderr)
    warning_count(stderr).must_equal(1)
    warning_count(stdout).must_equal(0)
    stdout.includes?("RUNNING HANDLER").must_equal(true)
  end

  # pgvillage.linux's own task (issue #308): the name's source line ends
  # in a YAML comment (` # noqa: args[module]`), which YAML already
  # stripped from the parsed name. The Origin search compared the raw
  # line text (comment included) against the parsed name, never matched,
  # and its task-start fallback reported the name's line where real
  # ansible reports the module args line, at the opening quote.
  it "points the Origin at the module line when the name line carries a trailing comment" do
    success, output = run_play([
      "    - name: Add repository # noqa: args[module]",
      "      ansible.builtin.copy: \"{{ some_dict }}\"",
    ], dict_vars_for("namecomment"))
    success.must_equal(true, output)
    warning_count(output).must_equal(1)
    # Line 10 is the module key line (the commented name is line 9); the
    # column is the opening quote, identical to the un-commented
    # `templated args` shape above.
    warning_origin(output).not_nil!.must_equal({"10", "29"})
    output.includes?("^ column 29").must_equal(true)
    output.includes?("10       ansible.builtin.copy: \"{{ some_dict }}\"").must_equal(true)
  end

  it "points the Origin at the module line for a quoted name followed by a comment" do
    success, output = run_play([
      "    - name: \"Add repository\" # noqa: args[module]",
      "      ansible.builtin.copy: \"{{ some_dict }}\"",
    ], dict_vars_for("quotedcomment"))
    success.must_equal(true, output)
    warning_count(output).must_equal(1)
    warning_origin(output).not_nil!.must_equal({"10", "29"})
    output.includes?("^ column 29").must_equal(true)
  end

  # `#` only opens a comment when whitespace precedes it - `foo#bar` is
  # name content and keeps matching; a less careful strip would cut it
  # and the Origin would fall back to the task-start position again.
  it "keeps matching a name whose only # has no preceding whitespace" do
    success, output = run_play([
      "    - name: reach foo#bar",
      "      ansible.builtin.copy: \"{{ some_dict }}\"",
    ], dict_vars_for("hashmidname"))
    success.must_equal(true, output)
    warning_count(output).must_equal(1)
    warning_origin(output).not_nil!.must_equal({"10", "29"})
  end
end
