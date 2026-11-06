require "../minitest_helper"

# ansible.builtin.apt_key is deprecated in ansible-core itself (issue #917):
# every task occurrence prints the [DEPRECATION WARNING] (with its Origin
# block at the module key's own position) ahead of the PLAY banner, the
# once-per-run trailer prints once, and every task result the module
# actually produced carries the `deprecations` entry - live-verified vs
# ansible-core 2.19.11 for the bare, FQCN and ansible.legacy spellings,
# including that a bare `apt_key:` echoes its as-written name while the
# qualified spellings echo their as-written qualified name, and that the
# removal tail names ansible-core, not a collection.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")

private TRAILER_LINE = "[WARNING]: Deprecation warnings can be disabled by setting `deprecation_warnings=False` in ansible.cfg."

private def run(playbook_text : String) : {String, String}
  dir = PluginSpecHelper.tmp_path("aptkey-deprecation-#{Random::Secure.hex(4)}")
  FileUtils.mkdir_p(dir)
  playbook = File.join(dir, "play.yml")
  File.write(playbook, playbook_text)
  stdout = IO::Memory.new
  stderr = IO::Memory.new
  Process.run(BINARY, ["-i", "localhost,", playbook], output: stdout, error: stderr, chdir: dir)
  {stdout.to_s, stderr.to_s}
end

describe "apt_key deprecation warning" do
  it "prints the deprecation with an Origin block at the module key, and the deprecations entry on the result" do
    stdout, stderr = run(<<-PLAYBOOK)
      - hosts: localhost
        gather_facts: false
        connection: local
        tasks:
          - name: apt_key
            ansible.builtin.apt_key:
              state: absent
              id: ABCDEF0123456789
            ignore_errors: true
            register: r
          - name: show
            ansible.builtin.debug:
              msg: "depr={{ r.deprecations | to_json }}"
      PLAYBOOK

    stdout.must_include("ok: [localhost]")
    stderr.scan(TRAILER_LINE).size.must_equal(1)
    stderr.must_include("[DEPRECATION WARNING]: ansible.builtin.apt_key has been deprecated. Use deb822_repository instead. This feature will be removed from ansible-core version 2.25.")
    # Origin at the module KEY's own line/column, like real.
    stderr.must_include("Origin: ")
    stderr.must_include("ansible.builtin.apt_key:\n")
    stderr.must_include("^ column 7")
    # The deprecation lands before the play banner (task-load time).
    (stderr.index!(TRAILER_LINE) < stdout.index!("PLAY [localhost]")).must_equal(true)
    # Every executed result carries the deprecations entry.
    stdout.must_include("ansible.builtin.apt_key has been deprecated. Use deb822_repository instead.")
    stdout.must_include("\\\"collection_name\\\": \\\"ansible.builtin\\\"")
    stdout.must_include("\\\"version\\\": \\\"2.25\\\"")
    stdout.must_include("\\\"deprecator\\\": {\\\"resolved_name\\\": \\\"ansible.builtin\\\", \\\"type\\\": null}")
  end

  it "prints once per task occurrence and echoes the as-written spelling" do
    _stdout, stderr = run(<<-PLAYBOOK)
      - hosts: localhost
        gather_facts: false
        connection: local
        tasks:
          - name: bare
            apt_key:
              state: absent
              id: ABCDEF0123456789
            ignore_errors: true
          - name: legacy
            ansible.legacy.apt_key:
              state: absent
              id: ABCDEF0123456789
            ignore_errors: true
      PLAYBOOK

    stderr.must_include("[DEPRECATION WARNING]: apt_key has been deprecated. Use deb822_repository instead. This feature will be removed from ansible-core version 2.25.")
    stderr.must_include("[DEPRECATION WARNING]: ansible.legacy.apt_key has been deprecated. Use deb822_repository instead. This feature will be removed from ansible-core version 2.25.")
    stderr.scan(/DEPRECATION WARNING\]: .*apt_key has been deprecated/).size.must_equal(2)
  end

  it "warns for a when-false skipped apt_key task" do
    stdout, stderr = run(<<-PLAYBOOK)
      - hosts: localhost
        gather_facts: false
        connection: local
        tasks:
          - name: skipped
            ansible.builtin.apt_key:
              state: absent
              id: ABCDEF0123456789
            when: false
      PLAYBOOK

    stderr.must_include("[DEPRECATION WARNING]: ansible.builtin.apt_key has been deprecated.")
    stdout.must_include("skipping: [localhost]")
  end
end
