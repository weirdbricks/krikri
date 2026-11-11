require "../minitest_helper"

# Ansible's include_vars action plugin uses
# the `file:`/`dir:` value AS a path in two places, before it ever copies it
# to text: `os.path.join(current_dir, self.source_dir)` for dir: and
# `_find_needle('vars', self.source_file)` for
# file:. A truthy non-string YAML literal therefore crashes the plugin there,
# with the value's Python type name in the message - while a FALSY one
# (0, 0.0, false, "", [], {}, a bare `file:`) is discarded by the plugin's own
# `if not self.source_dir and not self.source_file` check first, leaving the
# plain null-file failure. Both were previously a Crystal cast crash at PARSE
# time (`file: 0` dropped the whole task with a parse warning instead of
# running it). The free-form form (`include_vars: 21`) never becomes
# Ansible's _raw_params at all: mod_args refuses it with a whole-playbook abort.
# Every expectation below was probed against ansible-playbook 2.21.6 - note
# that the file: crash is `source.split('/')` there (2.21's
# path_dwim_relative_stack), where 2.19 and earlier reached
# `source.startswith('~')` first inside _find_needle.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(__DIR__, "..", "fixtures", "inventory-explicit-localhost.ini")

private def run_playbook(yaml : String, files : Hash(String, String) = {} of String => String)
  scratch = PluginSpecHelper.tmp_path("include-vars-path-type")
  FileUtils.mkdir_p(scratch)
  files.each { |name, content| File.write(File.join(scratch, name), content) }
  playbook = File.join(scratch, "play.yml")
  File.write(playbook, yaml)
  output = IO::Memory.new
  status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output, chdir: scratch)
  {status, output.to_s}
ensure
  FileUtils.rm_rf(scratch) if scratch && Dir.exists?(scratch)
end

private def play(task_args : String) : String
  <<-YAML
  - hosts: localhost
    connection: local
    gather_facts: false
    tasks:
      - include_vars:
  #{task_args}
        ignore_errors: true
  YAML
end

