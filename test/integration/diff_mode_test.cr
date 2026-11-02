require "file_utils"
require "../minitest_helper"

# Runs the compiled binary, since the magic-var binding happens in the
# executor's vars context and --diff is a CLI flag, neither reachable
# from a unit spec.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(__DIR__, "..", "fixtures", "inventory-explicit-localhost.ini")

# Found benchmarking linux-system-roles.firewall (round 970345): its
# "Show diffs" task guards with `when: ansible_check_mode or
# ansible_diff_mode or ...`, which hard-failed ("'ansible_diff_mode' is
# undefined") where ansible-playbook just skips - ansible_check_mode
# was bound as a magic var, its --diff sibling was not.
describe "ansible_diff_mode magic var" do
  it "defaults to false on a plain run instead of being undefined" do
    playbook = File.tempname("diff-mode-default", ".yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: Show diffs
            ansible.builtin.debug:
              msg: DIFF_SHOULD_NOT_SHOW
            when: ansible_check_mode or ansible_diff_mode or extra_flag | d(false)
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)

    status.success?.must_equal(true)
    output.to_s.wont_include("'ansible_diff_mode' is undefined")
    output.to_s.wont_include("DIFF_SHOULD_NOT_SHOW")
    output.to_s.must_match(/skipped=1\b/)
  ensure
    File.delete(playbook) if playbook && File.exists?(playbook)
  end

  it "flips to true under --diff and lets the guarded task run" do
    playbook = File.tempname("diff-mode-on", ".yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: Show diffs
            ansible.builtin.debug:
              msg: DIFF_SHOULD_SHOW
            when: ansible_check_mode or ansible_diff_mode or extra_flag | d(false)
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["--diff", "-i", INVENTORY, playbook], output: output, error: output)

    status.success?.must_equal(true)
    output.to_s.must_include("DIFF_SHOULD_SHOW")
  ensure
    File.delete(playbook) if playbook && File.exists?(playbook)
  end

  # Issue #457 (live-verified vs ansible-core 2.19.11): the task-level
  # `diff:` keyword overrides the --diff flag for that task - `diff: true`
  # shows the file diff on a plain run, `diff: false` suppresses it under
  # --diff - for both the module's diff payload (via _ansible_diff) and
  # the callback's display.
  it "shows the copy diff on a plain run with task-level diff: true" do
    playbook = File.tempname("task-diff-on", ".yml")
    dest = PluginSpecHelper.tmp_path("task-diff-on.txt")
    FileUtils.mkdir_p(File.dirname(dest))
    File.write(playbook, <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: Diff without --diff
            ansible.builtin.copy:
              content: "hello\\n"
              dest: #{dest}
            diff: true
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-c", "local", "-i", INVENTORY, playbook], output: output, error: output)

    status.success?.must_equal(true)
    output.to_s.must_include("--- before")
    output.to_s.must_include("+++ after: #{dest}")
    output.to_s.must_include("+hello")
  ensure
    File.delete(playbook) if playbook && File.exists?(playbook)
    File.delete(dest) if dest && File.exists?(dest)
  end

  it "suppresses the copy diff under --diff with task-level diff: false" do
    playbook = File.tempname("task-diff-off", ".yml")
    dest = PluginSpecHelper.tmp_path("task-diff-off.txt")
    FileUtils.mkdir_p(File.dirname(dest))
    File.write(playbook, <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: No diff despite --diff
            ansible.builtin.copy:
              content: "hello\\n"
              dest: #{dest}
            diff: false
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["--diff", "-c", "local", "-i", INVENTORY, playbook], output: output, error: output)

    status.success?.must_equal(true)
    output.to_s.must_include("changed: [localhost]")
    output.to_s.wont_include("--- before")
  ensure
    File.delete(playbook) if playbook && File.exists?(playbook)
    File.delete(dest) if dest && File.exists?(dest)
  end
end

# martin-micimo.haproxy's template/copy tasks all carry
# `diff: "{{ haproxy_show_template_diffs }}"` (defaults to true): a
# TEMPLATED diff: keyword. Parse-time it is not a literal boolean, so the
# parsed task left diff_mode nil and every display site fell back to the
# CLI --diff flag - the role's template tasks printed no diff block on a
# plain run where ansible prints one (issue #566). The keyword now
# resolves against live vars at execution time, exactly like the
# deferred check_mode: handling above.
describe "templated diff: keyword" do
  it "shows the template diff on a plain run when the templated value is true" do
    playbook = File.tempname("task-diff-tpl-on", ".yml")
    src = PluginSpecHelper.tmp_path("task-diff-tpl.j2")
    dest = PluginSpecHelper.tmp_path("task-diff-tpl-out.txt")
    FileUtils.mkdir_p(File.dirname(src))
    FileUtils.mkdir_p(File.dirname(dest))
    File.write(src, "hello from template\n")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        vars:
          show_template_diffs: true
        tasks:
          - name: Templated diff without --diff
            ansible.builtin.template:
              src: #{src}
              dest: #{dest}
            diff: "{{ show_template_diffs }}"
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-c", "local", "-i", INVENTORY, playbook], output: output, error: output)

    status.success?.must_equal(true)
    output.to_s.must_include("--- before")
    output.to_s.must_include("+hello from template")
    output.to_s.must_match(/changed=1\b/)
  ensure
    File.delete(playbook) if playbook && File.exists?(playbook)
    File.delete(src) if src && File.exists?(src)
    File.delete(dest) if dest && File.exists?(dest)
  end

  it "suppresses the diff under --diff when the templated value is false" do
    playbook = File.tempname("task-diff-tpl-off", ".yml")
    src = PluginSpecHelper.tmp_path("task-diff-tpl-off.j2")
    dest = PluginSpecHelper.tmp_path("task-diff-tpl-off-out.txt")
    FileUtils.mkdir_p(File.dirname(src))
    FileUtils.mkdir_p(File.dirname(dest))
    File.write(src, "hello from template\n")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        vars:
          show_template_diffs: false
        tasks:
          - name: Templated diff false under --diff
            ansible.builtin.template:
              src: #{src}
              dest: #{dest}
            diff: "{{ show_template_diffs }}"
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["--diff", "-c", "local", "-i", INVENTORY, playbook], output: output, error: output)

    status.success?.must_equal(true)
    output.to_s.must_include("changed: [localhost]")
    output.to_s.wont_include("--- before")
  ensure
    File.delete(playbook) if playbook && File.exists?(playbook)
    File.delete(src) if src && File.exists?(src)
    File.delete(dest) if dest && File.exists?(dest)
  end
