require "../minitest_helper"

# ansible.builtin.apt_repository is deprecated in ansible-core itself
# (issue #918): every task occurrence prints the [DEPRECATION WARNING]
# with an Origin block ahead of the PLAY banner, the once-per-run trailer
# prints once, and every task result the module actually produced carries
# the `deprecations` entry - live-verified vs ansible-core 2.21.6 for the
# bare, FQCN and ansible.legacy spellings: the FQCN spelling echoes
# "ansible.builtin.apt_repository" while the bare and ansible.legacy
# spellings echo the bare "apt_repository"; the FQCN and bare spellings
# carry the positioned Origin block at the module key's own line/column,
# while the ansible.legacy spelling's Origin is position-less
# (`Origin: <unknown>` with the bare key as its whole excerpt, no caret).
# The removal tail names ansible-core, not a collection. The playbook
# tasks below omit the required `repo` argument so the module fails at
# argspec validation and never touches the host's apt sources.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")

private TRAILER_LINE = "[WARNING]: Deprecation warnings can be disabled by setting `deprecation_warnings=False` in ansible.cfg."

private def run(playbook_text : String) : {String, String}
  dir = PluginSpecHelper.tmp_path("aptrepo-deprecation-#{Random::Secure.hex(4)}")
  FileUtils.mkdir_p(dir)
  playbook = File.join(dir, "play.yml")
  File.write(playbook, playbook_text)
  stdout = IO::Memory.new
  stderr = IO::Memory.new
  Process.run(BINARY, ["-i", "localhost,", playbook], output: stdout, error: stderr, chdir: dir)
  {stdout.to_s, stderr.to_s}
end

describe "apt_repository deprecation warning" do
  it "prints the deprecation with an Origin block at the module key, and the deprecations entry on the result" do
    stdout, stderr = run(<<-PLAYBOOK)
      - hosts: localhost
        gather_facts: false
        connection: local
        tasks:
          - name: apt_repository
            ansible.builtin.apt_repository:
              state: present
            ignore_errors: true
            register: r
          - name: show
            ansible.builtin.debug:
              msg: "depr={{ r.deprecations | to_json }}"
      PLAYBOOK

    stdout.must_include("ok: [localhost]")
    stderr.scan(TRAILER_LINE).size.must_equal(1)
    stderr.must_include("[DEPRECATION WARNING]: ansible.builtin.apt_repository has been deprecated. Use deb822_repository instead. This feature will be removed from ansible-core version 2.25.")
    # Origin at the module KEY's own line/column, like real.
    stderr.must_include("Origin: ")
    stderr.must_include("ansible.builtin.apt_repository:\n")
    stderr.must_include("^ column 7")
    # The deprecation lands before the play banner (task-load time).
    (stderr.index!(TRAILER_LINE) < stdout.index!("PLAY [localhost]")).must_equal(true)
    # Every executed result carries the deprecations entry.
    stdout.must_include("ansible.builtin.apt_repository has been deprecated. Use deb822_repository instead.")
    stdout.must_include("\\\"collection_name\\\": \\\"ansible.builtin\\\"")
    stdout.must_include("\\\"version\\\": \\\"2.25\\\"")
    stdout.must_include("\\\"deprecator\\\": {\\\"resolved_name\\\": \\\"ansible.builtin\\\", \\\"type\\\": null}")
  end

  it "prints once per task occurrence and echoes the as-written spelling for bare and legacy" do
    _stdout, stderr = run(<<-PLAYBOOK)
      - hosts: localhost
        gather_facts: false
        connection: local
        tasks:
          - name: fqcn
            ansible.builtin.apt_repository:
              state: present
            ignore_errors: true
          - name: bare
            apt_repository:
              state: present
            ignore_errors: true
          - name: legacy
            ansible.legacy.apt_repository:
              state: present
            ignore_errors: true
          - name: legacy again
            ansible.legacy.apt_repository:
              state: present
            ignore_errors: true
      PLAYBOOK

    stderr.must_include("[DEPRECATION WARNING]: ansible.builtin.apt_repository has been deprecated. Use deb822_repository instead. This feature will be removed from ansible-core version 2.25.")
    stderr.must_include("[DEPRECATION WARNING]: apt_repository has been deprecated. Use deb822_repository instead. This feature will be removed from ansible-core version 2.25.")
    # The bare and legacy spellings both echo the bare name (2.21.6).
    stderr.scan(/DEPRECATION WARNING\]: apt_repository has been deprecated/).size.must_equal(2)
    # The legacy spelling's Origin is position-less: the <unknown> tag with
    # the bare module key as its whole excerpt, no caret line - asserted
    # glued to its warning line so the positioned blocks' carets above
    # don't satisfy it.
    stderr.must_include("Use deb822_repository instead. This feature will be removed from ansible-core version 2.25.\nOrigin: <unknown>\n\napt_repository\n\n")
    # Being position-less, that block repeats verbatim, so two legacy
    # occurrences dedup onto one console line - unlike the positioned
    # blocks, which differ per task.
    stderr.scan("Origin: <unknown>").size.must_equal(1)
  end
end
