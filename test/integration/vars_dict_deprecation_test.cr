require "../minitest_helper"

# ansible-core 2.21 deprecates the internal `vars` dictionary
# (vars/manager.py tags the `vars` magic dict and every value inside it
# with _DEPRECATE_VARS): any template READ of the dict or one of its
# entries prints one [DEPRECATION WARNING] block - `Use the `vars` and
# `varnames` lookups instead.` - Origin'd at the reading site: the
# template file path alone for a .j2 read, the value token for a task
# param or when: clause, the DECLARATION of a variable whose own value
# reads the dict for an indirect read. One block per templating operation
# (first access wins) and one per distinct Origin per run. Issue #1028,
# ome.debug_dumpallvars: its templates/dumpall.j2 `{{ vars |
# default('<undefined>') | to_nice_json }}` printed the block under
# ansible-playbook and nothing under krikri-playbook. Every expected shape
# below was verified against the locally-installed ansible-core 2.21.6.
private PROJECT_ROOT               = File.expand_path("../..", __DIR__)
private BINARY                     = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private VARS_DICT_DEPRECATION_TEXT = "The internal \"vars\" dictionary is deprecated. This feature will be removed from ansible-core version 2.24."
private FACT_DEPRECATION_TEXT      = "INJECT_FACTS_AS_VARS default to `True` is deprecated, top-level facts will not be auto injected after the change. This feature will be removed from ansible-core version 2.24."

private def run(playbook_text : String) : {String, String}
  stdout, stderr, _dir = run_files({"play.yml" => playbook_text})
  {stdout, stderr}
end

private def run_files(files : Hash(String, String)) : {String, String, String}
  dir = PluginSpecHelper.tmp_path("vars-dict-deprecation-#{Random::Secure.hex(4)}")
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

