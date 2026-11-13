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

# Same shape with a role alongside the playbook, so a first_found lookup can
# chain through the role's own vars/main.yml the way real roles spell it.
private def run_batched_role_playbook(role_name : String, role_vars : String, role_tasks : String, playbook_text : String) : {String, String, String}
  dir = PluginSpecHelper.tmp_path("inject-facts-ffrole-#{Random::Secure.hex(4)}")
  role_dir = File.join(dir, "roles", role_name)
  FileUtils.mkdir_p(File.join(role_dir, "vars"))
  FileUtils.mkdir_p(File.join(role_dir, "tasks"))
  File.write(File.join(role_dir, "vars", "main.yml"), role_vars)
  File.write(File.join(role_dir, "tasks", "main.yml"), role_tasks)
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
  {stdout.to_s, stderr.to_s, File.join(role_dir, "vars", "main.yml")}
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

  # Real evaluates the task's conditional BEFORE it re-raises an undefined
  # loop source, so the clause's fact read still warns - and does so as its
  # OWN templating operation, not as part of the loop source. brentwg.docker's
  # import-line `when: ansible_os_family == 'RedHat'` gating a
  # `with_items: "{{ docker_packages_old }}"` import lost the block entirely
  # because this engine failed on the loop source first (issue #1089,
  # live-verified against ansible-core 2.21.6: the warning prints before the
  # [ERROR] block, Origin'd at the clause value token).
  it "warns for a when: clause even when the loop source above it is undefined" do
    stderr = run_playbook(<<-PLAYBOOK)
      - hosts: localhost
        connection: local
        gather_facts: true
        tasks:
          - name: loop over an undefined list
            debug:
              msg: "{{ item }}"
            when: ansible_os_family | length > 0
            with_items: "{{ no_such_list }}"
      PLAYBOOK

    stderr.scan(/DEPRECATION WARNING\]: INJECT_FACTS_AS_VARS/).size.must_equal(1)
    stderr.must_include(":8:13\n")
    stderr.must_include("8       when: ansible_os_family | length > 0\n")
    stderr.must_include("              ^ column 13")
  end

  # A block-sequence param value is a set of independent YAML scalars, and
  # real pins the read at the ITEM that named the fact, not at the param's
  # key line (fabiohbarbosa.synapse's role banner, issue #1089,
  # live-verified against 2.21.6: 5:9 - the banner item - where this engine
  # reported 3:9, the `msg:` key).
  it "pins a fact read inside a block-sequence param value at its own item" do
    stderr = run_playbook(<<-PLAYBOOK)
      - hosts: localhost
        connection: local
        gather_facts: true
        tasks:
          - name: banner
            debug:
              msg:
                - "***************************************"
                - "Running for {{ ansible_distribution }}"
                - "***************************************"
      PLAYBOOK

    stderr.must_include(":9:13\n")
    stderr.must_include("9           - \"Running for {{ ansible_distribution }}\"\n")
    stderr.must_include("^ column 13")
    stderr.includes?(":7:11").must_equal(false)
  end

  # A module called in its free-form key=value form writes its params inside
  # the action directive's own scalar, so the `<key>:` line scan finds
  # nothing. Real still warns for a fact the value reads, anchored at the
  # `<key>=` token on the directive's line - fabiohbarbosa.synapse's failing
  # `fail: msg="... {{ ansible_distribution }} ..."` reported 9:9 (issue
  # #1089, live-verified against 2.21.6).
  it "places a free-form action param's fact read at its key= token" do
    stderr = run_playbook(<<-PLAYBOOK)
      - hosts: localhost
        connection: local
        gather_facts: true
        tasks:
          - name: unsupported
            fail: msg="Role not compatibility for {{ ansible_distribution }}"
      PLAYBOOK

    stderr.must_include("INJECT_FACTS_AS_VARS")
    stderr.must_include(":6:13\n")
    stderr.must_include("6       fail: msg=\"Role not compatibility for {{ ansible_distribution }}\"\n")
    stderr.must_include("              ^ column 13")
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

  # The disable-hint is one-per-RUN across every deprecation kind (real
  # Display dedups it process-wide). The parse-time action-mapping warning
  # and the executor's INJECT_FACTS warning kept separate once-flags, so a
  # run hitting both printed the hint twice - farynam.mfitbs_openvpn_easyrsa
  # in check mode, issue #1149.
  it "prints the disable hint once when parse-time and executor deprecations share a run" do
    stderr = run_playbook(<<-PLAYBOOK)
      - hosts: localhost
        connection: local
        gather_facts: true
        tasks:
          - name: mapping form local_action
            local_action:
              module: file
              path: /tmp/krikri-hint-once-check
              state: directory
            when: false
          - name: gated by a top-level fact
            debug:
              msg: hi
            when: ansible_os_family | length > 0
      PLAYBOOK

    stderr.must_include("[WARNING]: Deprecation warnings can be disabled by setting `deprecation_warnings=False` in ansible.cfg.")
    stderr.must_include("[DEPRECATION WARNING]: Using a mapping for `action` is deprecated.")
    stderr.must_include("[DEPRECATION WARNING]: INJECT_FACTS_AS_VARS default to `True` is deprecated, top-level facts will not be auto injected after the change.")
    stderr.scan(/Deprecation warnings can be disabled/).size.must_equal(1)
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

  # jetune.docker_swarm_master's `when:` lists (issue #990): real evaluates
  # each item as its own templating operation, so a two-item list prints two
  # blocks, each pinned at the item that named the fact - never at the
  # `when:` key line, and never just one block for the whole list.
  # Live-verified vs 2.21.6.
  it "pins each block-sequence when: item's read at its own item token" do
    stderr = run_playbook(<<-PLAYBOOK)
      - hosts: localhost
        connection: local
        gather_facts: true
        tasks:
          - name: item gate
            debug:
              msg: hi
            when:
              - ansible_os_family | length > 0
              - ansible_architecture | length > 0
      PLAYBOOK

    stderr.scan(/DEPRECATION WARNING\]: INJECT_FACTS_AS_VARS/).size.must_equal(2)
    stderr.must_include(":9:11\n")
    stderr.must_include("8       when:\n")
    stderr.must_include("9         - ansible_os_family | length > 0\n")
    stderr.must_include("            ^ column 11")
    stderr.must_include(":10:11\n")
    stderr.must_include("10         - ansible_architecture | length > 0\n")
  end

  # mullholland.swap's "Enabling swap" gate (issue #1027): each of its
  # three items reads the SAME fact, and real evaluates every item as its
  # own templating operation with its own deprecate-tag audit context -
  # one block per item, each at its own item token. Pinning every read at
  # whichever item merely named the fact first collapsed all three
  # Origins onto item 1, and the display's per-Origin dedupe dropped the
  # rest (one block where real prints three).
  it "prints one block per when: item reading the same fact, each at its own item token" do
    stderr = run_playbook(<<-PLAYBOOK)
      - hosts: localhost
        connection: local
        gather_facts: true
        tasks:
          - name: Enabling swap
            ansible.builtin.command: /bin/true
            changed_when: false
            when:
              - ansible_virtualization_type != "docker"
              - ansible_virtualization_type != "containerd"
              - ansible_virtualization_type != "container"
      PLAYBOOK

    stderr.scan(/DEPRECATION WARNING\]: INJECT_FACTS_AS_VARS/).size.must_equal(3)
    stderr.must_include(":9:11\n")
    stderr.must_include(":10:11\n")
    stderr.must_include(":11:11\n")
    stderr.must_include("9         - ansible_virtualization_type != \"docker\"\n")
    stderr.must_include("11         - ansible_virtualization_type != \"container\"\n")
    stderr.must_include("            ^ column 11")
  end

  # YAML lets a block sequence's items sit at their parent key's own
  # indent, and Ansible-Security-Compliance's rhel7-role-C2S writes its
  # `when:` lists that way: real anchors each item's scalar token the same
  # as a deeper-indented one (tasks/main.yml:19:7 live-captured vs
  # ansible-playbook 2.21, issue #1017), where this engine reported the
  # `when:` key line's own value position (18:10) instead.
  it "pins a same-indent block-sequence when: item's read at its own item token" do
    dir = PluginSpecHelper.tmp_path("inject-facts-same-indent-#{Random::Secure.hex(4)}")
    tasks_dir = File.join(dir, "roles", "c2s_like", "tasks")
    FileUtils.mkdir_p(tasks_dir)
    File.write(File.join(tasks_dir, "main.yml"), <<-YAML)
      ---
      -   name: gated by a top-level fact
          debug:
              msg: hi
          tags:
          - one
          - two
          when:
          - (ansible_virtualization_role != "guest" or ansible_virtualization_type != "docker")
      YAML
    playbook = File.join(dir, "play.yml")
    File.write(playbook, <<-PLAYBOOK)
      - hosts: localhost
        connection: local
        gather_facts: true
        roles:
          - c2s_like
      PLAYBOOK

    stdout = IO::Memory.new
    stderr = IO::Memory.new
    Process.run(BINARY, ["-i", "localhost,", playbook], output: stdout, error: stderr, chdir: dir)

    stderr.to_s.scan(/DEPRECATION WARNING\]: INJECT_FACTS_AS_VARS/).size.must_equal(1)
    stderr.to_s.must_include("/roles/c2s_like/tasks/main.yml:9:7\n")
    stderr.to_s.must_include("7     - two\n")
    stderr.to_s.must_include("8     when:\n")
    stderr.to_s.must_include("9     - (ansible_virtualization_role != \"guest\" or ansible_virtualization_type != \"docker\")\n")
    stderr.to_s.must_include("\n        ^ column 7")
    stderr.to_s.includes?(":8:10").must_equal(false)
  end

  # A dynamic include's loaded tasks inherit the enclosing BLOCK's when:
  # through real's parent chain, so the block's fact read is reported after
  # the first included task's banner, Origin'd at the block's own clause
  # item (jetune.docker's main.yml/initialize.yml shape, issue #990).
  # Live-verified vs 2.21.6; the include statement's OWN when: stays silent
  # (issue #974), which is why the clause lives on the block here.
  it "warns for the block when: a dynamic include's tasks inherit" do
    dir = PluginSpecHelper.tmp_path("inject-facts-block-include-#{Random::Secure.hex(4)}")
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, "inner.yml"), <<-YAML)
      ---
      - name: inner task
        debug:
          msg: hi
      YAML
    playbook = File.join(dir, "play.yml")
    File.write(playbook, <<-PLAYBOOK)
      - hosts: localhost
        connection: local
        gather_facts: true
        tasks:
          - name: outer
            block:
              - name: include inner
                include_tasks: inner.yml
            when:
              - ansible_os_family | length > 0
      PLAYBOOK

    stdout = IO::Memory.new
    stderr = IO::Memory.new
    Process.run(BINARY, ["-i", "localhost,", playbook], output: stdout, error: stderr, chdir: dir)

    stdout.to_s.must_include("TASK [inner task]")
    stderr = stderr.to_s
    stderr.scan(/DEPRECATION WARNING\]: INJECT_FACTS_AS_VARS/).size.must_equal(1)
    stderr.must_include("/play.yml:10:11\n")
    stderr.must_include(" 8           include_tasks: inner.yml\n")
    stderr.must_include(" 9       when:\n")
    stderr.must_include("10         - ansible_os_family | length > 0\n")
    stderr.must_include("             ^ column 11")
  end

  # The skipped half of the same inheritance: a block inside the included
  # file that is itself skipped still evaluates the inherited clause for
  # each child, and real pins that read at the OUTER block's item - not at
  # the inner block's own `when:` line (issue #990, live-verified vs 2.21.6).
  it "keeps the outer block's Origin for a skipped block inside an include" do
    dir = PluginSpecHelper.tmp_path("inject-facts-skipped-block-#{Random::Secure.hex(4)}")
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, "inner.yml"), <<-YAML)
      ---
      - name: inner block
        block:
          - name: inner task
            debug:
              msg: hi
        when: false
      YAML
    playbook = File.join(dir, "play.yml")
    File.write(playbook, <<-PLAYBOOK)
      - hosts: localhost
        connection: local
        gather_facts: true
        tasks:
          - name: outer
            block:
              - name: include inner
                include_tasks: inner.yml
            when:
              - ansible_os_family | length > 0
      PLAYBOOK

    stdout = IO::Memory.new
    stderr = IO::Memory.new
    Process.run(BINARY, ["-i", "localhost,", playbook], output: stdout, error: stderr, chdir: dir)

    stdout.to_s.must_include("skipping: [localhost]")
    stderr = stderr.to_s
    stderr.scan(/DEPRECATION WARNING\]: INJECT_FACTS_AS_VARS/).size.must_equal(1)
    stderr.must_include("/play.yml:10:11\n")
    stderr.includes?("/inner.yml:7:").must_equal(false)
  end

  # The RUNNING half of the same inheritance: real evaluates the block's
  # when: as its own clause on every child (afpacket.devops_tools's
  # `when: ansible_os_family == "RedHat"` wrapping per-tool blocks, issue
  # #1144), so the fact read warns once, Origin'd at the BLOCK's clause
  # site - never once per child at each child's own `when:` token, which
  # is what a merged-into-one-string condition produced (live-verified
  # vs 2.21.6: one block, under the first child's banner).
  it "keeps the block's clause Origin for a running block's children" do
    stderr = run_playbook(<<-PLAYBOOK)
      - hosts: localhost
        connection: local
        gather_facts: true
        vars:
          serverless: true
          helm: true
        tasks:
          - name: redhat only
            block:
              - name: package dependencies
                debug:
                  msg: pkg
                when: serverless|bool

              - name: helm step
                debug:
                  msg: helm
                when: helm|bool
            when: ansible_os_family | length > 0
      PLAYBOOK

    stderr.scan(/DEPRECATION WARNING\]: INJECT_FACTS_AS_VARS/).size.must_equal(1)
    # The outer block's own `when:` value token (line 19, column 13) - not
    # the children's clause tokens at 13:17 / 18:17.
    stderr.must_include(":19:13\n")
    stderr.must_include("when: ansible_os_family | length > 0\n")
    stderr.must_include("              ^ column 13")
    stderr.includes?(":13:17").must_equal(false)
    stderr.includes?(":18:17").must_equal(false)
  end

  # Issue #995 (roxxers.certbot): the role's tasks/main.yml gates
  # `import_tasks: setup-RedHat.yml` on `ansible_os_family == 'RedHat'`
  # and that imported file is a block:. The import's clause is evaluated
  # FIRST and, being False off a RedHat host, short-circuits the block's
  # own clauses - real 2.21.6 prints exactly one block, Origin'd at the
  # import line's `when:` token in tasks/main.yml, where krikri stayed
  # silent (the merged condition text exists nowhere in the imported
  # file, so the own-file scan found no clause to label).
  it "attributes a skipped imported block's Origin to the import's when: token" do
    dir = PluginSpecHelper.tmp_path("inject-facts-import-block-#{Random::Secure.hex(4)}")
    tasks_dir = File.join(dir, "roles", "certbot_like", "tasks")
    FileUtils.mkdir_p(tasks_dir)
    File.write(File.join(tasks_dir, "main.yml"), <<-YAML)
      ---
      - import_tasks: setup-RedHat.yml
        when: ansible_os_family == 'NotARealFamily'

      - name: keep the play alive
        ansible.builtin.debug:
          msg: done
      YAML
    File.write(File.join(tasks_dir, "setup-RedHat.yml"), <<-YAML)
      ---
      - block:

        - name: redhat only step
          ansible.builtin.debug:
            msg: redhat

        when:
          - ansible_distribution == 'NotARealDistro'
          - ansible_distribution_major_version | int >= 8
      YAML
    playbook = File.join(dir, "play.yml")
    File.write(playbook, <<-PLAYBOOK)
      - hosts: localhost
        connection: local
        gather_facts: true
        roles:
          - certbot_like
      PLAYBOOK

    stdout = IO::Memory.new
    stderr = IO::Memory.new
    Process.run(BINARY, ["-i", "localhost,", playbook], output: stdout, error: stderr, chdir: dir)

    stdout.to_s.must_include("TASK [certbot_like : redhat only step]")
    stderr = stderr.to_s
    stderr.scan(/DEPRECATION WARNING\]: INJECT_FACTS_AS_VARS/).size.must_equal(1)
    stderr.must_include("Origin: #{File.join(tasks_dir, "main.yml")}:3:9\n")
    stderr.must_include("3   when: ansible_os_family == 'NotARealFamily'\n")
    stderr.must_include("          ^ column 9")
    # Nothing past the False import clause is templated, so the block's
    # own fact reads cannot be labeled.
    stderr.wont_include("setup-RedHat.yml:")
  end

  # The complement: an import clause that PASSES still gets its own block
  # and the block's own clause then evaluates too, so both deprecate - the
  # import's first, in evaluation order (live-verified vs 2.21.6).
  it "prints one block per evaluated clause, the import's before the block's own" do
    dir = PluginSpecHelper.tmp_path("inject-facts-import-block-#{Random::Secure.hex(4)}")
    tasks_dir = File.join(dir, "roles", "certbot_like", "tasks")
    FileUtils.mkdir_p(tasks_dir)
    File.write(File.join(tasks_dir, "main.yml"), <<-YAML)
      ---
      - import_tasks: setup-RedHat.yml
        when: ansible_os_family != 'NotARealFamily'

      - name: keep the play alive
        ansible.builtin.debug:
          msg: done
      YAML
    File.write(File.join(tasks_dir, "setup-RedHat.yml"), <<-YAML)
      ---
      - block:

        - name: redhat only step
          ansible.builtin.debug:
            msg: redhat

        when: ansible_distribution == 'NotARealDistro'
      YAML
    playbook = File.join(dir, "play.yml")
    File.write(playbook, <<-PLAYBOOK)
      - hosts: localhost
        connection: local
        gather_facts: true
        roles:
          - certbot_like
      PLAYBOOK

    stdout = IO::Memory.new
    stderr = IO::Memory.new
    Process.run(BINARY, ["-i", "localhost,", playbook], output: stdout, error: stderr, chdir: dir)

    stdout.to_s.must_include("TASK [certbot_like : redhat only step]")
    stderr = stderr.to_s
    stderr.scan(/DEPRECATION WARNING\]: INJECT_FACTS_AS_VARS/).size.must_equal(2)
    stderr.must_include("Origin: #{File.join(tasks_dir, "main.yml")}:3:9\n")
    stderr.must_include("Origin: #{File.join(tasks_dir, "setup-RedHat.yml")}:8:9\n")
    (stderr.index!("main.yml:3:9") < stderr.index!("setup-RedHat.yml:8:9")).must_equal(true)
  end

  # Issue #1099 (brentwg.docker): the same import clause, but the imported
  # file holds plain tasks rather than a block: - every one of them inherits
  # the False clause, yet real 2.21.6 prints the deprecation exactly once, at
  # the import's own `when:` token, and never at the imported file (verified
  # in normal and --check mode alike). The role's main.yml carries a task
  # before the import, so the Origin is not at line 1.
  it "prints one deprecation for an import clause inherited by plain imported tasks" do
    dir = PluginSpecHelper.tmp_path("inject-facts-import-plain-#{Random::Secure.hex(4)}")
    tasks_dir = File.join(dir, "roles", "docker_like", "tasks")
    FileUtils.mkdir_p(tasks_dir)
    File.write(File.join(tasks_dir, "main.yml"), <<-YAML)
      ---
      - name: keep the play alive
        ansible.builtin.debug:
          msg: done

      # Perform OS-specific family tasks
      - import_tasks: setup-RedHat.yml
        when: ansible_os_family == 'RedHat'
      YAML
    File.write(File.join(tasks_dir, "setup-RedHat.yml"), <<-YAML)
      ---
      - name: redhat only step one
        ansible.builtin.debug:
          msg: one

      - name: redhat only step two
        ansible.builtin.debug:
          msg: two
      YAML
    playbook = File.join(dir, "play.yml")
    File.write(playbook, <<-PLAYBOOK)
      - hosts: localhost
        connection: local
        gather_facts: true
        roles:
          - docker_like
      PLAYBOOK

    stdout = IO::Memory.new
    stderr = IO::Memory.new
    Process.run(BINARY, ["-i", "localhost,", playbook], output: stdout, error: stderr, chdir: dir)

    stdout.to_s.must_include("skipping: [localhost]")
    stderr = stderr.to_s
    stderr.scan(/DEPRECATION WARNING\]: INJECT_FACTS_AS_VARS/).size.must_equal(1)
    stderr.must_include("Origin: #{File.join(tasks_dir, "main.yml")}:8:9\n")
    stderr.must_include("7 - import_tasks: setup-RedHat.yml\n")
    stderr.must_include("8   when: ansible_os_family == 'RedHat'\n")
    stderr.must_include("          ^ column 9")
    stderr.wont_include("setup-RedHat.yml:")
  end
