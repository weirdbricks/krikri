require "../minitest_helper"
require "file_utils"

# The `[WARNING]: Jinja constant strings should not contain embedded
# templates.` blocks behind a task param whose quoted lookup argument
# carries its own `{{ }}` span (issue #259, fastlorenzo.redelk_client's
# `authorized_key: key: "{{ lookup('file', '{{ path }}/{{ user }}_id_rsa.pub')
# }}"`), byte-compared against ansible-core 2.19.11:
#
# - the block lands on STDERR only, after the message line in real's
#   format_event shape: Origin at the param's VALUE position (first
#   character after `key: `, quote included), the usual 2-context-line
#   excerpt with a caret under that position, a blank line, then the
#   help text, then a trailing blank line;
# - dedup is per distinct Origin per run (the message and help text are
#   constants, so the Origin is the only variable part of real's
#   formatted [WARNING] block, which is what Display._deduplicate keys
#   on): two tasks with the pattern at different lines warn separately,
#   a looped task's per-item re-render of the SAME line warns once.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "test", "fixtures", "inventory-explicit-localhost.ini")

private WARNING_LINE = "[WARNING]: Jinja constant strings should not contain embedded templates. This feature will be disabled by default in ansible-core 2.23."
private HELP_LINE    = "Use inline expressions, for example: `msg: \"{{ lookup('env', '{{ a_var }}') }}\"` becomes `msg: \"{{ lookup('env', a_var) }}\"`"

