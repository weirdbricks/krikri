require "../minitest_helper"

# Issue #879 (adriano-di-giovanni.consul-tls): a free-form `command: >`
# task whose raw string templates a role default that itself templates an
# undefined variable. The fourth chain stanza ("'x' is undefined" with the
# Origin at the default's own definition) went missing because the
# reachability seed was read from the message's `_raw_params` key - a key
# the task's params never hold (the free string lives under `cmd`) - so
# the scan ran over every var layer unfiltered and a SIBLING default
# failing with the same message (`consul_tls_consul_certificate_file`
# here) made the definition look ambiguous. Real 2.19.11 follows the vars
# the failing arg actually references, so the sibling never suppresses the
# stanza.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")

describe "free-form command undefined chain stanza through a role default" do
  it "points the var-definition stanza at the default despite a same-message sibling" do
    src_dir = PluginSpecHelper.tmp_path("free-form-undef-chain-stanza", "role")
    role_dir = File.join(src_dir, "roles", "consultest")
    Dir.mkdir_p(File.join(role_dir, "tasks"))
    Dir.mkdir_p(File.join(role_dir, "defaults"))
    defaults = File.join(role_dir, "defaults", "main.yml")
    File.write(defaults, <<-YAML)
      ---
      consul_tls_out_dir: /tmp
      consul_tls_consul_private_key_file: '{{ consul_datacenter }}.consul.key.pem'
      consul_tls_consul_certificate_file: '{{ consul_datacenter }}.consul.crt.pem'
      YAML
    tasks = File.join(role_dir, "tasks", "main.yml")
    File.write(tasks, <<-YAML)
      ---
      - name: Create Certificate Signing Request
        command: >
          openssl req
            -keyout {{ consul_tls_out_dir }}/{{ consul_tls_consul_private_key_file }}
        args:
          creates: '{{ consul_tls_out_dir }}/consul.csr.pem'
      YAML
    playbook = File.join(src_dir, "pb.yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        roles:
          - consultest
      YAML

    stdout = IO::Memory.new
    Process.run(BINARY, ["-i", File.join(__DIR__, "..", "fixtures", "inventory-localhost-local.ini"), playbook], output: stdout, error: Process::Redirect::Inherit)
    text = stdout.to_s

    # The params stanza shortens to the prefix alone once the fourth stanza
    # applies, keeping the free string's own value position.
    text.must_include("Error while resolving value for '_raw_params'.\nOrigin: #{tasks}:3:12")
    # The fourth stanza's Origin is the failing default's own value token
    # (the quote), not the sibling default that fails the same way but is
    # unreachable from this arg.
    text.must_include("'consul_datacenter' is undefined\nOrigin: #{defaults}:3:37")
  end
end
