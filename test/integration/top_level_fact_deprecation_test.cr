require "../minitest_helper"

# ansible-core 2.21 deprecates reading a gathered fact's top-level
# `ansible_`-prefixed spelling (INJECT_FACTS_AS_VARS defaulting to True) -
# issue #957, AAROC.AAROC_regional-apel-server: the role's
# AAROC.certificates dependency gates two blocks on
# `when: ansible_os_family == 'RedHat'` / `== 'Debian'`, and
# ansible-playbook printed one [DEPRECATION WARNING] block per clause
# where this engine printed none at all.
#
# Every expected shape below was verified against the locally-installed
# ansible-core 2.21.6 (live-verified: the Origin is the clause VALUE
# token with the two context lines above it and a caret under the column,
# and one warning per distinct Origin per run - two children evaluating
# the same inherited block condition still warn once).
private PROJECT_ROOT          = File.expand_path("../..", __DIR__)
private BINARY                = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private FACT_DEPRECATION_TEXT = "INJECT_FACTS_AS_VARS default to `True` is deprecated, top-level facts will not be auto injected after the change. This feature will be removed from ansible-core version 2.24."

private def run(playbook_text : String) : {String, String}
  stdout, stderr, _dir = run_files({"play.yml" => playbook_text})
  {stdout, stderr}
end

# Writes *files* (playbook text keyed by path relative to a fresh scratch
# dir, roles included; the playbook itself is always "play.yml") and runs
# the binary there. Returns the scratch dir too, so a spec can assert the
# absolute Origins the engine prints.
private def run_files(files : Hash(String, String)) : {String, String, String}
  dir = PluginSpecHelper.tmp_path("fact-deprecation-#{Random::Secure.hex(4)}")
  FileUtils.mkdir_p(dir)
  files.each do |relative, content|
    path = File.join(dir, relative)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, content)
  end
  stdout = IO::Memory.new
  stderr = IO::Memory.new
  Process.run(BINARY, ["-i", "localhost,", File.join(dir, "play.yml")], output: stdout, error: stderr, chdir: dir)
  {stdout.to_s, stderr.to_s, dir}
end