end

# The template action hands the engine its whole variable scope up front, so
# it re-renders every stored value eagerly - while ansible-core templates a
# value lazily at the render that consumes it. A value nothing consumes must
# therefore stay silent (issue #1091, msterhuj.victoriametrics_single's
# `go_arch`, live-verified against 2.21.6).
describe "INJECT_FACTS_AS_VARS deprecation from a template task's variable scope" do
  private def template_role_dir(name : String) : String
    dir = PluginSpecHelper.tmp_path("#{name}-#{Random::Secure.hex(4)}")
    FileUtils.mkdir_p(File.join(dir, "roles", "vm_like", "vars"))
    FileUtils.mkdir_p(File.join(dir, "roles", "vm_like", "defaults"))
    FileUtils.mkdir_p(File.join(dir, "roles", "vm_like", "tasks"))
    FileUtils.mkdir_p(File.join(dir, "roles", "vm_like", "templates"))
    File.write(File.join(dir, "roles", "vm_like", "vars", "main.yml"), <<-YAML)
      ---
      go_arch_map:
        i386: '386'
        x86_64: 'amd64'
        aarch64: 'arm64'

      go_arch: "{{ go_arch_map[ansible_architecture] | default(ansible_architecture) }}"
      YAML
    File.write(File.join(dir, "roles", "vm_like", "defaults", "main.yml"), <<-YAML)
      ---
      vm_like_repo_url: "https://example.invalid/releases"
      vm_like_download_url: "{{ vm_like_repo_url }}/{{ go_arch }}-v1.0.0.tar.gz"
      YAML
    File.write(File.join(dir, "roles", "vm_like", "tasks", "main.yml"), <<-YAML)
      ---
      - name: keep the play alive
        ansible.builtin.debug:
          msg: done

      - name: render a config file
        ansible.builtin.template:
          src: "config.j2"
          dest: "#{dir}/rendered.txt"
          mode: "0644"
      YAML
    File.write(File.join(dir, "play.yml"), <<-PLAYBOOK)
      - hosts: localhost
        connection: local
        gather_facts: true
        roles:
          - vm_like
      PLAYBOOK
    dir
  end

  it "stays silent for a scope value the template never consumes" do
    dir = template_role_dir("inject-facts-template-silent")
    File.write(File.join(dir, "roles", "vm_like", "templates", "config.j2"), "hello\n")

    stdout = IO::Memory.new
    stderr = IO::Memory.new
    Process.run(BINARY, ["-i", "localhost,", File.join(dir, "play.yml")], output: stdout, error: stderr, chdir: dir)

    stdout.to_s.must_include("TASK [vm_like : render a config file]")
    stderr.to_s.wont_include("INJECT_FACTS_AS_VARS")
  end

  it "warns at the forwarding chain's innermost fact declaration when the template reads it" do
    dir = template_role_dir("inject-facts-template-chain")
    File.write(File.join(dir, "roles", "vm_like", "templates", "config.j2"), "{{ vm_like_download_url }}\n")

    stdout = IO::Memory.new
    stderr = IO::Memory.new
    Process.run(BINARY, ["-i", "localhost,", File.join(dir, "play.yml")], output: stdout, error: stderr, chdir: dir)

    stderr = stderr.to_s
    stderr.scan(/DEPRECATION WARNING\]: INJECT_FACTS_AS_VARS/).size.must_equal(1)
    stderr.must_include("Origin: #{File.join(dir, "roles", "vm_like", "vars", "main.yml")}:7:10\n")
    stderr.must_include("Use `ansible_facts[\"fact_name\"]` (no `ansible_` prefix) instead.")
  end
