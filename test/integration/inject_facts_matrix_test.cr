require "../minitest_helper"

# Trigger matrix for the INJECT_FACTS_AS_VARS deprecation class: ansible-core
# 2.21 tags every fact it ALSO injects at the top level as `ansible_<fact>`
# and prints the block the first time a templating operation reads one. WHICH
# operation reads it, and where its Origin points, depends on the placement of
# the read - so a fix for one placement kept missing another (issues #962,
# #1089, #1092, #1225, #1435, #1516, #1524, #1526, #1573).
#
# Every expected transcript below was byte-compared against the locally
# installed ansible-core 2.21.6 (the pinned parity target), captured the way
# bin/krikri-capture-case does it: `-i inventory.ini -c local` with
# the [local] host pinning ansible_connection/ansible_python_interpreter (the
# interpreter-discovery warning is on KNOWN_MISSING.md's unmatchable list),
# `ANSIBLE_NOCOLOR=1`, the fact-gathering env vars unset, and only the scratch
# directory normalized to `<WORK>`.
#
# The assertion is the WHOLE stderr transcript, so a cell that gains an extra
# block, loses one, reorders two, or moves an Origin by one column fails.
#
# Cells whose expected behaviour has NOT been verified against real ansible are
# listed at the bottom as commented-out pending rows naming what is unverified.
# Never invent an expected transcript for them.
private MATRIX_BINARY = File.expand_path("../../bin/krikri-playbook", __DIR__)

# One cell: the placement under test, the playbook (plus any role files, keyed
# by path under the scratch directory), the CLI flags, and real ansible's exact
# stderr for it.
private record InjectFactsCell,
  placement : String,
  playbook : String,
  files : Hash(String, String),
  flags : Array(String),
  expected : String

private INJECT_FACTS_DEPRECATION = "[DEPRECATION WARNING]: INJECT_FACTS_AS_VARS default to `True` is deprecated, top-level facts will not be auto injected after the change. This feature will be removed from ansible-core version 2.24.\n"
private INJECT_FACTS_HINT        = "[WARNING]: Deprecation warnings can be disabled by setting `deprecation_warnings=False` in ansible.cfg.\n"
private INJECT_FACTS_FOOTER      = "Use `ansible_facts[\"fact_name\"]` (no `ansible_` prefix) instead.\n\n"

