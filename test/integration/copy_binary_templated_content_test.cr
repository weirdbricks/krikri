require "../minitest_helper"

# Binary content produced by TEMPLATING (not by a src: file - the src-path
# binary staging is spec'd in copy_binary_source_staging_test.cr) riding the
# plugin JSON wire: bloxberg.corosync_pacemaker's "exchange | deploy authkey"
# is `copy: content: "{{ hostvars['_authkey_dummy']['authkey_content'] }}"`
# where the value came from `slurp` + `b64decode` of corosync-keygen's 32
# random bytes (issue #835). The bytes are almost never valid UTF-8, and a
# Crystal JSON round trip mangles invalid byte sequences into U+FFFD text -
# so the plugin's content-vs-dest checksum comparison saw different bytes
# than the file held and every run rewrote the file as changed where
# ansible-playbook reports ok. The wire now base64-wraps invalid-UTF-8
# param values (BINARY_WIRE_PREFIX), and this spec pins the end-to-end
# behavior: the deployed file's bytes are exact and the second run is ok.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "test", "fixtures", "inventory-explicit-localhost.ini")

# 32 bytes of deliberately invalid UTF-8 (lone continuation bytes, truncated
# multibyte leads, an invalid 0xFB lead) - the same shapes a real random
# authkey carries.
private AUTHKEY_BYTES = Bytes[0x86, 0x47, 0x6d, 0x68, 0x17, 0x8e, 0x2e, 0x07, 0xce, 0xf2, 0x0a, 0xe9, 0xa2, 0x95, 0x0f, 0x3f, 0x56, 0x8b, 0x2d, 0x32, 0xa8, 0xd3, 0x9a, 0x7e, 0xce, 0x03, 0xdd, 0xe7, 0xc5, 0x8b, 0x97, 0xfb]

private def run_playbook(scratch : String) : String
  playbook = File.join(scratch, "play.yml")
  output = IO::Memory.new
  Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output, chdir: scratch)
  output.to_s
end

describe "copy: templated binary content survives the plugin JSON wire" do
  it "deploys slurp+b64decode bytes exactly and is ok on the second run" do
    scratch = PluginSpecHelper.tmp_path("copy-binary-templated-content")
    FileUtils.mkdir_p(scratch)
    key_file = File.join(scratch, "authkey")
    File.write(key_file, AUTHKEY_BYTES)
    deployed = File.join(scratch, "authkey.deployed")

    File.write(File.join(scratch, "play.yml"), <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: generate | slurp authkey
            slurp:
              src: #{key_file}
            register: authkey_slurp
          - name: generate | save into dummy host
            add_host:
              name: _authkey_dummy
              authkey_content: "{{ authkey_slurp['content'] | b64decode }}"
            changed_when: no
          - name: exchange | deploy authkey
            copy:
              content: "{{ hostvars['_authkey_dummy']['authkey_content'] }}"
              dest: #{deployed}
              mode: 0644
      YAML

    first = run_playbook(scratch)
    first.must_include("changed: [localhost]")
    File.read(deployed).must_equal(String.new(AUTHKEY_BYTES))

    # The idempotency verdict is the issue's actual divergence: ansible's
    # identical-content copy reports ok, the pre-fix engine rewrote the
    # file (changed) because its wire-mangled content never checksummed
    # equal to the dest.
    second = run_playbook(scratch)
    second.must_include("changed=0")
    File.read(deployed).must_equal(String.new(AUTHKEY_BYTES))
  ensure
    FileUtils.rm_r(scratch) if scratch && Dir.exists?(scratch)
  end
end