end

# Issue #1167 (bramford.apt-sources, round 29908271): real trips the
# top-level fact deprecation DURING the template render, and jinja2
# resolves a frame's names only when that frame's code starts - a
# top-level dead `{% if %}` branch's name joins the prologue (still
# warns), while a `{% for %}` body's names resolve per iteration, so a
# render that dies on an undefined iterable before the first iteration
# prints NO block for them (live-verified against 2.21.6 and Jinja
# 3.1.6's compiled code). Krikri keyed the whole probe off the static
# AST and warned for the loop body's `ansible_distribution_release`
# reads real never reached.
describe "INJECT_FACTS_AS_VARS deprecation vs a render that dies before a loop frame ran" do
  private def failing_render_playbook_dir(name : String, template_text : String) : String
    dir = PluginSpecHelper.tmp_path("#{name}-#{Random::Secure.hex(4)}")
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, "fact.j2"), template_text)
    File.write(File.join(dir, "play.yml"), <<-PLAYBOOK)
      - hosts: localhost
        connection: local
        gather_facts: true
        tasks:
          - name: render
            ansible.builtin.template:
              src: fact.j2
              dest: #{dir}/rendered.txt
            ignore_errors: true
      PLAYBOOK
    dir
  end

  it "prints no block when the render dies on an undefined loop iterable" do
    dir = failing_render_playbook_dir("inject-facts-loop-fail", <<-TEMPLATE)
      {% for repo in apt_sources_repos %}
      {% if repo != ansible_distribution_release + "-backports" %}
      deb http://example.invalid {{ repo }} main
      {% endif %}
      {% endfor %}
      TEMPLATE

    stdout = IO::Memory.new
    stderr = IO::Memory.new
    Process.run(BINARY, ["-i", "localhost,", File.join(dir, "play.yml")], output: stdout, error: stderr, chdir: dir)

    stdout.to_s.must_include("'apt_sources_repos' is undefined")
    stderr.to_s.wont_include("INJECT_FACTS_AS_VARS")
  end

  it "still prints the block for a top-level read that ran before a later failure" do
    dir = failing_render_playbook_dir("inject-facts-top-fail", "{{ ansible_os_family }}{{ also_missing }}\n")

    stdout = IO::Memory.new
    stderr = IO::Memory.new
    Process.run(BINARY, ["-i", "localhost,", File.join(dir, "play.yml")], output: stdout, error: stderr, chdir: dir)

    stderr.to_s.scan(/DEPRECATION WARNING\]: INJECT_FACTS_AS_VARS/).size.must_equal(1)
    stderr.to_s.must_include("Origin: #{File.join(dir, "fact.j2")}\n")
  end

  it "still prints the block for a dead-branch read when the render succeeds" do
    dir = failing_render_playbook_dir("inject-facts-dead-branch", "{% if false %}{{ ansible_os_family }}{% endif %}\n")

    stdout = IO::Memory.new
    stderr = IO::Memory.new
    Process.run(BINARY, ["-i", "localhost,", File.join(dir, "play.yml")], output: stdout, error: stderr, chdir: dir)

    stdout.to_s.must_include("TASK [render]")
    stderr.to_s.scan(/DEPRECATION WARNING\]: INJECT_FACTS_AS_VARS/).size.must_equal(1)
    stderr.to_s.must_include("Origin: #{File.join(dir, "fact.j2")}\n")
  end
