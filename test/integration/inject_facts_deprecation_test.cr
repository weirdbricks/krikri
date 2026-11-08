require "../minitest_helper"

require "socket"

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

# Batching only engages off the local connection, so the batch-shape cases
# below need a real sshd; they skip without one. The same throwaway server
# batch_when_error_side_effects_test.cr's header documents works; override
# KRIKRI_TEST_SSHD_HOST/PORT/USER/KEY to point elsewhere.
private DEPR_SSHD_HOST = ENV["KRIKRI_TEST_SSHD_HOST"]? || "127.0.0.1"
private DEPR_SSHD_PORT = (ENV["KRIKRI_TEST_SSHD_PORT"]? || "2224").to_i
private DEPR_SSHD_USER = ENV["KRIKRI_TEST_SSHD_USER"]? || "root"
private DEPR_SSHD_KEY  = ENV["KRIKRI_TEST_SSHD_KEY"]? || "/tmp/kkt-key"

private def depr_sshd_reachable? : Bool
  return false unless File.exists?(DEPR_SSHD_KEY)
  TCPSocket.new(DEPR_SSHD_HOST, DEPR_SSHD_PORT, connect_timeout: 1).close
  true
rescue
  false
end

private def run_batched_playbook(playbook_text : String) : {String, String}
  dir = PluginSpecHelper.tmp_path("inject-facts-batch-#{Random::Secure.hex(4)}")
  FileUtils.mkdir_p(dir)
  playbook = File.join(dir, "play.yml")
  File.write(playbook, playbook_text)
  inventory = File.join(dir, "inv.ini")
  File.write(inventory, "[target]\ntarget ansible_connection=ssh ansible_host=#{DEPR_SSHD_HOST} " \
                        "ansible_user=#{DEPR_SSHD_USER} ansible_port=#{DEPR_SSHD_PORT} " \
                        "ansible_ssh_private_key_file=#{DEPR_SSHD_KEY} " \
                        "ansible_ssh_common_args='-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null " \
                        "-o IdentitiesOnly=yes -o ConnectTimeout=5'\n")
  stdout = IO::Memory.new
  stderr = IO::Memory.new
  Process.run(BINARY, ["-i", inventory, playbook], output: stdout, error: stderr, chdir: dir)
  {stdout.to_s, stderr.to_s}
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

  it "prints it for a whole `is defined` test, which resolves the name leniently" do
    # The is-defined test never goes through the substitutor, so the read
    # produced no deprecation at all (live-verified vs 2.21.6, which prints
    # the whole block Origin'd at the when: value token like any other read).
    stderr = run_playbook(<<-PLAYBOOK)
      - hosts: localhost
        connection: local
        gather_facts: true
        tasks:
          - name: gated by an is defined test
            debug:
              msg: hi
            when: ansible_os_family is defined
      PLAYBOOK

    stderr.must_include("[DEPRECATION WARNING]: INJECT_FACTS_AS_VARS default to `True` is deprecated, top-level facts will not be auto injected after the change. This feature will be removed from ansible-core version 2.24.")
    stderr.must_include(":8:13\n")
    stderr.must_include("8       when: ansible_os_family is defined\n")
    stderr.must_include("              ^ column 13")
    stderr.must_include("Use `ansible_facts[\"fact_name\"]` (no `ansible_` prefix) instead.")
  end

  it "stays silent for an is defined test on a name that is not a top-level fact" do
    stderr = run_playbook(<<-PLAYBOOK)
      - hosts: localhost
        connection: local
        gather_facts: true
        tasks:
          - name: gated by a plain variable
            debug:
              msg: hi
            when: not_a_fact is defined
      PLAYBOOK

    stderr.includes?("INJECT_FACTS_AS_VARS").must_equal(false)
  end

  it "attributes a loop source's fact read to the candidate element that named it" do
    # mullholland.ntp's "Include distribution specific variables" (issue
    # #956): a with_first_found: candidate list of template strings. Real
    # renders the whole candidate list as ONE templating operation and
    # tags the deprecation at the first candidate that named a fact, never
    # at the `with_first_found:` keyword line - one block for the task,
    # live-verified against 2.21.6.
    dir = PluginSpecHelper.tmp_path("inject-facts-loop-#{Random::Secure.hex(4)}")
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, "default.yml"), "---\nntp_package: ntp\n")
    playbook = File.join(dir, "play.yml")
    File.write(playbook, <<-PLAYBOOK)
      - hosts: localhost
        connection: local
        gather_facts: true
        tasks:
          - name: Include distribution specific variables
            ansible.builtin.include_vars: "{{ item }}"
            with_first_found:
              - '{{ ansible_distribution }}-{{ ansible_distribution_major_version }}.yml'
              - '{{ ansible_distribution }}.yml'
              - '{{ ansible_os_family }}.yml'
              - 'default.yml'
      PLAYBOOK

    stdout = IO::Memory.new
    stderr = IO::Memory.new
    Process.run(BINARY, ["-i", "localhost,", playbook], output: stdout, error: stderr, chdir: dir)

    # The candidate on line 8 (its opening quote, column 11) is the first
    # element naming a fact, and it is the only block the task gets.
    stderr.to_s.must_include("Origin: #{playbook}:8:11\n")
    stderr.to_s.must_include("8         - '{{ ansible_distribution }}-{{ ansible_distribution_major_version }}.yml'\n")
    stderr.to_s.must_include("            ^ column 11")
    stderr.to_s.scan(/DEPRECATION WARNING\]: INJECT_FACTS_AS_VARS/).size.must_equal(1)
    stderr.to_s.wont_include("Origin: #{playbook}:7:")
  end

  # Issue #979 (6nsh.zabbix_proxy, ginsys.nginx / round 29902182): a batch
  # group's later members are evaluated and prepared during batch-build -
  # their when:, and for a template: the whole file render - so a fact read
  # there printed the block even when the group's FIRST member failed and
  # the play ended before that task was ever reached. Real printed nothing.
  it "stays silent for batch members a failed neighbour keeps the play from reaching" do
    skip "no reachable test sshd (see this file's header for the throwaway setup)" unless depr_sshd_reachable?

    template = PluginSpecHelper.tmp_path("inject-facts-batch-#{Random::Secure.hex(4)}.j2")
    File.write(template, "distro {{ ansible_distribution_major_version }}\n")
    begin
      stdout, stderr = run_batched_playbook(<<-PLAYBOOK)
        - hosts: target
          gather_facts: true
          tasks:
            - name: fail first
              ansible.builtin.command: /bin/false
            - name: gated by a top-level fact
              ansible.builtin.command: /bin/true
              when: ansible_os_family | length > 0
            - name: render a template that reads a fact
              ansible.builtin.template:
                src: #{template}
                dest: /tmp/krikri-979-never-reached.txt
                mode: '0644'
        PLAYBOOK

      stdout.wont_include("gated by a top-level fact")
      stdout.wont_include("render a template that reads a fact")
      stderr.includes?("INJECT_FACTS_AS_VARS").must_equal(false)
    ensure
      File.delete(template) if File.exists?(template)
    end
  end

  # The other half of the same rule: the warning a batch build merely
  # prepared must still reach stderr once its task is really reached.
  it "still warns for a batch member that is reached" do
    skip "no reachable test sshd (see this file's header for the throwaway setup)" unless depr_sshd_reachable?

    stdout, stderr = run_batched_playbook(<<-PLAYBOOK)
      - hosts: target
        gather_facts: true
        tasks:
          - name: first member succeeds
            ansible.builtin.command: /bin/true
          - name: gated by a top-level fact
            ansible.builtin.command: /bin/true
            when: ansible_os_family | length > 0
      PLAYBOOK

    stdout.must_include("gated by a top-level fact")
    stderr.must_include("[DEPRECATION WARNING]: INJECT_FACTS_AS_VARS default to `True` is deprecated, top-level facts will not be auto injected after the change. This feature will be removed from ansible-core version 2.24.")
    stderr.scan(/DEPRECATION WARNING\]: INJECT_FACTS_AS_VARS/).size.must_equal(1)
  end
end
