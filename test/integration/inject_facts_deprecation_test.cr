require "../minitest_helper"

# ansible-core 2.21 tags every fact it ALSO injects at the top level as
# `ansible_<fact>` (INJECT_FACTS_AS_VARS defaulting to True) and prints
# this deprecation the first time a template reads one - issue #962,
# alecunsolo.cockpit: the role's
# `when: (ansible_os_family | lower) == "debian"` task made real ansible
# print the whole block where this engine stayed silent. Every expected
# shape below was byte-compared against the locally installed
# ansible-core 2.21.6.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")

private def run_playbook(playbook_text : String) : String
  dir = PluginSpecHelper.tmp_path("inject-facts-#{Random::Secure.hex(4)}")
  FileUtils.mkdir_p(dir)
  playbook = File.join(dir, "play.yml")
  File.write(playbook, playbook_text)
  stdout = IO::Memory.new
  stderr = IO::Memory.new
  Process.run(BINARY, ["-i", "localhost,", playbook], output: stdout, error: stderr, chdir: dir)
  stderr.to_s
end

describe "INJECT_FACTS_AS_VARS deprecation from a when: clause" do
  it "attributes the Origin to the when: value token and prints the help hint" do
    stderr = run_playbook(<<-PLAYBOOK)
      - hosts: localhost
        connection: local
        gather_facts: true
        tasks:
          - name: gated by a top-level fact
            debug:
              msg: hi
            when: ansible_os_family | length > 0
      PLAYBOOK

    stderr.must_include("[WARNING]: Deprecation warnings can be disabled by setting `deprecation_warnings=False` in ansible.cfg.")
    stderr.must_include("[DEPRECATION WARNING]: INJECT_FACTS_AS_VARS default to `True` is deprecated, top-level facts will not be auto injected after the change. This feature will be removed from ansible-core version 2.24.")
    # The Origin block: the when: value's first character ('a' of
    # ansible_os_family) sits at column 13 of line 8 for this playbook
    # shape, with the two context lines above and the caret under it.
    stderr.must_include("Origin: ")
    stderr.must_include(":8:13\n")
    stderr.must_include("6       debug:\n")
    stderr.must_include("8       when: ansible_os_family | length > 0\n")
    stderr.must_include("              ^ column 13")
    stderr.must_include("Use `ansible_facts[\"fact_name\"]` (no `ansible_` prefix) instead.")
  end

  it "attributes a role task file's filtered when: Origin to the clause value token" do
    # The cockpit shape: the clause lives in the role's own tasks/main.yml
    # and filters the fact before comparing, so the Origin must point into
    # that file (line 6, column 9 - where the value's `(` starts) rather
    # than at the playbook that ran the role.
    dir = PluginSpecHelper.tmp_path("inject-facts-role-#{Random::Secure.hex(4)}")
    tasks_dir = File.join(dir, "roles", "cockpit_like", "tasks")
    FileUtils.mkdir_p(tasks_dir)
    FileUtils.mkdir_p(File.join(dir, "roles", "cockpit_like", "defaults"))
    File.write(File.join(dir, "roles", "cockpit_like", "defaults", "main.yml"), <<-YAML)
      ---
      cockpit_networkmanager_package: cockpit-networkmanager
      YAML
    File.write(File.join(tasks_dir, "main.yml"), <<-YAML)
      ---
      - name: Ensure cockpit component is installed [{{ cockpit_networkmanager_package }}]
        ansible.builtin.debug:
          msg: '{{ cockpit_networkmanager_package }}'
          verbosity: 0
        when: (ansible_os_family | lower) == "debian"
      YAML
    playbook = File.join(dir, "play.yml")
    File.write(playbook, <<-PLAYBOOK)
      - hosts: localhost
        connection: local
        gather_facts: true
        roles:
          - cockpit_like
      PLAYBOOK

    stdout = IO::Memory.new
    stderr = IO::Memory.new
    Process.run(BINARY, ["-i", "localhost,", playbook], output: stdout, error: stderr, chdir: dir)

    stdout.to_s.must_include("TASK [cockpit_like : Ensure cockpit component is installed")
    stderr.to_s.must_include("Origin: ")
    stderr.to_s.must_include("/roles/cockpit_like/tasks/main.yml:6:9\n")
    stderr.to_s.must_include("4     msg: '{{ cockpit_networkmanager_package }}'\n")
    stderr.to_s.must_include("5     verbosity: 0\n")
    stderr.to_s.must_include("6   when: (ansible_os_family | lower) == \"debian\"\n")
    stderr.to_s.must_include("          ^ column 9")
  end

  it "prints the warning once for a looped clause, deduped per Origin" do
    stderr = run_playbook(<<-PLAYBOOK)
      - hosts: localhost
        connection: local
        gather_facts: true
        tasks:
          - name: looped gate
            debug:
              msg: "{{ item }}"
            loop: [1, 2, 3]
            when: ansible_os_family | length > 0
      PLAYBOOK

    stderr.scan(/DEPRECATION WARNING\]: INJECT_FACTS_AS_VARS/).size.must_equal(1)
  end

  it "does not warn for a magic ansible_* variable that is not a top-level fact" do
    stderr = run_playbook(<<-PLAYBOOK)
      - hosts: localhost
        connection: local
        gather_facts: true
        tasks:
          - name: magic var gate
            debug:
              msg: hi
            when: not ansible_check_mode
      PLAYBOOK

    stderr.includes?("INJECT_FACTS_AS_VARS").must_equal(false)
  end
end