end

# Issue #735: ansible post-validates the diff:/check_mode: keywords with
# its strict boolean() - a literal it can't convert (`diff: banana`) or a
# template that renders to one fails the task with "Error processing
# keyword 'diff': The value 'banana' could not be converted to 'bool'."
# at keyword-validation time, and `diff: 1` is a valid boolean spelling
# the old parse silently dropped.
describe "diff:/check_mode: keyword post-validation" do
  it "fails a task with a non-boolean diff: literal instead of running it" do
    playbook = File.tempname("diff-invalid", ".yml")
    dest = PluginSpecHelper.tmp_path("diff-invalid-out.txt")
    FileUtils.mkdir_p(File.dirname(dest))
    File.write(playbook, <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: Invalid diff keyword
            ansible.builtin.copy:
              content: "hello\\n"
              dest: #{dest}
            diff: banana
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-c", "local", "-i", INVENTORY, playbook], output: output, error: output)

    output_text = output.to_s
    status.success?.must_equal(false, output_text)
    output_text.includes?("Error processing keyword 'diff': The value 'banana' could not be converted to 'bool'.").must_equal(true, output_text)
    File.exists?(dest).must_equal(false)
  ensure
    File.delete(playbook) if playbook && File.exists?(playbook)
    File.delete(dest) if dest && File.exists?(dest)
  end

  it "fails a task with a non-boolean check_mode: literal instead of running it" do
    playbook = File.tempname("check-mode-invalid", ".yml")
    dest = PluginSpecHelper.tmp_path("check-mode-invalid-out.txt")
    FileUtils.mkdir_p(File.dirname(dest))
    File.write(playbook, <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: Invalid check_mode keyword
            ansible.builtin.copy:
              content: "hello\\n"
              dest: #{dest}
            check_mode: banana
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-c", "local", "-i", INVENTORY, playbook], output: output, error: output)

    output_text = output.to_s
    status.success?.must_equal(false, output_text)
    output_text.includes?("Error processing keyword 'check_mode': The value 'banana' could not be converted to 'bool'.").must_equal(true, output_text)
    File.exists?(dest).must_equal(false)
  ensure
    File.delete(playbook) if playbook && File.exists?(playbook)
    File.delete(dest) if dest && File.exists?(dest)
  end

  it "honors diff: 1 as a boolean spelling on a plain run" do
    playbook = File.tempname("diff-numeric", ".yml")
    src = PluginSpecHelper.tmp_path("diff-numeric.j2")
    dest = PluginSpecHelper.tmp_path("diff-numeric-out.txt")
    FileUtils.mkdir_p(File.dirname(src))
    FileUtils.mkdir_p(File.dirname(dest))
    File.write(src, "hello from template\n")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: Numeric diff spelling
            ansible.builtin.template:
              src: #{src}
              dest: #{dest}
            diff: 1
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-c", "local", "-i", INVENTORY, playbook], output: output, error: output)

    status.success?.must_equal(true, output.to_s)
    output.to_s.must_include("--- before")
    output.to_s.must_include("+hello from template")
  ensure
    File.delete(playbook) if playbook && File.exists?(playbook)
    File.delete(src) if src && File.exists?(src)
    File.delete(dest) if dest && File.exists?(dest)
  end

  it "fails a templated diff: that renders to a non-boolean value" do
    playbook = File.tempname("diff-tpl-invalid", ".yml")
    dest = PluginSpecHelper.tmp_path("diff-tpl-invalid-out.txt")
    FileUtils.mkdir_p(File.dirname(dest))
    File.write(playbook, <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        vars:
          diff_setting: banana
        tasks:
          - name: Templated invalid diff keyword
            ansible.builtin.copy:
              content: "hello\\n"
              dest: #{dest}
            diff: "{{ diff_setting }}"
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-c", "local", "-i", INVENTORY, playbook], output: output, error: output)

    output_text = output.to_s
    status.success?.must_equal(false, output_text)
    output_text.includes?("Error processing keyword 'diff': The value 'banana' could not be converted to 'bool'.").must_equal(true, output_text)
    File.exists?(dest).must_equal(false)
  ensure
    File.delete(playbook) if playbook && File.exists?(playbook)
    File.delete(dest) if dest && File.exists?(dest)
  end
end
