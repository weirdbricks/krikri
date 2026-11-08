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
  dir = PluginSpecHelper.tmp_path("fact-deprecation-#{Random::Secure.hex(4)}")
  FileUtils.mkdir_p(dir)
  playbook = File.join(dir, "play.yml")
  File.write(playbook, playbook_text)
  stdout = IO::Memory.new
  stderr = IO::Memory.new
  Process.run(BINARY, ["-i", "localhost,", playbook], output: stdout, error: stderr, chdir: dir)
  {stdout.to_s, stderr.to_s}
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

  it "stays silent for spellings real does not inject and for indirect reads" do
    # clean_facts drops `ansible_*_interpreter`, so that alias never warns
    # (live-verified against 2.21.6), and a variable whose OWN value names
    # the fact is tagged at its declaration in real - an Origin this
    # engine cannot place, so the read stays silent rather than
    # mis-attributing the warning to the template that merely uses the
    # variable.
    stdout, stderr = run(<<-PLAYBOOK)
      - hosts: localhost
        connection: local
        gather_facts: true
        vars:
          indirect_reader: "{{ ansible_os_family }}"
        tasks:
          - name: interpreter alias
            debug:
              msg: "{{ ansible_python_interpreter | default('none') }}"
          - name: indirect read
            debug:
              msg: "{{ indirect_reader }}"
      PLAYBOOK

    stdout.must_include("TASK [indirect read]")
    stderr.wont_include("INJECT_FACTS_AS_VARS")
  end
end