private INJECT_FACTS_CELLS = {
  # 1. A task's `when:` clause: Origin at the clause value's first character.
  "task when: clause" => InjectFactsCell.new(
    placement: "task `when:` clause",
    playbook: <<-PLAYBOOK,
      - hosts: localhost
        connection: local
        gather_facts: true
        tasks:
          - name: gated by a top-level fact
            ansible.builtin.debug:
              msg: hi
            when: ansible_os_family | length > 0
      PLAYBOOK
    files: {} of String => String,
    flags: [] of String,
    expected: INJECT_FACTS_HINT + INJECT_FACTS_DEPRECATION +
              "Origin: <WORK>/playbook.yml:8:13\n\n" \
              "6       ansible.builtin.debug:\n" \
              "7         msg: hi\n" \
              "8       when: ansible_os_family | length > 0\n" \
              "              ^ column 13\n\n" + INJECT_FACTS_FOOTER,
  ),

  # 2. A task parameter value: Origin at the value token, inside the msg:.
  "task parameter value" => InjectFactsCell.new(
    placement: "task parameter value",
    playbook: <<-PLAYBOOK,
      - hosts: localhost
        connection: local
        gather_facts: true
        tasks:
          - name: message naming a fact
            ansible.builtin.debug:
              msg: "family is {{ ansible_os_family }}"
      PLAYBOOK
    files: {} of String => String,
    flags: [] of String,
    expected: INJECT_FACTS_HINT + INJECT_FACTS_DEPRECATION +
              "Origin: <WORK>/playbook.yml:7:14\n\n" \
              "5     - name: message naming a fact\n" \
              "6       ansible.builtin.debug:\n" \
              "7         msg: \"family is {{ ansible_os_family }}\"\n" \
              "               ^ column 14\n\n" + INJECT_FACTS_FOOTER,
  ),

  # 3. A role default CONSUMED by a task: the read belongs to the default's own
  # value token, in the role's defaults/main.yml, not to the consuming task.
  # (The #1573 corpus case is the negative half: a default nothing consumes
  # must print nothing.)
  "role defaults value" => InjectFactsCell.new(
    placement: "role `defaults/main.yml` value consumed by a task",
    playbook: <<-PLAYBOOK,
      - hosts: localhost
        connection: local
        gather_facts: true
        roles:
          - rdef
      PLAYBOOK
    files: {
      "roles/rdef/defaults/main.yml" => <<-YAML,
        ---
        distribution_family: "{{ ansible_os_family }}"
        YAML
      "roles/rdef/tasks/main.yml" => <<-YAML,
        ---
        - name: consume the role default
          ansible.builtin.debug:
            msg: "{{ distribution_family }}"
        YAML
    },
    flags: [] of String,
    expected: INJECT_FACTS_HINT + INJECT_FACTS_DEPRECATION +
              "Origin: <WORK>/roles/rdef/defaults/main.yml:2:22\n\n" \
              "1 ---\n" \
              "2 distribution_family: \"{{ ansible_os_family }}\"\n" \
              "                       ^ column 22\n\n" + INJECT_FACTS_FOOTER,
  ),

  # 4. A role `meta/argument_specs.yml` default: real templates the whole spec
  # while finalizing the synthesized validation task's args (issue #1435).
  "argument_specs default" => InjectFactsCell.new(
    placement: "role `meta/argument_specs.yml` default",
    playbook: <<-PLAYBOOK,
      - hosts: localhost
        connection: local
        gather_facts: true
        roles:
          - rspec
      PLAYBOOK
    files: {
      "roles/rspec/meta/argument_specs.yml" => <<-YAML,
        ---
        argument_specs:
          main:
            short_description: matrix cell
            options:
              spec_domain:
                type: str
                default: "{{ ansible_os_family }}"
        YAML
      "roles/rspec/defaults/main.yml" => "---\n",
      "roles/rspec/tasks/main.yml"    => <<-YAML,
        ---
        - name: consume the spec default
          ansible.builtin.debug:
            msg: "{{ spec_domain }}"
        YAML
    },
    flags: [] of String,
    expected: INJECT_FACTS_HINT + INJECT_FACTS_DEPRECATION +
              "Origin: <WORK>/roles/rspec/meta/argument_specs.yml:8:18\n\n" \
              "6       spec_domain:\n" \
              "7         type: str\n" \
              "8         default: \"{{ ansible_os_family }}\"\n" \
              "                   ^ column 18\n\n" + INJECT_FACTS_FOOTER,
  ),

  # 5. An `include_tasks:` carrying the fact-gated `when:` prints NOTHING:
  # real hands the conditional to the included tasks (which override it per
  # task) and never templates it on the include task itself. A negative cell,
  # so a "fix" that starts warning here fails too.
  "include_tasks inherited when" => InjectFactsCell.new(
    placement: "`include_tasks:`-inherited `when:` clause (negative)",
    playbook: <<-PLAYBOOK,
      - hosts: localhost
        connection: local
        gather_facts: true
        tasks:
          - name: include with a fact gate
            ansible.builtin.include_tasks: inc/one.yml
            when: ansible_os_family | length > 0
      PLAYBOOK
    files: {
      "inc/one.yml" => <<-YAML,
        ---
        - name: included task
          ansible.builtin.debug:
            msg: in
        YAML
    },
    flags: [] of String,
    expected: "",
  ),

  # 6. The same clause on an `import_tasks:` (static import) DOES warn, Origin'd
  # at the import's own `when:` value, because the clause is copied onto every
  # imported task and templated with the playbook's own source span.
  "import_tasks inherited when" => InjectFactsCell.new(
    placement: "`import_tasks:`-inherited `when:` clause",
    playbook: <<-PLAYBOOK,
      - hosts: localhost
        connection: local
        gather_facts: true
        tasks:
          - name: import with a fact gate
            ansible.builtin.import_tasks: inc/one.yml
            when: ansible_os_family | length > 0
      PLAYBOOK
    files: {
      "inc/one.yml" => <<-YAML,
        ---
        - name: included task
          ansible.builtin.debug:
            msg: in
        YAML
    },
    flags: [] of String,
    expected: INJECT_FACTS_HINT + INJECT_FACTS_DEPRECATION +
              "Origin: <WORK>/playbook.yml:7:13\n\n" \
              "5     - name: import with a fact gate\n" \
              "6       ansible.builtin.import_tasks: inc/one.yml\n" \
              "7       when: ansible_os_family | length > 0\n" \
              "              ^ column 13\n\n" + INJECT_FACTS_FOOTER,
  ),

  # 7. A loop source: three separate reads, in this order - the list leaf that
  # spelled the fact, the consuming param (item is already a plain string, but
  # the param still templates), and the item label, whose Origin real cannot
  # place (`<unknown>`) and which real prefixes "While processing 'item': ".
  "loop source" => InjectFactsCell.new(
    placement: "loop source",
    playbook: <<-PLAYBOOK,
      - hosts: localhost
        connection: local
        gather_facts: true
        vars:
          facts_list:
            - "{{ ansible_os_family }}"
        tasks:
          - name: loop over a fact-bearing list
            ansible.builtin.debug:
              msg: "{{ item }}"
            loop: "{{ facts_list }}"
      PLAYBOOK
    files: {} of String => String,
    flags: [] of String,
    expected: INJECT_FACTS_HINT + INJECT_FACTS_DEPRECATION +
              "Origin: <WORK>/playbook.yml:6:9\n\n" \
              "4   vars:\n" \
              "5     facts_list:\n" \
              "6       - \"{{ ansible_os_family }}\"\n" \
              "          ^ column 9\n\n" + INJECT_FACTS_FOOTER +
              INJECT_FACTS_DEPRECATION +
              "Origin: <WORK>/playbook.yml:10:14\n\n" \
              " 8     - name: loop over a fact-bearing list\n" \
              " 9       ansible.builtin.debug:\n" \
              "10         msg: \"{{ item }}\"\n" \
              "                ^ column 14\n\n" + INJECT_FACTS_FOOTER +
              "[DEPRECATION WARNING]: While processing 'item': INJECT_FACTS_AS_VARS default to `True` is deprecated, top-level facts will not be auto injected after the change. This feature will be removed from ansible-core version 2.24.\n" \
              "Origin: <unknown>\n\nitem\n\n" + INJECT_FACTS_FOOTER,
  ),

  # 8. --check mode: the same when: clause, same block, same Origin.
  "--check mode" => InjectFactsCell.new(
    placement: "`--check` mode (`when:` clause)",
    playbook: <<-PLAYBOOK,
      - hosts: localhost
        connection: local
        gather_facts: true
        tasks:
          - name: gated by a top-level fact
            ansible.builtin.debug:
              msg: hi
            when: ansible_os_family | length > 0
      PLAYBOOK
    files: {} of String => String,
    flags: ["--check"],
    expected: INJECT_FACTS_HINT + INJECT_FACTS_DEPRECATION +
              "Origin: <WORK>/playbook.yml:8:13\n\n" \
              "6       ansible.builtin.debug:\n" \
              "7         msg: hi\n" \
              "8       when: ansible_os_family | length > 0\n" \
              "              ^ column 13\n\n" + INJECT_FACTS_FOOTER,
  ),

  # 9. A task's `environment:` entry: real templates the dict's leaves, so the
  # read is Origin'd at that entry's own value token (issue #1526).
  "task environment entry" => InjectFactsCell.new(
    placement: "task `environment:` entry",
    playbook: <<-PLAYBOOK,
      - hosts: localhost
        connection: local
        gather_facts: true
        tasks:
          - name: command with a fact-bearing environment entry
            ansible.builtin.command:
              cmd: "true"
            environment:
              PATH: "{{ ansible_env.PATH }}:/usr/local/bin"
      PLAYBOOK
    files: {} of String => String,
    flags: ["--check"],
    expected: INJECT_FACTS_HINT + INJECT_FACTS_DEPRECATION +
              "Origin: <WORK>/playbook.yml:9:15\n\n" \
              "7         cmd: \"true\"\n" \
              "8       environment:\n" \
              "9         PATH: \"{{ ansible_env.PATH }}:/usr/local/bin\"\n" \
              "                ^ column 15\n\n" + INJECT_FACTS_FOOTER,
  ),

  # 10. A role `vars/main.yml` value consumed by a task: same rule as defaults
  # (the read belongs to the value's own token), and role vars are templated
  # when the consuming task renders - not at load.
  "role vars value" => InjectFactsCell.new(
    placement: "role `vars/main.yml` value consumed by a task",
    playbook: <<-PLAYBOOK,
      - hosts: localhost
        connection: local
        gather_facts: true
        roles:
          - rvars
      PLAYBOOK
    files: {
      "roles/rvars/vars/main.yml" => <<-YAML,
        ---
        role_var_family: "{{ ansible_os_family }}"
        YAML
      "roles/rvars/tasks/main.yml" => <<-YAML,
        ---
        - name: consume the role var
          ansible.builtin.debug:
            msg: "{{ role_var_family }}"
        YAML
    },
    flags: [] of String,
    expected: INJECT_FACTS_HINT + INJECT_FACTS_DEPRECATION +
              "Origin: <WORK>/roles/rvars/vars/main.yml:2:18\n\n" \
              "1 ---\n" \
              "2 role_var_family: \"{{ ansible_os_family }}\"\n" \
              "                   ^ column 18\n\n" + INJECT_FACTS_FOOTER,
  ),
}