describe "jinja constant embedded-template warning blocks" do
  it "warns at the authorized_key key param's value position (issue #259)" do
    src_dir = File.tempname("jinja-const-warn-ak")
    Dir.mkdir_p(File.join(src_dir, "keys"))
    File.write(File.join(src_dir, "keys", "root_id_rsa.pub"),
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAItestkeycomment259")
    File.write(File.join(src_dir, "pb.yml"), <<-YAML)
      ---
      - hosts: localhost
        connection: local
        gather_facts: false
        vars:
          redelk_user: root
          ssh_keys_path: #{src_dir}/keys
        tasks:
          - authorized_key:
              user: "{{ redelk_user }}"
              key: "{{ lookup('file', '{{ ssh_keys_path }}/{{ redelk_user }}_id_rsa.pub') }}"
      YAML

    stdout = IO::Memory.new
    stderr = IO::Memory.new
    Process.run(BINARY, ["-i", INVENTORY, "pb.yml", "--check"], output: stdout, error: stderr, chdir: src_dir)

    lines = File.read_lines(File.join(src_dir, "pb.yml"))
    pb_path = File.expand_path(File.join(src_dir, "pb.yml"))
    # The param's value starts at the `"` right after `key: ` (column 14
    # on the 8-space-indent line); the caret sits under it via the shared
    # Origin-block rules (2 context lines, right-aligned numbers).
    expected = "#{WARNING_LINE}\n" \
               "Origin: #{pb_path}:11:14\n\n" \
               " 9 #{lines[8]}\n" \
               "10 #{lines[9]}\n" \
               "11 #{lines[10]}\n" \
               "#{" " * 16}^ column 14\n\n" \
               "#{HELP_LINE}\n\n"
    stderr.to_s.must_include(expected)
    # STDERR-only: the warning never touches the task output stream.
    stdout.to_s.wont_include("Jinja constant strings")
  ensure
    FileUtils.rm_rf(src_dir) if src_dir
  end

  it "warns once per distinct origin, not per render" do
    src_dir = File.tempname("jinja-const-warn-dedup")
    Dir.mkdir_p(File.join(src_dir, "keys"))
    File.write(File.join(src_dir, "keys", "redelk_id_rsa.pub"), "KEY1")
    File.write(File.join(src_dir, "pb.yml"), <<-YAML)
      ---
      - hosts: localhost
        connection: local
        gather_facts: false
        vars:
          redelk_user: redelk
          ssh_keys_path: #{src_dir}/keys
        tasks:
          - ansible.builtin.debug:
              msg: "{{ lookup('file', '{{ ssh_keys_path }}/{{ redelk_user }}_id_rsa.pub') }}"
          - ansible.builtin.debug:
              msg: "{{ lookup('file', '{{ ssh_keys_path }}/{{ redelk_user }}_id_rsa.pub') }}"
          - ansible.builtin.debug:
              msg: "{{ lookup('file', '{{ ssh_keys_path }}/{{ redelk_user }}_id_rsa.pub') }}"
            loop: [1, 2]
      YAML

    stdout = IO::Memory.new
    stderr = IO::Memory.new
    Process.run(BINARY, ["-i", INVENTORY, "pb.yml"], output: stdout, error: stderr, chdir: src_dir)

    text = stderr.to_s
    # Three tasks at three distinct lines = three blocks, even though the
    # rendered literal is identical; the third task's two loop items share
    # one Origin, so its render runs twice but warns once.
    text.scan(WARNING_LINE).size.must_equal(3)
    pb_path = File.expand_path(File.join(src_dir, "pb.yml"))
    ["10:14", "12:14", "14:14"].each do |pos|
      text.must_include("Origin: #{pb_path}:#{pos}")
    end
    stdout.to_s.wont_include("Jinja constant strings")
  ensure
    FileUtils.rm_rf(src_dir) if src_dir
  end

  it "warns through the native-typed whole-span route too (set_fact, debug msg)" do
    src_dir = File.tempname("jinja-const-warn-native")
    Dir.mkdir_p(File.join(src_dir, "keys"))
    File.write(File.join(src_dir, "keys", "redelk_id_rsa.pub"), "KEY1")
    # A whole-span set_fact value and a debug msg resolve STRUCTURALLY
    # (native typing), which renders the embedded lookup constant inside
    # the krikri-jinja engine rather than the hand-rolled dispatch - the
    # same constants real warns for, so that route must warn identically.
    File.write(File.join(src_dir, "pb.yml"), <<-YAML)
      ---
      - hosts: localhost
        connection: local
        gather_facts: false
        vars:
          redelk_user: redelk
          ssh_keys_path: #{src_dir}/keys
        tasks:
          - ansible.builtin.set_fact:
              k: "{{ lookup('file', '{{ ssh_keys_path }}/{{ redelk_user }}_id_rsa.pub') }}"
          - ansible.builtin.debug:
              msg: "{{ lookup('file', '{{ ssh_keys_path }}/{{ redelk_user }}_id_rsa.pub') }}"
      YAML

    stdout = IO::Memory.new
    stderr = IO::Memory.new
    Process.run(BINARY, ["-i", INVENTORY, "pb.yml"], output: stdout, error: stderr, chdir: src_dir)

    text = stderr.to_s
    text.scan(WARNING_LINE).size.must_equal(2)
    pb_path = File.expand_path(File.join(src_dir, "pb.yml"))
    # The set_fact key sits at an 8-space indent (quote at column 12);
    # the debug msg's quote at column 14.
    text.must_include("Origin: #{pb_path}:10:12\n\n 8   tasks:\n 9     - ansible.builtin.set_fact:\n10         k: \"{{ lookup('file', '{{ ssh_keys_path }}/{{ redelk_user }}_id_rsa.pub') }}\"\n#{" " * 14}^ column 12\n\n#{HELP_LINE}\n\n")
    text.must_include("Origin: #{pb_path}:12:14\n\n10         k: \"{{ lookup('file', '{{ ssh_keys_path }}/{{ redelk_user }}_id_rsa.pub') }}\"\n11     - ansible.builtin.debug:\n12         msg: \"{{ lookup('file', '{{ ssh_keys_path }}/{{ redelk_user }}_id_rsa.pub') }}\"\n#{" " * 16}^ column 14\n\n#{HELP_LINE}\n\n")
    stdout.to_s.wont_include("Jinja constant strings")
  ensure
    FileUtils.rm_rf(src_dir) if src_dir
  end

  it "warns for a loop: whose first_found term is an embedded-template constant (issue #339)" do
    src_dir = File.tempname("jinja-const-warn-loop-ff")
    Dir.mkdir_p(src_dir)
    File.write(File.join(src_dir, "pb.yml"), <<-YAML)
      ---
      - hosts: localhost
        connection: local
        gather_facts: false
        vars:
          ansible_os_family: RedHat
        tasks:
          - ansible.builtin.debug:
              msg: "{{ item }}"
            loop: "{{ q('first_found', 'tasks/{{ ansible_os_family }}.yml', errors='ignore') }}"
      YAML

    stdout = IO::Memory.new
    stderr = IO::Memory.new
    Process.run(BINARY, ["-i", INVENTORY, "pb.yml", "--check"], output: stdout, error: stderr, chdir: src_dir)

    lines = File.read_lines(File.join(src_dir, "pb.yml"))
    pb_path = File.expand_path(File.join(src_dir, "pb.yml"))
    # The loop keyword's VALUE position (first character after `loop: `,
    # quote included): ansible inherits the templated loop VALUE's own
    # position onto the warning Origin, the same rule module-param
    # finalization already pins here (live-verified vs 2.19.11). Exactly
    # one warning: the loop resolves empty (no such candidate file under
    # errors='ignore') and the task stays a plain skip.
    stderr.to_s.must_include("#{WARNING_LINE}\n" \
                             "Origin: #{pb_path}:10:13\n\n" \
                             " 8 #{lines[7]}\n" \
                             " 9 #{lines[8]}\n" \
                             "10 #{lines[9]}\n" \
                             "#{" " * 15}^ column 13\n\n" \
                             "#{HELP_LINE}\n\n")
    stdout.to_s.wont_include("Jinja constant strings")
  ensure
    FileUtils.rm_rf(src_dir) if src_dir
  end

  it "warns the same when the loop source is a lookup('file', ...) expression" do
    src_dir = File.tempname("jinja-const-warn-loop-file")
    Dir.mkdir_p(File.join(src_dir, "keys"))
    File.write(File.join(src_dir, "keys", "redelk_id_rsa.pub"), "KEY1")
    File.write(File.join(src_dir, "pb.yml"), <<-YAML)
      ---
      - hosts: localhost
        connection: local
        gather_facts: false
        vars:
          redelk_user: redelk
          ssh_keys_path: #{src_dir}/keys
        tasks:
          - ansible.builtin.debug:
              msg: "{{ item }}"
            loop: "{{ lookup('file', '{{ ssh_keys_path }}/{{ redelk_user }}_id_rsa.pub') }}"
      YAML

    stdout = IO::Memory.new
    stderr = IO::Memory.new
    Process.run(BINARY, ["-i", INVENTORY, "pb.yml", "--check"], output: stdout, error: stderr, chdir: src_dir)

    lines = File.read_lines(File.join(src_dir, "pb.yml"))
    pb_path = File.expand_path(File.join(src_dir, "pb.yml"))
    # The non-first_found lookup route: the term's own quoted-literal
    # rerender inside the hand-rolled dispatch is the emitter here, with
    # the loop source's registration the only missing piece - so the same
    # value-position block is expected.
    stderr.to_s.must_include("#{WARNING_LINE}\n" \
                             "Origin: #{pb_path}:11:13\n\n" \
                             " 9 #{lines[8]}\n" \
                             "10 #{lines[9]}\n" \
                             "11 #{lines[10]}\n" \
                             "#{" " * 15}^ column 13\n\n" \
                             "#{HELP_LINE}\n\n")
    stdout.to_s.wont_include("Jinja constant strings")
  ensure
    FileUtils.rm_rf(src_dir) if src_dir
  end

  it "points an assert that: item's origin at the surviving value under duplicate keys (issue #1136)" do
    # fogartyp.ora-host carries TWO `that:` keys on one assert; ansible
    # warns "Using last defined value only" and pins each evaluated
    # item's warning Origin on the LAST key's value (the one that
    # survived the duplicate-key collapse), while the collapsed
    # one-item condition list made the positional index scan label the
    # FIRST key's line. Byte-compared vs ansible-core 2.19.11 on the
    # role: both the constant-template warning and the fact-injection
    # deprecation report line 11's value, never line 10's.
    src_dir = File.tempname("jinja-const-warn-dup-that")
    Dir.mkdir_p(src_dir)
    File.write(File.join(src_dir, "pb.yml"), <<-YAML)
      ---
      - hosts: localhost
        connection: local
        gather_facts: false
        vars:
          ansible_distribution_version: "7"
          os_min_supported_version: "6.4"
        tasks:
          - assert:
              that: "ansible_os_family == 'Debian'"
              that: "ansible_distribution_version >= '{{ os_min_supported_version }}'"
      YAML

    stdout = IO::Memory.new
    stderr = IO::Memory.new
    Process.run(BINARY, ["-i", INVENTORY, "pb.yml", "--check"], output: stdout, error: stderr, chdir: src_dir)

    lines = File.read_lines(File.join(src_dir, "pb.yml"))
    pb_path = File.expand_path(File.join(src_dir, "pb.yml"))
    # Line 11 is the second (surviving) `that:`; its value starts at the
    # `"` after `that: ` (column 15 on the 8-space-indent line).
    expected = "#{WARNING_LINE}\n" \
               "Origin: #{pb_path}:11:15\n\n" \
               " 9 #{lines[8]}\n" \
               "10 #{lines[9]}\n" \
               "11 #{lines[10]}\n" \
               "#{" " * 17}^ column 15\n\n" \
               "Use inline expressions, for example: `when: \"{{ a_var }}\" == 42` becomes `when: a_var == 42`\n\n"
    stderr.to_s.must_include(expected)
    # The collapse must not label the FIRST key's value either.
    stderr.to_s.wont_include("Origin: #{pb_path}:10:")
    # Last-value-wins means only the version condition was evaluated -
    # the family check never ran, like ansible's assert.
    stdout.to_s.must_include("All assertions passed")
  ensure
    FileUtils.rm_rf(src_dir) if src_dir
  end
end