end

# Issue #1138 (nekeal.postgresql_db, round 29907013): real's TaskExecutor
# runs each task inside a DeferredWarningContext, so a deprecation raised
# while the task runs - here an INJECT_FACTS_AS_VARS read templating the
# task's own args - displays at the result's display point, AFTER every
# warning the module's own result carries (the callback's _handle_warnings
# prints warnings first, then deprecations; live-verified against 2.21.6
# with a `find:` task whose paths template reads a fact and whose run
# warns about an inaccessible path). Krikri printed the block at read
# time, before the module ever ran, ahead of the module's [WARNING] line.
describe "INJECT_FACTS_AS_VARS deprecation vs a module's own warnings" do
  it "displays the module's [WARNING] before the arg-templating [DEPRECATION WARNING] block" do
    stderr = run_playbook(<<-PLAYBOOK)
      - hosts: localhost
        connection: local
        gather_facts: true
        tasks:
          - name: Find configs
            ansible.builtin.find:
              paths: "/nonexistent-krikri-1138/{{ 'cfg' if ansible_python.version.major == 3 else 'other' }}"
              patterns: "*.conf"
      PLAYBOOK

    # The find module's own access-issue warning comes back in its result
    # and must print before the deprecation block the args' fact read
    # produced.
    stderr.must_include("[WARNING]: Skipped '/nonexistent-krikri-1138/cfg' path due to this access issue")
    warning_at = stderr.index!("[WARNING]: Skipped")
    deprecation_at = stderr.index!("[DEPRECATION WARNING]: INJECT_FACTS_AS_VARS")
    (warning_at < deprecation_at).must_equal(true)
    # The block still lands with its task - before the run ends.
    stderr.must_include("Use `ansible_facts[\"fact_name\"]` (no `ansible_` prefix) instead.")
  end

  it "does the same for a batched member over ssh" do
    skip "no reachable test sshd (see this file's header for the throwaway setup)" unless depr_sshd_reachable?

    stdout, stderr = run_batched_playbook(<<-PLAYBOOK)
      - hosts: target
        gather_facts: true
        tasks:
          - name: first member succeeds
            ansible.builtin.command: /bin/true
          - name: Find configs
            ansible.builtin.find:
              paths: "/nonexistent-krikri-1138/{{ 'cfg' if ansible_python.version.major == 3 else 'other' }}"
              patterns: "*.conf"
      PLAYBOOK

    stdout.must_include("TASK [Find configs]")
    warning_at = stderr.index!("[WARNING]: Skipped")
    deprecation_at = stderr.index!("[DEPRECATION WARNING]: INJECT_FACTS_AS_VARS")
    (warning_at < deprecation_at).must_equal(true)
  end