private def write_inject_facts_cell(dir : String, cell : InjectFactsCell) : Nil
  File.write(File.join(dir, "playbook.yml"), cell.playbook)
  File.write(File.join(dir, "inventory.ini"),
    "[local]\nlocalhost ansible_connection=local ansible_python_interpreter=/usr/bin/python3\n")
  cell.files.each do |path, content|
    full = File.join(dir, path)
    FileUtils.mkdir_p(File.dirname(full))
    File.write(full, content)
  end
end

# Run krikri over one matrix cell and return its normalized stderr - the whole
# transcript of the deprecation surface, which is what each cell pins.
private def run_inject_facts_cell(placement : String) : String
  cell = INJECT_FACTS_CELLS[placement]
  dir = PluginSpecHelper.tmp_path("inject-facts-matrix-#{Random::Secure.hex(4)}")
  FileUtils.mkdir_p(File.join(dir, "home"))
  write_inject_facts_cell(dir, cell)

  stdout = IO::Memory.new
  stderr = IO::Memory.new
  Process.run(
    MATRIX_BINARY,
    ["-i", "inventory.ini", "-c", "local"] + cell.flags + ["playbook.yml"],
    output: stdout,
    error: stderr,
    chdir: dir,
    env: {
      "ANSIBLE_NOCOLOR"                 => "1",
      "HOME"                            => File.join(dir, "home"),
      "ANSIBLE_GATHERING"               => nil,
      "ANSIBLE_CACHE_PLUGIN"            => nil,
      "ANSIBLE_CACHE_PLUGIN_CONNECTION" => nil,
    },
  )
  stderr.to_s.gsub(dir, "<WORK>")