describe "include_vars with a non-string file:/dir: literal" do
  it "runs a falsy file literal as the null-file failure, never dropping the task" do
    _, output = run_playbook(play("          file: 0"))

    output.wont_include("Skipping task")
    output.must_include(%([WARNING]: Invalid request to find a file that matches a "null" value))
    output.must_include("[ERROR]: Task failed: Action failed: Unknown error.")
    output.must_include(%("message": "Could not find file on the Ansible Controller.))
    output.must_match(/ignored=1/)
  end

  it "crashes a truthy non-string file literal in the dataloader, with its Python type name" do
    _, output = run_playbook(play("          file: 21"))

    output.must_include("[ERROR]: Task failed: '_AnsibleTaggedInt' object has no attribute 'split'")
    output.must_include(%("msg": "Task failed: '_AnsibleTaggedInt' object has no attribute 'split'"))
    output.wont_include("Invalid request to find a file")
    output.must_match(/ignored=1/)
  end

  it "crashes an integer file literal exactly as the generator's chaos seed does" do
    _, output = run_playbook(play("          file: 71"))

    output.must_include("[ERROR]: Task failed: '_AnsibleTaggedInt' object has no attribute 'split'")
    output.must_include(%("msg": "Task failed: '_AnsibleTaggedInt' object has no attribute 'split'"))
    output.must_match(/ignored=1/)
  end

  it "prints plain bool for a true file literal and the tagged names for the containers" do
    _, bools = run_playbook(play("          file: true"))
    bools.must_include("[ERROR]: Task failed: 'bool' object has no attribute 'split'")

    _, lists = run_playbook(play("          file: [a]"))
    lists.must_include("[ERROR]: Task failed: '_AnsibleTaggedList' object has no attribute 'split'")

    _, dicts = run_playbook(play("          file: {a: 1}"))
    dicts.must_include("[ERROR]: Task failed: '_AnsibleTaggedDict' object has no attribute 'split'")

    _, floats = run_playbook(play("          file: 1.5"))
    floats.must_include("[ERROR]: Task failed: '_AnsibleTaggedFloat' object has no attribute 'split'")
  end

  it "crashes a truthy non-string dir literal in os.path.join instead" do
    _, output = run_playbook(play("          dir: 21"))

    output.must_include("[ERROR]: Task failed: join() argument must be str, bytes, or os.PathLike object, not '_AnsibleTaggedInt'")
    output.wont_include("Invalid request to find a file")
  end

  it "discards a falsy dir literal into the same null-file failure a file literal gets" do
    _, output = run_playbook(play("          dir: false"))

    output.must_include(%([WARNING]: Invalid request to find a file that matches a "null" value))
    output.must_include("[ERROR]: Task failed: Action failed: Unknown error.")
  end

  it "reports the invalid-option and mixing errors before any type crash" do
    _, mixed = run_playbook(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - include_vars:
              file: 21
              depth: 3
            ignore_errors: true
    YAML
    mixed.must_include("[ERROR]: Task failed: You are mixing file only and dir only arguments")

    _, invalid = run_playbook(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - include_vars:
              file: 21
              files_macthing: "*.yml"
            ignore_errors: true
    YAML
    invalid.must_include("[ERROR]: Task failed: files_macthing is not a valid option in include_vars")
  end

  it "registers the failed arg-validation result so a later when: on it skips, not errors" do
    # issue #1124: real's register fires for the failed action-validation
    # result too ({changed, failed, exception, msg}), so with ignore_errors:
    # the play continues and `when: r is succeeded` evaluates false - the
    # next task skips. This engine left the register undefined and the
    # when: itself failed ('r' is undefined) where real had a skipped task.
    _, output = run_playbook(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - include_vars:
              file: vars.yml
              hash_behaviour_bogus: merge
            register: r
            ignore_errors: true
          - debug:
              msg: should-not-run
            when: r is succeeded
    YAML

    output.must_include("[ERROR]: Task failed: hash_behaviour_bogus is not a valid option in include_vars")
    output.must_include("skipping: [localhost]")
    output.wont_include("'r' is undefined")
    output.must_match(/ok=1/)
    output.must_match(/skipped=1/)
    output.must_match(/ignored=1/)
  end

  it "keeps the arg-validation chain two-segment, Origin'd at the offending option" do
    # include_vars.py raises its argument-validation failures with the
    # offending VALUE as the exception's obj, so ansible's caused-by event
    # carries that value's own source context and the block does NOT
    # collapse into the header: the unknown-option loop tags the KEY
    # (`obj=arg`, caret on the key) while the non-list `extensions:` check
    # tags the VALUE (caret on the value). Captured byte-for-byte from
    # ansible-playbook 2.21.6.
    scratch = PluginSpecHelper.tmp_path("include-vars-option-origin")
    FileUtils.mkdir_p(scratch)
    playbook = File.join(scratch, "play.yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: typo on file
            include_vars:
              name: bawazd
              flie: vars.yml
            ignore_errors: true
          - name: non-list extensions
            include_vars:
              dir: /nonexistent-krikri-dir
              extensions: notalist
            ignore_errors: true
      YAML
    output = IO::Memory.new
    Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output, chdir: scratch)
    text = output.to_s

    typo = "[ERROR]: Task failed: flie is not a valid option in include_vars\n\n" +
           "Task failed.\nOrigin: #{playbook}:5:7\n\n" \
           "3   gather_facts: false\n" \
           "4   tasks:\n" \
           "5     - name: typo on file\n" \
           "        ^ column 7\n\n" \
           "<<< caused by >>>\n\n" \
           "flie is not a valid option in include_vars\nOrigin: #{playbook}:8:9\n\n" \
           "6       include_vars:\n" \
           "7         name: bawazd\n" \
           "8         flie: vars.yml\n" \
           "          ^ column 9\n\n"
    text.must_include(typo)

    extensions = "[ERROR]: Task failed: The 'extensions' option must be a list.\n\n" +
                 "Task failed.\nOrigin: #{playbook}:10:7\n\n" \
                 " 8         flie: vars.yml\n" \
                 " 9       ignore_errors: true\n" \
                 "10     - name: non-list extensions\n" \
                 "         ^ column 7\n\n" \
                 "<<< caused by >>>\n\n" \
                 "The 'extensions' option must be a list.\nOrigin: #{playbook}:13:21\n\n" \
                 "11       include_vars:\n" \
                 "12         dir: /nonexistent-krikri-dir\n" \
                 "13         extensions: notalist\n" \
                 "                       ^ column 21\n\n"
    text.must_include(extensions)
  end

  it "aborts the whole playbook on a non-string free-form value, like Ansible's mod_args" do
    _, output = run_playbook(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - include_vars: 21
    YAML

    output.must_include("[ERROR]: unexpected parameter type in action: <class 'ansible.module_utils._internal._datatag._AnsibleTaggedInt'>")
    output.wont_include("PLAY [")
  end

  it "crashes a free-form value that TEMPLATES to a non-string, on the value's own type" do
    # A free-form include_vars: is Ansible's _raw_params: mod_args keeps
    # whatever the template resolved to, so a resolve-to-list reaches
    # _set_args as a list (a truthy one dies on .rstrip, a falsy one in
    # os.path.join) instead of becoming a path - 5u623l20.pgsql's own
    # `lookup('first_found', ..., skip=true)` resolves to an empty list on
    # any distribution it ships no vars/ file for (issue #1085).
    _, output = run_playbook(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - include_vars: "{{ lookup('ansible.builtin.first_found', params) }}"
            vars:
              params:
                files: [nosuch-vars.yml]
                skip: true
            ignore_errors: true
          - include_vars: "{{ [1] }}"
            ignore_errors: true
    YAML

    output.must_include("[ERROR]: Task failed: join() argument must be str, bytes, or os.PathLike object, not '_AnsibleTaggedList'")
    output.must_include(%("msg": "Task failed: join() argument must be str, bytes, or os.PathLike object, not '_AnsibleTaggedList'"))
    output.must_include("[ERROR]: Task failed: '_AnsibleTaggedList' object has no attribute 'rstrip'")
    output.must_match(/ignored=2/)
    output.wont_include("Searched in")
  end

  it "still accepts the ordinary string file form" do
    _, output = run_playbook(
      <<-YAML,
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - include_vars: {file: good.yml}
          - debug: {msg: "{{ aa }}"}
      YAML
      {"good.yml" => "aa: 1\n"}
    )

    output.must_include(%("msg": 1))
  end
end
