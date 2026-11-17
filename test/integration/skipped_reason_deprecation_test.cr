require "../minitest_helper"

# Runs the compiled binary against a real playbook: ansible-core 2.21 tags
# the `skipped_reason` a zero-item loop's aggregate carries with
# deprecate_value, so reading that value from a template prints a
# [DEPRECATION WARNING] block - only observable end-to-end.
private REPRO_ROOT = File.expand_path("../..", __DIR__)
private REPRO_BIN  = File.join(REPRO_ROOT, "bin", "krikri-playbook")
private REPRO_DEPR = "[DEPRECATION WARNING]: The 'skipped_reason' value is deprecated. This feature will be removed from ansible-core version 2.24."
private REPRO_HINT = "[WARNING]: Deprecation warnings can be disabled by setting `deprecation_warnings=False` in ansible.cfg."

private def repro_run(playbook_text : String) : {String, String, String}
  dir = PluginSpecHelper.tmp_path("skipped-reason-#{Random::Secure.hex(4)}")
  FileUtils.mkdir_p(dir)
  playbook = File.join(dir, "play.yml")
  File.write(playbook, playbook_text)
  stdout = IO::Memory.new
  stderr = IO::Memory.new
  Process.run(REPRO_BIN, ["-i", "localhost,", playbook], output: stdout, error: stderr, chdir: dir)
  {playbook, stdout.to_s, stderr.to_s}
end

# The `<path>:<line>:<col>` Origin real reports for the line of *playbook*
# containing *needle*, whose column is where *token* starts on that line.
private def repro_origin(playbook : String, needle : String, token : String) : String
  line = File.read_lines(playbook).index! { |text| text.includes?(needle) }
  column = File.read_lines(playbook)[line].index!(token) + 1
  "#{playbook}:#{line + 1}:#{column}"
end

describe "deprecated skipped_reason read" do
  # stancel.restore_db_and_files' own `debug: var=gzip_file_there` over a
  # looped stat: task whose source matched nothing (issue #1424). The role
  # mixes both debug spellings in one file, which is what used to make the
  # free-form read borrow a LATER task's `var:` line as its Origin.
  it "emits one block per debug Origin for free-form and keyed var reads" do
    playbook, stdout, err = repro_run(<<-YAML)
      - name: repro
        hosts: localhost
        gather_facts: false
        connection: local
        tasks:
          - name: empty loop
            stat:
              path: /tmp/krikri-does-not-exist/{{ item }}
            with_items: []
            register: gzip_file_there

          - name: free form read
            debug: var=gzip_file_there

          - name: keyed read
            debug:
              var: gzip_file_there
      YAML

    err.must_include(REPRO_HINT)
    err.must_include(REPRO_DEPR)
    # The free-form directive anchors at its `var=` token, the keyed one at
    # the value token below `var:`.
    err.must_include("Origin: #{repro_origin(playbook, "debug: var=gzip_file_there", "var=")}")
    err.must_include("Origin: #{repro_origin(playbook, "var: gzip_file_there", "gzip_file_there")}")
    err.must_include("Use 'skip_reason' instead.")
    # One block per Origin: each read prints its own, neither repeats.
    err.scan(REPRO_DEPR).size.must_equal(2)
    stdout.must_include(%("skipped_reason": "No items in the list"))
  end

  # The tag rides the VALUE, so any templating operation that consumes the
  # container warns at its own Origin, while a read of one of the
  # container's other leaves does not (live-verified vs 2.21.6).
  it "warns for a whole-value render but not for a sibling leaf read" do
    playbook, stdout, err = repro_run(<<-YAML)
      - name: repro
        hosts: localhost
        gather_facts: false
        connection: local
        tasks:
          - name: empty loop
            debug:
              msg: "{{ item }}"
            with_items: []
            register: r

          - name: whole value
            debug:
              msg: "value is {{ r }}"

          - name: sibling leaf
            debug:
              msg: "{{ r.results | length }} {{ r.skip_reason }}"
      YAML

    err.must_include("Origin: #{repro_origin(playbook, "value is {{ r }}", %("))}")
    err.scan(REPRO_DEPR).size.must_equal(1)
    stdout.must_include("0 No items in the list")
  end

  # A registered read's result carries the deprecation entry real attaches
  # to the task it warned on (no help_text in the entry, version 2.24).
  it "records the deprecation on the reading task's registered result" do
    _playbook, out, _err = repro_run(<<-YAML)
      - name: repro
        hosts: localhost
        gather_facts: false
        connection: local
        tasks:
          - name: empty loop
            debug:
              msg: "{{ item }}"
            with_items: []
            register: r

          - name: read it
            debug: var=r
            register: d

          - name: dump it
            debug:
              msg: "{{ d | to_json }}"
      YAML

    out.must_include("\\\"deprecations\\\": [{\\\"msg\\\": \\\"The 'skipped_reason' value is deprecated.\\\"")
    out.must_include("\\\"version\\\": \\\"2.24\\\"")
  end
end