end

describe "INJECT_FACTS_AS_VARS trigger matrix" do
  it "warns for a task when: clause at the clause value token" do
    run_inject_facts_cell("task when: clause").must_equal(INJECT_FACTS_CELLS["task when: clause"].expected)
  end

  it "warns for a task parameter value at the value token" do
    run_inject_facts_cell("task parameter value").must_equal(INJECT_FACTS_CELLS["task parameter value"].expected)
  end

  it "attributes a consumed role default to the defaults file" do
    run_inject_facts_cell("role defaults value").must_equal(INJECT_FACTS_CELLS["role defaults value"].expected)
  end

  it "attributes an argument_specs default to the spec file" do
    run_inject_facts_cell("argument_specs default").must_equal(INJECT_FACTS_CELLS["argument_specs default"].expected)
  end

  it "stays silent for an include_tasks-inherited when: clause" do
    run_inject_facts_cell("include_tasks inherited when").must_equal("")
  end

  it "warns for an import_tasks-inherited when: clause at the import" do
    run_inject_facts_cell("import_tasks inherited when").must_equal(INJECT_FACTS_CELLS["import_tasks inherited when"].expected)
  end

  it "warns three times for a loop source, the param and the item label" do
    run_inject_facts_cell("loop source").must_equal(INJECT_FACTS_CELLS["loop source"].expected)
  end

  it "warns identically in --check mode" do
    run_inject_facts_cell("--check mode").must_equal(INJECT_FACTS_CELLS["--check mode"].expected)
  end

  it "warns for a task environment: entry at the entry value token" do
    run_inject_facts_cell("task environment entry").must_equal(INJECT_FACTS_CELLS["task environment entry"].expected)
  end

  it "attributes a consumed role var to the role's vars file" do
    run_inject_facts_cell("role vars value").must_equal(INJECT_FACTS_CELLS["role vars value"].expected)
  end

  # ── pending cells: expected behaviour NOT verified against real ansible ──
  #
  # Each row below is a placement of the same class that nobody has
  # byte-compared against ansible-core 2.21.6 yet. They are deliberately not
  # asserted: inventing an Origin or a block count here would pin a guess.
  #
  # - `template:` action: a fact read inside the .j2 BODY. Real reports the
  #   Origin against the template file's own line/column (or `<unknown>` when
  #   the value came from a variable), and the file is rendered on the
  #   controller - unverified for 2.21.6, so no transcript is recorded.
  #   it "warns for a fact read inside a template: body" do ... end
  #
  # - `block:`-level `when:` inherited by several tasks: whether real warns
  #   once (the block's clause templated once) or once per inherited task, and
  #   which Origin it keeps, is unverified.
  #   it "warns once for a block-level when: clause" do ... end
  #
  # - `hostvars[...]` / `ansible_facts[...]`-mediated reads of the same fact:
  #   these must NOT warn (they are the migration target), but that is
  #   unverified for every placement above except the two the existing
  #   inject_facts_deprecation_test.cr cases cover.
  #   it "stays silent for an ansible_facts[] read" do ... end
end