describe "INJECT_FACTS_AS_VARS deprecation" do
  it "attributes a task's when: clause read to the clause value token" do
    stdout, stderr = run(<<-PLAYBOOK)
      - hosts: localhost
        connection: local
        gather_facts: true
        tasks:
          - name: debian only
            debug:
              msg: hi
            when: ansible_os_family == 'Debian'
      PLAYBOOK

    stdout.must_match(/TASK \[debian only\]/)
    stderr.must_include("[WARNING]: Deprecation warnings can be disabled by setting `deprecation_warnings=False` in ansible.cfg.")
    stderr.must_include("[DEPRECATION WARNING]: #{FACT_DEPRECATION_TEXT}\n")
    # The Origin block: the when: VALUE token - `ansible_os_family` starts
    # at column 13 of line 8 - with the two context lines above it and the
    # caret under that column.
    stderr.must_include("Origin: ")
    stderr.must_include(":8:13\n")
    stderr.must_include("6       debug:\n")
    stderr.must_include("7         msg: hi\n")
    stderr.must_include("8       when: ansible_os_family == 'Debian'\n")
    stderr.must_include("              ^ column 13")
    stderr.must_include("Use `ansible_facts[\"fact_name\"]` (no `ansible_` prefix) instead.")
  end

  it "warns once per distinct block when: Origin" do
    # The role that reported this gates a whole `block:` - so the clause is
    # the BLOCK's, evaluated by each of its children (or re-evaluated by
    # the skip path for a block that does not run). Real prints one
    # warning per distinct Origin, though both children of the RedHat
    # block resolve the same inherited condition.
    stdout, stderr = run(<<-PLAYBOOK)
      - hosts: localhost
        connection: local
        gather_facts: true
        tasks:
          - block:
              - name: redhat one
                debug:
                  msg: rh1
              - name: redhat two
                debug:
                  msg: rh2
            when: ansible_os_family == 'RedHat'
          - block:
              - name: debian one
                debug:
                  msg: deb1
            when: ansible_os_family == 'Debian'
      PLAYBOOK

    stdout.must_include("TASK [redhat one]")
    stdout.must_include("TASK [redhat two]")
    stdout.must_include("TASK [debian one]")
    stderr.must_include("Origin: ")
    stderr.must_include(":12:13\n")
    stderr.must_include("10           debug:\n")
    stderr.must_include("12       when: ansible_os_family == 'RedHat'\n")
    stderr.must_include(":17:13\n")
    stderr.must_include("17       when: ansible_os_family == 'Debian'\n")
    stderr.scan(/DEPRECATION WARNING\]: #{Regex.escape(FACT_DEPRECATION_TEXT)}/).size.must_equal(2)
    stderr.scan(/:12:13/).size.must_equal(1)
    stderr.scan(/:17:13/).size.must_equal(1)
    # In the blocks' own order, the way ansible interleaves them with the
    # task output.
    (stderr.index!(":12:13") < stderr.index!(":17:13")).must_equal(true)
  end

  it "stays silent for spellings real does not inject" do
    # clean_facts drops `ansible_*_interpreter`, so that alias never warns
    # even though this engine's own fact store holds it for a local
    # connection (live-verified against 2.21.6).
    stdout, stderr = run(<<-PLAYBOOK)
      - hosts: localhost
        connection: local
        gather_facts: true
        tasks:
          - name: interpreter alias
            debug:
              msg: "{{ ansible_python_interpreter | default('none') }}"
      PLAYBOOK

    stdout.must_include("TASK [interpreter alias]")
    stderr.wont_include("INJECT_FACTS_AS_VARS")
  end

  it "attributes a read reached through a variable's value to that value's declaration" do
    # Issue #961, adzumatokaku.docker_role: nothing in the task's own text
    # names a fact - the role's defaults/main.yml value does
    # (`docker_yum_repo_url: https://...{{ ansible_distribution }}...`) and
    # the task only reads that variable. Real templates the VALUE lazily
    # and tags the warning with the value's own declaring position, the
    # opening quote of the defaults/vars scalar (live-verified against
    # 2.21.6: line 5, column 22 for the playbook below), so the read must
    # not stay silent.
    stdout, stderr, dir = run_files({"play.yml" => <<-PLAYBOOK})
      - hosts: localhost
        connection: local
        gather_facts: true
        vars:
          indirect_reader: "{{ ansible_os_family }}"
        tasks:
          - name: indirect read
            debug:
              msg: "{{ indirect_reader }}"
      PLAYBOOK

    stdout.must_include("TASK [indirect read]")
    stderr.must_include("[DEPRECATION WARNING]: #{FACT_DEPRECATION_TEXT}\n")
    stderr.must_include("Origin: #{File.join(dir, "play.yml")}:5:22\n")
    stderr.must_include("5     indirect_reader: \"{{ ansible_os_family }}\"\n")
    stderr.must_include("^ column 22")
    # One block total: the read belongs to the value, not to the param that
    # rendered the variable.
    stderr.scan(/DEPRECATION WARNING\]: #{Regex.escape(FACT_DEPRECATION_TEXT)}/).size.must_equal(1)
  end

  it "attributes a role default's fact read to the defaults file, not the task" do
    # The shape issue #961 was filed for, reproduced from
    # adzumatokaku.docker_role: a role default naming ansible_distribution,
    # read by a task that mentions no fact at all. The Origin is the
    # defaults file's own line and value column (live-verified against
    # 2.21.6: 13:22 for this fixture).
    stdout, stderr, dir = run_files({
      "play.yml" => <<-PLAYBOOK,
      - hosts: localhost
        connection: local
        gather_facts: true
        roles:
          - rdemo
      PLAYBOOK
      "roles/rdemo/defaults/main.yml" => <<-YAML,
        ---
        # Service options.
        docker_service_state: started

        # For RedHat/CentOS/Fedora.
        docker_yum_repo_url: https://download.docker.com/linux/{{ (ansible_distribution == "Fedora") | ternary("fedora","centos") }}/docker-ce.repo
        YAML
      "roles/rdemo/tasks/main.yml" => <<-YAML,
        ---
        - name: show repo url
          ansible.builtin.debug:
            msg: "{{ docker_yum_repo_url }}"
        YAML
    })

    defaults = File.join(dir, "roles", "rdemo", "defaults", "main.yml")
    stdout.must_include("TASK [rdemo : show repo url]")
    stderr.must_include("[DEPRECATION WARNING]: #{FACT_DEPRECATION_TEXT}\n")
    stderr.must_include("Origin: #{defaults}:6:22\n")
    stderr.must_include("^ column 22")
    stdout.must_include("docker-ce.repo")
  end

  it "attributes a template file's indirect read to the value, not the file" do
    # A `.j2` that reads a variable whose own value names a fact: real's
    # Origin is the value's declaration, not the template file (different
    # from a DIRECT `{{ ansible_os_family }}` in a .j2, whose Origin is the
    # file alone) - live-verified against 2.21.6.
    stdout, stderr, dir = run_files({
      "play.yml" => <<-PLAYBOOK,
        - hosts: localhost
          connection: local
          gather_facts: true
          vars:
            repo_url: "https://x/{{ ansible_distribution }}"
          tasks:
            - name: render file
              ansible.builtin.template:
                src: t.j2
                dest: out.txt
        PLAYBOOK
      "t.j2" => "url={{ repo_url }}\n",
    })

    stdout.must_include("TASK [render file]")
    stderr.must_include("Origin: #{File.join(dir, "play.yml")}:5:15\n")
    stderr.wont_include("Origin: #{File.join(dir, "t.j2")}")
  end

  it "prints one block per templating operation, at the first fact it read" do
    # Issue #964, badsectorlabs.ludus_emux via geerlingguy.docker: one task
    # param that pulls in several defaults each naming a different fact.
    # Real keeps the deprecate tag's FIRST access per render (live-verified
    # against 2.21.6: task 1 prints only os_name's declaration), so the
    # second value's Origin must not add its own block; a later task that
    # reads that second value alone gets it, at its own site.
    stdout, stderr, dir = run_files({"play.yml" => <<-PLAYBOOK})
      - hosts: localhost
        connection: local
        gather_facts: true
        vars:
          os_name: "{{ ansible_os_family }}"
          os_dist: "{{ ansible_distribution }}"
        tasks:
          - name: both vars at once
            debug:
              msg: "{{ os_name }} {{ os_dist }}"
          - name: the second var alone
            debug:
              msg: "{{ os_dist }}"
      PLAYBOOK

    stdout.must_include("TASK [both vars at once]")
    stdout.must_include("TASK [the second var alone]")
    stderr.scan(/DEPRECATION WARNING\]: #{Regex.escape(FACT_DEPRECATION_TEXT)}/).size.must_equal(2)
    stderr.must_include("Origin: #{File.join(dir, "play.yml")}:5:14\n")
    stderr.must_include("Origin: #{File.join(dir, "play.yml")}:6:14\n")
    stderr.scan(":5:14\n").size.must_equal(1)
    stderr.scan(":6:14\n").size.must_equal(1)
    # In the tasks' own order, the way ansible interleaves them.
    (stderr.index!(":5:14") < stderr.index!(":6:14")).must_equal(true)
  end
end
