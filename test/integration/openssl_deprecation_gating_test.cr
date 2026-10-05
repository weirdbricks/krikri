require "../minitest_helper"

# community.crypto.openssl_pkcs12's removed-param deprecation (maciter_size)
# is gated on the module's actual OUTCOME, and openssl_privatekey's
# deprecated-curve warning rides on the generation path. Both expectations
# were captured live against ansible-playbook 2.19.11 +
# community.crypto (local, ansible_connection=local, 2026-10):
#
#   * an uncaught module exception ("Task failed: Module failed: [Errno 2]
#     ...") builds its result WITHOUT the collected deprecations, so no
#     [DEPRECATION WARNING] reaches stderr
#   * a normal return (module ok) and a fail_json failure both carry the
#     deprecation: the one-time "Deprecation warnings can be disabled"
#     hint, then the [DEPRECATION WARNING] line - stderr only, deduped
#   * generating an ECC key on a deprecated curve (brainpool*, sect*,
#     secp192r1) warns "Elliptic curves of type X should not be used for
#     new keys!" at generate_private_key time; a non-deprecated curve and
#     an idempotent rerun do not
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "test", "fixtures", "inventory-explicit-localhost.ini")

private HINT                = "[WARNING]: Deprecation warnings can be disabled by setting `deprecation_warnings=False` in ansible.cfg.\n"
private MACITER_DEPRECATION = "[DEPRECATION WARNING]: Param 'maciter_size' is deprecated. " \
                              "See the module docs for more information. This feature will be removed from " \
                              "collection 'community.crypto' version 4.0.0.\n"

def run_playbook(playbook : String) : {String, String}
  stdout = IO::Memory.new
  stderr = IO::Memory.new
  Process.run(BINARY, ["-i", INVENTORY, playbook], output: stdout, error: stderr)
  {stdout.to_s, stderr.to_s}
end

describe "openssl_pkcs12 maciter_size deprecation gating" do
  it "prints no deprecation when the module dies with an uncaught exception" do
    dir = PluginSpecHelper.tmp_path("pkcs12-deprecation-gate")
    FileUtils.mkdir_p(dir)
    missing_cert = File.join(dir, "missing-cert.pem")
    File.delete(missing_cert) if File.exists?(missing_cert)
    playbook = File.join(dir, "crash.yml")
    File.write(playbook, <<-YAML)
      - name: repro
        hosts: localhost
        gather_facts: false
        tasks:
          - community.crypto.openssl_pkcs12:
              maciter_size: 7
              path: #{File.join(dir, "out.p12")}
              privatekey_path: #{File.join(dir, "key.pem")}
              other_certificates:
                - #{missing_cert}
              state: present
            ignore_errors: true
      YAML

    stdout, stderr = run_playbook(playbook)
    stderr.must_equal("")
    stdout.must_include("Task failed: Module failed: [Errno 2] No such file or directory")
    stdout.wont_include("DEPRECATION")
  ensure
    FileUtils.rm_rf(dir) if dir
  end

  it "prints the deprecation once when the module returns normally and on a fail_json failure" do
    dir = PluginSpecHelper.tmp_path("pkcs12-deprecation-show")
    FileUtils.mkdir_p(dir)
    key = File.join(dir, "key.pem")
    PluginSpecHelper.run("openssl_privatekey", {"path" => key, "size" => "2048"})
    playbook = File.join(dir, "show.yml")
    File.write(playbook, <<-YAML)
      - name: repro
        hosts: localhost
        gather_facts: false
        tasks:
          - community.crypto.openssl_pkcs12:
              maciter_size: 7
              path: #{File.join(dir, "gone.p12")}
              state: absent
          - community.crypto.openssl_pkcs12:
              maciter_size: 7
              path: #{File.join(dir, "missing-dir", "out.p12")}
              privatekey_path: #{key}
              state: present
            ignore_errors: true
      YAML

    stdout, stderr = run_playbook(playbook)
    stderr.must_equal(HINT + MACITER_DEPRECATION)
    stdout.must_include("ignored=1")
  ensure
    FileUtils.rm_rf(dir) if dir
  end
end

describe "openssl_privatekey deprecated-curve warning" do
  it "warns when generating a key on a deprecated curve" do
    path = PluginSpecHelper.tmp_path("pk-brainpool.key")
    File.delete(path) if File.exists?(path)
    result = PluginSpecHelper.run("openssl_privatekey",
      {"path" => path, "type" => "ECC", "curve" => "brainpoolP384r1"})

    result["changed"].as_bool.must_equal(true)
    result["warnings"].as_a.map(&.as_s).must_equal(
      ["Elliptic curves of type brainpoolP384r1 should not be used for new keys!"])
  end

  it "does not warn for a current curve or an unchanged rerun" do
    path = PluginSpecHelper.tmp_path("pk-secp384.key")
    File.delete(path) if File.exists?(path)
    result = PluginSpecHelper.run("openssl_privatekey",
      {"path" => path, "type" => "ECC", "curve" => "secp384r1"})
    result["warnings"]?.must_be_nil

    rerun = PluginSpecHelper.run("openssl_privatekey",
      {"path" => path, "type" => "ECC", "curve" => "secp384r1"})
    rerun["changed"].as_bool.must_equal(false)
    rerun["warnings"]?.must_be_nil
  end

  # The sweep container has no `openssl` CLI: every previous CLI-backed
  # code path died with "Error executing process: 'openssl': No such file
  # or directory". With PATH stripped the whole run must still work
  # natively through libcrypto - generation, idempotency inspection and
  # fingerprints.
  it "generates and re-inspects keys with no openssl CLI on PATH" do
    path = PluginSpecHelper.tmp_path("pk-nocli.key")
    File.delete(path) if File.exists?(path)
    no_cli = {"PATH" => "/nonexistent-kpg34"}

    result = PluginSpecHelper.run("openssl_privatekey",
      {"path" => path, "type" => "ECC", "curve" => "brainpoolP384r1"}, env: no_cli)
    result["changed"].as_bool.must_equal(true)
    result["fingerprint"].as_h.has_key?("sha256").must_equal(true)
    File.read(path).lines.first.must_equal("-----BEGIN EC PRIVATE KEY-----")

    rerun = PluginSpecHelper.run("openssl_privatekey",
      {"path" => path, "type" => "ECC", "curve" => "brainpoolP384r1"}, env: no_cli)
    rerun["changed"].as_bool.must_equal(false)
    rerun["fingerprint"].as_h.has_key?("sha256").must_equal(true)

    encrypted = PluginSpecHelper.tmp_path("pk-nocli-ed448.key")
    File.delete(encrypted) if File.exists?(encrypted)
    ed = PluginSpecHelper.run("openssl_privatekey",
      {"path" => encrypted, "type" => "Ed448", "passphrase" => "rebfhu",
       "format" => "auto"}, env: no_cli)
    ed["changed"].as_bool.must_equal(true)
    File.read(encrypted).lines.first.must_equal("-----BEGIN ENCRYPTED PRIVATE KEY-----")

    ed_rerun = PluginSpecHelper.run("openssl_privatekey",
      {"path" => encrypted, "type" => "Ed448", "passphrase" => "rebfhu",
       "format" => "auto"}, env: no_cli)
    ed_rerun["changed"].as_bool.must_equal(false)
  end
end