end

# Issue #1169 (idiv_biodiversity.nsswitch, round 29908264): the role's
# `lookup('first_found', __nsswitch_template)` chains through role vars whose
# values read top-level facts. The lookup's internal param renderer hardcoded
# the host identity "localhost", so on any REMOTE target every per-host Origin
# attribution inside that render missed (the origin lookup registry is keyed
# by the calling host) and the whole block stayed silent where real printed
# it - on a local connection the host happened to BE localhost and the same
# role printed the block, which is why every local repro passed.
describe "INJECT_FACTS_AS_VARS deprecation from a first_found lookup's param rendering" do
  it "warns on a remote host when the lookup's candidates chain through fact-reading role vars" do
    skip "no reachable test sshd (see this file's header for the throwaway setup)" unless depr_sshd_reachable?

    role_vars = <<-VARS
      ---
      __ff_distro: >-
        {{ ansible_distribution | lower }}

      __ff_first:
        - '{{ __ff_distro }}'
        - 'exists'

      __ff_template:
        files: >-
          {{
            __ff_first |
              map('regex_replace', '^', 'ff_') |
              map('regex_replace', '$', '.yml') |
              list
          }}
        paths:
          - files
      VARS
    role_tasks = <<-TASKS
      ---
      - name: find os file
        ansible.builtin.template:
          src: '{{ lookup("first_found", __ff_template) }}'
          dest: /tmp/krikri-1169-ff.txt
          mode: '0644'
      TASKS
    playbook = <<-PLAYBOOK
      - hosts: target
        become: true
        gather_facts: true
        roles:
          - ff_like_nsswitch
      PLAYBOOK

    stdout, stderr, role_vars_path = run_batched_role_playbook("ff_like_nsswitch", role_vars, role_tasks, playbook)

    # The role ships no matching template, so the lookup exhausts and fails
    # the task exactly like idiv_biodiversity.nsswitch's round run did - the
    # deprecation block must still print (real printed it ahead of the
    # failure).
    stdout.must_include("TASK [ff_like_nsswitch : find os file]")
    stdout.must_include("No file was found when using first_found")
    stderr.must_include("[DEPRECATION WARNING]: INJECT_FACTS_AS_VARS default to `True` is deprecated, top-level facts will not be auto injected after the change. This feature will be removed from ansible-core version 2.24.")
    stderr.must_include("[WARNING]: Deprecation warnings can be disabled by setting `deprecation_warnings=False` in ansible.cfg.")
    # The block is Origin'd at the fact-reading value's own declaration in the
    # role's vars file (real live-verified vs 2.21.6 on the original role:
    # vars/main.yml:7:20, the `__nsswitch_distro` line - here the same
    # declaration sits at 2:14).
    stderr.must_include("Origin: #{role_vars_path}:2:14\n")
    stderr.must_include("2 __ff_distro: >-\n")
    stderr.scan(/DEPRECATION WARNING\]: INJECT_FACTS_AS_VARS/).size.must_equal(1)
  end
