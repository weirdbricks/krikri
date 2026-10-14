require "../minitest_helper"
require "file_utils"

# The `Origin:` / source-excerpt blocks ansible-core 2.19.11 prints for
# task error kinds this engine used to render bare (issue #12, round
# logs___1791776891 / logs___1791778831 / logs___1791780432) - every
# shape below live-verified against local ansible-playbook 2.19.11:
#
# - a removed `include:` action refusal: STDERR block with the task's
#   own Origin (the `include:` KEY column) + excerpt + caret, exit 1,
#   nothing on stdout;
# - an undefined loop SOURCE (`loop: "{{ undefined_var }}"`): the cause
#   stanza of the "Task failed." chain carries the loop keyword's VALUE
#   token Origin + excerpt + caret;
# - a first_found lookup exhaustion (with_first_found: keyword on a
#   module task / include_tasks: / include_vars: / handler): the
#   bodyless [ERROR] block (`Origin: <unknown>` + bare `invoke_lookup()`
#   frame line) with a msg-only fatal - never the "Task failed:" wrapper;
# - the same lookup failing INSIDE a templated loop source
#   (`loop: "{{ query('first_found', ...) }}"`): same bare block but the
#   Origin pins the loop VALUE token, and without the "Provide a
#   list..." tail the type-refusal shape carries;
# - a missing meta/main.yml ROLE DEPENDENCY: the search list is
#   `ansible.legacy:`-prefixed with the declaring role's parent appended,
#   and the Origin points at the dependency entry inside the declaring
#   role's own meta/main.yml.

private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "test", "fixtures", "inventory-explicit-localhost.ini")

