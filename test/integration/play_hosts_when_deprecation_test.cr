require "../minitest_helper"

# The `play_hosts` magic-variable read deprecation raised while a `when:`
# clause evaluates (issue #835, bloxberg.corosync_pacemaker: the role's
# `import_tasks: generate.yml` gated on a folded
# `when: >- inventory_hostname == play_hosts[0] and ...` printed the
# [DEPRECATION WARNING] block in ansible-core 2.19.11 with the Origin at
# the import line's when: VALUE token, which this engine used to leave
# silent - reads whose Origin krikri does not reproduce stayed quiet).
#
# Every expected shape below was verified against the locally-installed
# ansible-core 2.19.11 (live-verified: the folded-scalar origin points at
# the `>-` token - column 9 for a two-space-indented `when: >-` - with the
# two context lines above it, and the plain-value origin at the value's
# first character).
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")

private def run(playbook_text : String, child_text : String? = nil) : {String, String}
  dir = PluginSpecHelper.tmp_path("playhosts-when-#{Random::Secure.hex(4)}")
  FileUtils.mkdir_p(dir)
  playbook = File.join(dir, "play.yml")
  File.write(playbook, playbook_text)
  if child_text
    File.write(File.join(dir, "child.yml"), child_text)
  end
  stdout = IO::Memory.new
  stderr = IO::Memory.new
  Process.run(BINARY, ["-i", "localhost,", playbook], output: stdout, error: stderr, chdir: dir)
  {stdout.to_s, stderr.to_s}
end

describe "play_hosts deprecation from a when: clause" do
  it "attributes the Origin to an import_tasks line's folded when: value token" do
    stdout, stderr = run(<<-PLAYBOOK, <<-CHILD)
      - hosts: localhost
        gather_facts: false
        connection: local
        tasks:
          - import_tasks: child.yml
            when: >-
              inventory_hostname == play_hosts[0]
      PLAYBOOK
      - name: first inlined task
        debug:
          msg: one
      - name: second inlined task
        debug:
          msg: two
      CHILD

    stdout.must_include("ok: [localhost]")
    stderr.must_include("[WARNING]: Deprecation warnings can be disabled by setting `deprecation_warnings=False` in ansible.cfg.")
    stderr.must_include("[DEPRECATION WARNING]: The `play_hosts` magic variable is deprecated. This feature will be removed from ansible-core version 2.23.")
    # The Origin block: the import line's when: VALUE token - the `>-` at
    # column 13 of the when: line (six-space indent), with the two context
    # lines above and the caret under it.
    stderr.must_include("Origin: ")
    stderr.must_include(":6:13\n")
    stderr.must_include("5     - import_tasks: child.yml\n")
    stderr.must_include("6       when: >-\n")
    stderr.must_include("              ^ column 13")
    stderr.must_include("Use `ansible_play_batch` instead.")
    # Deduplicated per distinct Origin per run, exactly like real's Display:
    # two inlined tasks evaluated the same clause, one warning.
    stderr.scan(/DEPRECATION WARNING\]: The `play_hosts` magic variable/).size.must_equal(1)
  end

  it "attributes the Origin to a task's own plain when: value token" do
    _stdout, stderr = run(<<-PLAYBOOK)
      - hosts: localhost
        gather_facts: false
        connection: local
        tasks:
          - debug:
              msg: hi
            when: play_hosts[0] == 'localhost'
      PLAYBOOK

    stderr.must_include("Origin: ")
    # The when: value's first character ('p' of play_hosts) sits at column
    # 13 of line 7 for this playbook shape.
    stderr.must_include(":7:13\n")
    stderr.must_include("5     - debug:\n")
    stderr.must_include("7       when: play_hosts[0] == 'localhost'\n")
    stderr.must_include("              ^ column 13")
  end
end
