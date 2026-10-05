require "../minitest_helper"
require "file_utils"

# Regression specs for round 981063 (linux-system-roles.postgresql,
# previously clean): a template-valued var loaded by include_vars: was
# treated as LITERAL TEXT when referenced from a consumer task's
# task-level `vars:` entry - `{{ __pk | list }}` produced the template
# source's own characters (`["{", "{", " ", "[", ...]`) instead of
# rendering the template first (ansible-playbook: `["pg-server"]`).
#
# Root cause: the task-level `vars:` bare-mustache render
# (evaluate_bare_mustache_preserving_type) evaluated the expression
# through krikri-jinja's EAGER evaluate_expression, which converts the
# whole vars context with from_json_any - no recursive re-templating -
# so an author vars value whose stored text is itself Jinja (a vars
# file loaded by include_vars:) reached the engine verbatim. The same
# eager call had replaced the lazy, resolver-backed evaluation on the
# notify:-handler-name path too. Both sites now go through
# JinjaRenderer.evaluate_structured, the resolver-backed (JinjaVar-
# Resolver) evaluation every other path uses, so include_vars data is
# templated lazily like any author vars source.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(__DIR__, "..", "fixtures", "inventory-explicit-localhost.ini")

# Runs the binary on the given consumer/producer task lines and returns
# the rendered debug msg line (the JSON-ish `  [...]` display line).
# Heredoc convention: the task dash sits at the heredoc's own strip
# level (the closing YAML marker's indentation), so every non-empty
# line gets the play's 4-space task level prefixed here.
private def run_repro(tasks : String)
  src_dir = File.tempname("include-vars-templated")
  Dir.mkdir_p(File.join(src_dir, "iv"))
  File.write(File.join(src_dir, "iv", "Debian.yml"), <<-YAML)
    __pk: >-
      {{ ['@pg:' + (__ver | string) +
           '/server'] if (__ver | string) != '13' else
           ['pg-server'] }}
    YAML

  playbook = File.join(src_dir, "pb.yml")
  File.write(playbook, "- hosts: all\n  gather_facts: false\n  tasks:\n" +
                       tasks.each_line.reject(&.empty?).map { |line| "    " + line }.join("\n") + "\n")

  output = IO::Memory.new
  status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output, chdir: src_dir)
  # The debug msg now displays as Ansible 2.19.11 does (live-captured):
  # a whole-span list value is a NATIVE container, pretty-printed as
  # `    "msg": [` + the elements - never the old JSON-string dump
  # `    "msg": "[\"pg-server\"]"`.
  {status, output.to_s}
ensure
  FileUtils.rm_rf(src_dir) if src_dir
end

# The exact linux-system-roles.postgresql shape: a looped include_vars:
# gated by `when:` with a task-level `vars:` path template, consumed by
# a later task's own `vars:` entry whose expression ternaries on the
# loaded value.
private REPRO_TASKS = <<-YAML
  - set_fact:
      __ver: "13"
  - set_fact:
      __ost: false
  - include_vars: "{{ __vars_file }}"
    loop:
      - "Debian.yml"
    vars:
      __vars_file: "{{ playbook_dir }}/iv/{{ item }}"
    when: __vars_file is file
  - debug: msg="{{ __actual }}"
    vars:
      __actual: "{{ (__ost | d(false)) | ternary(__pk | reject('match', '^@'), __pk) | list }}"
  YAML

# Same consumption shape, but the include_vars: loop items themselves
# are FACT templates (set_fact-produced names), exercising the looped
# path's per-iteration vars re-render feeding the load.
private FACT_TEMPLATE_LOOP_TASKS = <<-YAML
  - set_fact:
      __ver: "13"
  - set_fact:
      __ost: false
  - set_fact:
      __file: "Debian.yml"
  - include_vars: "{{ __vars_file }}"
    loop:
      - "{{ __file }}"
    vars:
      __vars_file: "{{ playbook_dir }}/iv/{{ item }}"
    when: __vars_file is file
  - debug: msg="{{ __actual }}"
    vars:
      __actual: "{{ (__ost | d(false)) | ternary(__pk | reject('match', '^@'), __pk) | list }}"
  YAML

# Plain (non-looped) include_vars: consumed from a task-level `vars:`
# entry - the eager-evaluation bug is not loop-specific.
private PLAIN_TASKS = <<-YAML
  - set_fact:
      __ver: "13"
  - set_fact:
      __ost: false
  - include_vars: "{{ playbook_dir }}/iv/Debian.yml"
  - debug: msg="{{ __actual }}"
    vars:
      __actual: "{{ (__ost | d(false)) | ternary(__pk | reject('match', '^@'), __pk) | list }}"
  YAML

describe "include_vars-loaded template values consumed from task-level vars:" do
  it "renders the template, not its literal text (looped include_vars, round 981063 repro)" do
    # ansible-playbook renders the loaded author template lazily:
    # a native one-element list, pretty-printed. The regression rendered
    # the template SOURCE text and split it into single characters with
    # `| list`.
    status, output = run_repro(REPRO_TASKS)
    status.success?.must_equal(true)
    output.must_include("\"msg\": [")
    output.must_include("\"pg-server\"")
    output.wont_include("{{")
  end

  it "renders the template when the include_vars loop items are fact templates" do
    status, output = run_repro(FACT_TEMPLATE_LOOP_TASKS)
    status.success?.must_equal(true)
    output.must_include("\"msg\": [")
    output.must_include("\"pg-server\"")
    output.wont_include("{{")
  end

  it "renders the template for a plain (non-looped) include_vars too" do
    status, output = run_repro(PLAIN_TASKS)
    status.success?.must_equal(true)
    output.must_include("\"msg\": [")
    output.must_include("\"pg-server\"")
    output.wont_include("{{")
  end
end