describe "task error Origin blocks (issue #12)" do
  # Runs the binary with stdout/stderr captured separately. Returns
  # {exit code, stdout, stderr}.
  private def run_playbook(path : String) : {Int32, String, String}
    stdout = IO::Memory.new
    stderr = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, path], output: stdout, error: stderr, input: IO::Memory.new)
    {status.exit_code, stdout.to_s, stderr.to_s}
  end

  # Writes a playbook plus optional same-directory sidecars (relative
  # paths, e.g. "roles/x/tasks/main.yml") and runs it. Returns
  # {exit code, stdout, stderr, playbook path}.
  private def run_play_file(yaml : String, sidecars : Hash(String, String) = {} of String => String) : {Int32, String, String, String}
    path = PluginSpecHelper.tmp_path("origin-block-#{Random::Secure.hex(4)}.yml")
    File.write(path, yaml)
    dir = File.dirname(path)
    sidecars.each do |name, content|
      sidecar = File.join(dir, name)
      FileUtils.mkdir_p(File.dirname(sidecar))
      File.write(sidecar, content)
    end
    code, out, err = run_playbook(path)
    {code, out, err, File.expand_path(path)}
  ensure
    if path && File.exists?(path)
      dir = File.dirname(path)
      sidecars.try &.each do |name, _|
        file = File.join(dir, name)
        File.delete(file) if File.exists?(file)
      end
      FileUtils.rm_r(File.join(dir, "roles")) if Dir.exists?(File.join(dir, "roles"))
      File.delete(path)
    end
  end

  it "prints the removed include: action's Origin block on stderr, exit 1" do
    code, out, err, path = run_play_file([
      "---",
      "- hosts: localhost",
      "  gather_facts: false",
      "  connection: local",
      "  tasks:",
      "    - include: sidecar.yml",
    ].join("\n") + "\n")
    code.must_equal(1)
    out.strip.empty?.must_equal(true)
    err.must_include "[ERROR]: The 'ansible.builtin.include' action plugin has been removed. " \
                     "Use include_tasks or import_tasks instead. This feature was removed from " \
                     "ansible-core in a release after 2023-05-16."
    # The Origin points at the `include:` KEY itself (column 7), with the
    # two preceding source lines + caret, exactly like real's block.
    err.must_include "Origin: #{path}:6:7\n"
    err.must_include "4   connection: local\n5   tasks:\n6     - include: sidecar.yml\n        ^ column 7\n"
  end

  it "pins the loop value token as the caused-by Origin of an undefined loop source" do
    code, out, _err, path = run_play_file([
      "---",
      "- hosts: localhost",
      "  gather_facts: false",
      "  connection: local",
      "  tasks:",
      "    - ansible.builtin.debug:",
      "        msg: \"{{ item }}\"",
      "      loop: \"{{ wordpress_sites }}\"",
    ].join("\n") + "\n")
    code.must_equal(2)
    out.must_include "[ERROR]: Task failed: 'wordpress_sites' is undefined"
    out.must_include "fatal: [localhost]: FAILED! => {\"msg\": \"Task failed: 'wordpress_sites' is undefined\"}"
    # The caused-by stanza's Origin is the loop keyword's VALUE token
    # (column 13), with the usual excerpt + caret - previously the cause
    # stanza printed with no Origin block at all.
    out.must_include "Origin: #{path}:8:13\n"
    out.must_include "6     - ansible.builtin.debug:\n7         msg: \"{{ item }}\"\n8       loop: \"{{ wordpress_sites }}\"\n              ^ column 13\n"
  end

  it "pins the first list element's value token as the caused-by Origin of a block-sequence with_items undefined source" do
    # `with_items:` written as a BLOCK SEQUENCE (item on the next line)
    # puts no value token on the key line itself - real 2.19 reports the
    # FIRST list element's opening char as the Origin, not the end of the
    # `with_items:` line (issue #88).
    code, out, _err, path = run_play_file([
      "---",
      "- hosts: localhost",
      "  gather_facts: false",
      "  connection: local",
      "  tasks:",
      "    - ansible.builtin.debug:",
      "        msg: \"{{ item }}\"",
      "      with_items:",
      "        - \"{{ zones_id }}\"",
    ].join("\n") + "\n")
    code.must_equal(2)
    out.must_include "[ERROR]: Task failed: 'zones_id' is undefined"
    # The caused-by stanza's Origin is the first element's value token
    # (line 9, column 11 = just past `        - `), with the excerpt and
    # caret under that token.
    out.must_include "Origin: #{path}:9:11\n"
    out.must_include "7         msg: \"{{ item }}\"\n8       with_items:\n9         - \"{{ zones_id }}\"\n            ^ column 11\n"
  end

  it "prints the bodyless lookup-failure block for a with_first_found: module task" do
    code, out, _err, _path = run_play_file([
      "---",
      "- hosts: localhost",
      "  gather_facts: false",
      "  connection: local",
      "  tasks:",
      "    - ansible.builtin.debug:",
      "        msg: found",
      "      with_first_found:",
      "        - files:",
      "            - definitely-not-here-12.yml",
      "          paths:",
      "            - /tmp",
    ].join("\n") + "\n")
    code.must_equal(2)
    out.must_include "[ERROR]: The lookup plugin 'first_found' failed: No file was found when using first_found.\n" \
                     "Origin: <unknown>\n\ninvoke_lookup()\n\n"
    out.must_include "fatal: [localhost]: FAILED! => {\"msg\": \"The lookup plugin 'first_found' failed: No file was found when using first_found.\"}"
    out.wont_include "Task failed:"
  end

  it "prints the same bodyless block for a with_first_found: include_tasks:" do
    code, out, _err, _path = run_play_file([
      "---",
      "- hosts: localhost",
      "  gather_facts: false",
      "  connection: local",
      "  tasks:",
      "    - ansible.builtin.include_tasks: \"{{ item }}\"",
      "      with_first_found:",
      "        - files:",
      "            - definitely-not-here-12.yml",
      "          paths:",
      "            - /tmp",
    ].join("\n") + "\n")
    code.must_equal(2)
    out.must_include "[ERROR]: The lookup plugin 'first_found' failed: No file was found when using first_found.\n" \
                     "Origin: <unknown>\n\ninvoke_lookup()\n\n"
    out.must_include "fatal: [localhost]: FAILED! => {\"msg\": \"The lookup plugin 'first_found' failed: No file was found when using first_found.\"}"
  end

  it "prints the same bodyless block for a with_first_found: include_vars:" do
    code, out, _err, _path = run_play_file([
      "---",
      "- hosts: localhost",
      "  gather_facts: false",
      "  connection: local",
      "  tasks:",
      "    - ansible.builtin.include_vars: \"{{ item }}\"",
      "      with_first_found:",
      "        - files:",
      "            - definitely-not-here-12.yml",
      "          paths:",
      "            - /tmp",
    ].join("\n") + "\n")
    code.must_equal(2)
    out.must_include "[ERROR]: The lookup plugin 'first_found' failed: No file was found when using first_found.\n" \
                     "Origin: <unknown>\n\ninvoke_lookup()\n\n"
    out.must_include "fatal: [localhost]: FAILED! => {\"msg\": \"The lookup plugin 'first_found' failed: No file was found when using first_found.\"}"
  end

  it "fails a with_first_found: handler with the same bodyless block" do
    code, out, _err, _path = run_play_file([
      "---",
      "- hosts: localhost",
      "  gather_facts: false",
      "  connection: local",
      "  tasks:",
      "    - ansible.builtin.debug: msg=hi",
      "      changed_when: true",
      "      notify: h1",
      "  handlers:",
      "    - name: h1",
      "      ansible.builtin.debug: msg=handled",
      "      with_first_found:",
      "        - files:",
      "            - definitely-not-here-12.yml",
      "          paths:",
      "            - /tmp",
    ].join("\n") + "\n")
    code.must_equal(2)
    out.must_include "[ERROR]: The lookup plugin 'first_found' failed: No file was found when using first_found.\n" \
                     "Origin: <unknown>\n\ninvoke_lookup()\n\n"
    out.must_include "fatal: [localhost]: FAILED! => {\"msg\": \"The lookup plugin 'first_found' failed: No file was found when using first_found.\"}"
    out.wont_include "\"msg\": \"handled\""
  end

  it "pins the loop value token Origin for a first_found failure inside a templated loop" do
    code, out, _err, path = run_play_file([
      "---",
      "- hosts: localhost",
      "  gather_facts: false",
      "  connection: local",
      "  tasks:",
      "    - ansible.builtin.debug:",
      "        msg: found",
      "      loop: \"{{ query('first_found', 'definitely-not-here-12.yml') }}\"",
    ].join("\n") + "\n")
    code.must_equal(2)
    out.must_include "[ERROR]: The lookup plugin 'first_found' failed: No file was found when using first_found.\n"
    # The templated-loop invocation site IS pinned - the loop VALUE token.
    out.must_include "Origin: #{path}:8:13\n"
    out.must_include "6     - ansible.builtin.debug:\n7         msg: found\n8       loop: \"{{ query('first_found', 'definitely-not-here-12.yml') }}\"\n              ^ column 13\n"
    # The type-refusal tail belongs to LoopTypeError only.
    out.wont_include "Provide a list of items/templates"
    out.must_include "fatal: [localhost]: FAILED! => {\"msg\": \"The lookup plugin 'first_found' failed: No file was found when using first_found.\"}"
  end

  it "reports a missing meta/main.yml dependency with the ansible.legacy: search list and the meta Origin" do
    meta = [
      "galaxy_info:",
      "  author: me",
      "  license: MIT",
      "dependencies:",
      "  - role: missing_dep_xyz",
    ].join("\n") + "\n"
    code, _out, err, path = run_play_file([
      "---",
      "- hosts: localhost",
      "  gather_facts: false",
      "  connection: local",
      "  roles:",
      "    - r2",
    ].join("\n") + "\n", sidecars: {
      "roles/r2/meta/main.yml"  => meta,
      "roles/r2/tasks/main.yml" => "- ansible.builtin.debug:\n    msg: hi\n",
    })
    code.must_equal(1)
    # The dependency context's search list is ansible.legacy:-prefixed and
    # appends the declaring role's parent (here <tmp>/roles) before the
    # playbook dir - unlike the play-level form, which carries no prefix.
    err.must_include "the role 'missing_dep_xyz' was not found in ansible.legacy:"
    err.must_include ":#{File.join(File.dirname(path), "roles")}:#{File.dirname(path)}\n"
    # The Origin points at the dependency entry inside the DECLARING
    # role's own meta/main.yml (line 5, the `role:` key column 5).
    meta_path = File.join(File.dirname(path), "roles", "r2", "meta", "main.yml")
    err.must_include "Origin: #{meta_path}:5:5\n"
    err.must_include "3   license: MIT\n4 dependencies:\n5   - role: missing_dep_xyz\n      ^ column 5\n"
  end

  it "reports a missing bare-string dependency at the entry's own column" do
    meta = [
      "galaxy_info:",
      "  author: me",
      "  license: MIT",
      "dependencies:",
      "  - missing_dep_bare",
    ].join("\n") + "\n"
    code, _out, err, path = run_play_file([
      "---",
      "- hosts: localhost",
      "  gather_facts: false",
      "  connection: local",
      "  roles:",
      "    - r2",
    ].join("\n") + "\n", sidecars: {
      "roles/r2/meta/main.yml"  => meta,
      "roles/r2/tasks/main.yml" => "- ansible.builtin.debug:\n    msg: hi\n",
    })
    code.must_equal(1)
    err.must_include "the role 'missing_dep_bare' was not found in ansible.legacy:"
    meta_path = File.join(File.dirname(path), "roles", "r2", "meta", "main.yml")
    err.must_include "Origin: #{meta_path}:5:5\n"
    err.must_include "5   - missing_dep_bare\n      ^ column 5\n"
  end
end