describe "internal vars dictionary deprecation" do
  it "warns at the template file when a .j2 reads the vars dict" do
    # The issue #1028 shape: a template task rendering a dumpall-style
    # .j2 that reads `vars`. Origin is the template file alone, no
    # line/column.
    stdout, stderr, dir = run_files({
      "play.yml" => <<-PLAYBOOK,
        - hosts: localhost
          connection: local
          gather_facts: false
          tasks:
            - name: dump all vars
              ansible.builtin.template:
                src: t.j2
                dest: out.txt
        PLAYBOOK
      "t.j2" => "{{ vars | default('<undefined>') | to_nice_json }}\n",
    })

    stdout.must_include("TASK [dump all vars]")
    stderr.must_include("[WARNING]: Deprecation warnings can be disabled by setting `deprecation_warnings=False` in ansible.cfg.")
    stderr.must_include("[DEPRECATION WARNING]: #{VARS_DICT_DEPRECATION_TEXT}\n")
    stderr.must_include("Origin: #{File.join(dir, "t.j2")}\n")
    stderr.wont_include("^ column")
    stderr.must_include("Use the `vars` and `varnames` lookups instead.")
    stderr.scan(/DEPRECATION WARNING\]: #{Regex.escape(VARS_DICT_DEPRECATION_TEXT)}/).size.must_equal(1)
  end

  it "prints one block for several reads inside one template" do
    # Real keeps the deprecate tag's first access per templating
    # operation: two `vars` reads in one template print one block.
    _stdout, stderr, dir = run_files({
      "play.yml" => <<-PLAYBOOK,
        - hosts: localhost
          connection: local
          gather_facts: false
          tasks:
            - name: two reads
              ansible.builtin.template:
                src: t.j2
                dest: out.txt
        PLAYBOOK
      "t.j2" => "{{ vars | length }}\n{{ vars | length }}\n",
    })

    stderr.must_include("Origin: #{File.join(dir, "t.j2")}\n")
    stderr.scan(/DEPRECATION WARNING\]: #{Regex.escape(VARS_DICT_DEPRECATION_TEXT)}/).size.must_equal(1)
  end

  it "prints once when the same template renders again" do
    # The display dedups the whole formatted block per Origin, so a
    # second task rendering the same file adds no second warning.
    _stdout, stderr, dir = run_files({
      "play.yml" => <<-PLAYBOOK,
        - hosts: localhost
          connection: local
          gather_facts: false
          tasks:
            - name: first render
              ansible.builtin.template:
                src: t.j2
                dest: out1.txt
            - name: second render
              ansible.builtin.template:
                src: t.j2
                dest: out2.txt
        PLAYBOOK
      "t.j2" => "{{ vars | length }}\n",
    })

    count = stderr.scan(/DEPRECATION WARNING\]: #{Regex.escape(VARS_DICT_DEPRECATION_TEXT)}/).size
    count.must_equal(1)
    stderr.must_include("Origin: #{File.join(dir, "t.j2")}\n")
  end

  it "warns at the value token for a task param read" do
    stdout, stderr = run(<<-PLAYBOOK)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: param read
            debug:
              msg: "{{ vars | length }}"
      PLAYBOOK

    stdout.must_include("TASK [param read]")
    stderr.must_include("[DEPRECATION WARNING]: #{VARS_DICT_DEPRECATION_TEXT}\n")
    stderr.must_include(":7:14\n")
    stderr.must_include("7         msg: \"{{ vars | length }}\"\n")
    stderr.must_include(" " * 15 + "^ column 14")
    stderr.must_include("Use the `vars` and `varnames` lookups instead.")
    stderr.scan(/DEPRECATION WARNING\]: #{Regex.escape(VARS_DICT_DEPRECATION_TEXT)}/).size.must_equal(1)
  end

  it "attributes an indirect read to the value's declaration" do
    # A template or param that only reads a variable whose own value reads
    # the dict: real templates the value lazily and Origin's the value's
    # own declaration (the opening quote of the scalar), not the reader.
    _stdout, stderr = run(<<-PLAYBOOK)
      - hosts: localhost
        connection: local
        gather_facts: false
        vars:
          d1: "{{ vars.playbook_dir }}"
        tasks:
          - name: indirect read
            debug:
              msg: "{{ d1 }}"
      PLAYBOOK

    stderr.must_include("[DEPRECATION WARNING]: #{VARS_DICT_DEPRECATION_TEXT}\n")
    stderr.must_include(":5:9\n")
    stderr.must_include("5     d1: \"{{ vars.playbook_dir }}\"\n")
    stderr.must_include(" " * 10 + "^ column 9")
    stderr.scan(/DEPRECATION WARNING\]: #{Regex.escape(VARS_DICT_DEPRECATION_TEXT)}/).size.must_equal(1)
  end

  it "prints one block at the first value when two values name the dict" do
    # Both values' reads belong to the one param's templating operation,
    # so the first access's Origin is the only block (live-verified
    # against 2.21.6).
    _stdout, stderr = run(<<-PLAYBOOK)
      - hosts: localhost
        connection: local
        gather_facts: false
        vars:
          d1: "{{ vars.playbook_dir }}"
          d2: "{{ vars.ansible_version | default('x') }}"
        tasks:
          - name: both values at once
            debug:
              msg: "{{ d1 }}|{{ d2 }}"
      PLAYBOOK

    stderr.scan(/DEPRECATION WARNING\]: #{Regex.escape(VARS_DICT_DEPRECATION_TEXT)}/).size.must_equal(1)
    stderr.must_include(":5:9\n")
    stderr.wont_include(":6:9\n")
  end

  it "replays a task vars: value's read at the consuming render" do
    # A task `vars:` value renders eagerly at vars-context build, before
    # any rendering site exists - ansible-core templates it lazily at the
    # render that CONSUMES the value, so the block belongs to that
    # operation and Origin's the value's own declaration (the same replay
    # the INJECT_FACTS_AS_VARS readings take; live-verified against
    # 2.21.6).
    stdout, stderr = run(<<-PLAYBOOK)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: consume the eager value
            vars:
              myvar: "{{ vars.playbook_dir }}"
            debug:
              msg: "{{ myvar }}"
      PLAYBOOK

    stdout.must_include("TASK [consume the eager value]")
    stdout.must_include("/tmp")
    stderr.must_include("[DEPRECATION WARNING]: #{VARS_DICT_DEPRECATION_TEXT}\n")
    stderr.must_include(":7:16\n")
    stderr.must_include("7         myvar: \"{{ vars.playbook_dir }}\"\n")
    stderr.must_include(" " * 17 + "^ column 16")
    stderr.scan(/DEPRECATION WARNING\]: #{Regex.escape(VARS_DICT_DEPRECATION_TEXT)}/).size.must_equal(1)
  end

  it "stays silent for a value the template never reads" do
    # ansible templates a variable's value lazily at its USE: a `vars`
    # read inside a value the rendering template never touches prints
    # nothing (live-verified against 2.21.6), so the scope pre-render's
    # eager re-render must not warn for it.
    stdout, stderr = run_files({
      "play.yml" => <<-PLAYBOOK,
        - hosts: localhost
          connection: local
          gather_facts: false
          vars:
            unused: "{{ vars.playbook_dir }}"
          tasks:
            - name: render clean
              ansible.builtin.template:
                src: t.j2
                dest: out.txt
        PLAYBOOK
      "t.j2" => "nothing here\n",
    })

    stdout.must_include("TASK [render clean]")
    stderr.wont_include("[DEPRECATION WARNING]")
    stderr.wont_include("Deprecation warnings can be disabled")
  end

  it "warns at the when: token for a whole is-defined test" do
    # `is defined` is answered leniently without ever resolving the name,
    # so the read never reaches the substitutor - the same static-scan
    # gap the INJECT_FACTS_AS_VARS read has (live-verified against
    # 2.21.6: the block Origin's the when: value token).
    stdout, stderr = run(<<-PLAYBOOK)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: bare defined when
            debug:
              msg: "a"
            when: vars is defined
      PLAYBOOK

    stdout.must_include("TASK [bare defined when]")
    stderr.must_include("[DEPRECATION WARNING]: #{VARS_DICT_DEPRECATION_TEXT}\n")
    stderr.must_include(":8:13\n")
    stderr.must_include("8       when: vars is defined\n")
    stderr.must_include(" " * 14 + "^ column 13")
    stderr.scan(/DEPRECATION WARNING\]: #{Regex.escape(VARS_DICT_DEPRECATION_TEXT)}/).size.must_equal(1)
  end

  it "warns at the block when: token for a skipped block's is-defined test" do
    # A skipped block's when: is still a real evaluation in ansible -
    # every child's "skipping" line carries its deprecation, at the
    # BLOCK's own when: value token (live-verified against 2.21.6).
    stdout, stderr = run(<<-PLAYBOOK)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: skipped block
            when: vars.absent_marker is defined
            block:
              - name: child of skipped block
                debug:
                  msg: "b"
      PLAYBOOK

    stdout.must_include("TASK [child of skipped block]")
    stderr.must_include("[DEPRECATION WARNING]: #{VARS_DICT_DEPRECATION_TEXT}\n")
    stderr.must_include(":6:13\n")
    stderr.scan(/DEPRECATION WARNING\]: #{Regex.escape(VARS_DICT_DEPRECATION_TEXT)}/).size.must_equal(1)
  end

  it "warns at the that: item token for an assert read" do
    # assert:'s `that:` items evaluate inside the action plugin with no
    # templated-param site on the fiber, so the read is detected on the
    # raw item text and Origin'd at the item's own scalar position
    # (live-verified against 2.21.6).
    stdout, stderr = run(<<-PLAYBOOK)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: assert that read
            assert:
              that:
                - vars is defined
      PLAYBOOK

    stdout.must_include("TASK [assert that read]")
    stderr.must_include("[DEPRECATION WARNING]: #{VARS_DICT_DEPRECATION_TEXT}\n")
    stderr.must_include(":8:13\n")
    stderr.scan(/DEPRECATION WARNING\]: #{Regex.escape(VARS_DICT_DEPRECATION_TEXT)}/).size.must_equal(1)
  end

  it "prints both blocks when one param reads a fact and the vars dict" do
    # The two reads are separate deprecate tags in ansible-core: one
    # block per class, in access order (live-verified against 2.21.6).
    _stdout, stderr = run(<<-PLAYBOOK)
      - hosts: localhost
        connection: local
        gather_facts: true
        tasks:
          - name: fact and vars at once
            debug:
              msg: "{{ ansible_os_family }}|{{ vars | length }}"
      PLAYBOOK

    stderr.must_include("[DEPRECATION WARNING]: #{FACT_DEPRECATION_TEXT}\n")
    stderr.must_include("[DEPRECATION WARNING]: #{VARS_DICT_DEPRECATION_TEXT}\n")
    stderr.scan(/DEPRECATION WARNING\]/).size.must_equal(2)
    fact_at = stderr.index!("[DEPRECATION WARNING]: #{FACT_DEPRECATION_TEXT}")
    vars_at = stderr.index!("[DEPRECATION WARNING]: #{VARS_DICT_DEPRECATION_TEXT}")
    (fact_at < vars_at).must_equal(true)
  end
end