end

# Jinja2 resolves the names a frame loads when the frame is ENTERED
# (compiler.py's enter_frame hoists the resolve() calls) and the
# deprecation tag fires when the tagged value is ACCESSED - so a fact read
# in a `{% for %}` body warns only when the loop really iterates and an
# uncalled macro's body warns never, while a root-frame read warns even
# when the render dies before its expression runs. bramford.apt-sources'
# sources.list.j2 reads `ansible_distribution_release` inside
# `{% for repo in apt_sources_repos %}` and, off Debian/Ubuntu hosts, the
# render dies on the undefined iterable at the loop header with the body
# frame never entered - real prints no block at the file (issue #1179,
# previously #1097, live-verified against 2.21.6).
describe "INJECT_FACTS_AS_VARS deprecation and a template's unentered frames" do
  private def run_template_file(template_text : String) : {String, String}
    dir = PluginSpecHelper.tmp_path("inject-facts-frames-#{Random::Secure.hex(4)}")
    FileUtils.mkdir_p(dir)
    template = File.join(dir, "t.j2")
    File.write(template, template_text)
    playbook = File.join(dir, "play.yml")
    File.write(playbook, <<-PLAYBOOK)
      - hosts: localhost
        connection: local
        gather_facts: true
        tasks:
          - name: render t.j2
            ansible.builtin.template:
              src: #{template}
              dest: #{File.join(dir, "out.txt")}
              mode: "0644"
      PLAYBOOK
    stdout = IO::Memory.new
    stderr = IO::Memory.new
    Process.run(BINARY, ["-i", "localhost,", playbook], output: stdout, error: stderr, chdir: dir)
    {stdout.to_s, stderr.to_s}
  end

  it "stays silent when the render dies at the loop header before its body" do
    stdout, stderr = run_template_file("{% for repo in apt_sources_repos %}\n" \
                                       "{% if repo != ansible_distribution_release %}x{% endif %}\n" \
                                       "{% endfor %}\n")

    stdout.must_include("'apt_sources_repos' is undefined")
    stderr.includes?("INJECT_FACTS_AS_VARS").must_equal(false)
  end

  it "stays silent for a for body that never iterates" do
    _stdout, stderr = run_template_file("{% for x in [] %}{{ ansible_distribution }}{% endfor %}ok\n")

    stderr.includes?("INJECT_FACTS_AS_VARS").must_equal(false)
  end

  it "warns for a for body the loop really enters" do
    _stdout, stderr = run_template_file("{% for x in ['a'] %}{{ ansible_distribution }}{% endfor %}ok\n")

    stderr.scan(/DEPRECATION WARNING\]: INJECT_FACTS_AS_VARS/).size.must_equal(1)
    stderr.must_include("Origin: ")
  end

  it "warns after a top-level set the render binds" do
    _stdout, stderr = run_template_file("{% set x = 1 %}{{ x }}" \
                                        "{% for i in ['a'] %}{{ ansible_distribution }}{% endfor %}ok\n")

    stderr.scan(/DEPRECATION WARNING\]: INJECT_FACTS_AS_VARS/).size.must_equal(1)
    stderr.must_include("Origin: ")
  end

  it "warns after a set a taken branch binds" do
    _stdout, stderr = run_template_file("{% if true %}{% set x = 1 %}{% endif %}{{ x }}" \
                                        "{% for i in ['a'] %}{{ ansible_distribution }}{% endfor %}ok\n")

    stderr.scan(/DEPRECATION WARNING\]: INJECT_FACTS_AS_VARS/).size.must_equal(1)
    stderr.must_include("Origin: ")
  end

  it "stays silent for a macro body the template never calls" do
    _stdout, stderr = run_template_file("{% macro m() %}{{ ansible_distribution }}{% endmacro %}ok\n")

    stderr.includes?("INJECT_FACTS_AS_VARS").must_equal(false)
  end

  it "stays silent for a loop inside a branch that never runs" do
    _stdout, stderr = run_template_file("{% if false %}{% for x in ['a'] %}{{ ansible_distribution }}{% endfor %}{% endif %}ok\n")

    stderr.includes?("INJECT_FACTS_AS_VARS").must_equal(false)
  end

  it "stays silent for a loop the render dies before reaching" do
    stdout, stderr = run_template_file("{{ totally_undefined_var }}{% for x in ['a'] %}{{ ansible_distribution }}{% endfor %}\n")

    stdout.must_include("'totally_undefined_var' is undefined")
    stderr.includes?("INJECT_FACTS_AS_VARS").must_equal(false)
  end

  it "warns for a root-frame read in a branch that never runs" do
    _stdout, stderr = run_template_file("{% if false %}{{ ansible_distribution }}{% endif %}ok\n")

    stderr.scan(/DEPRECATION WARNING\]: INJECT_FACTS_AS_VARS/).size.must_equal(1)
    stderr.must_include("Origin: ")
  end
end
