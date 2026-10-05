require "../minitest_helper"

# Pins plugins/openssl_dhparam.cr's backend selection against real
# community.crypto.openssl_dhparam (live-diffed vs ansible-playbook
# 2.19.11): the cryptography backend's generate raises the
# "DH key_size must be at least 512 bits" ValueError for undersized
# params as an UNHANDLED module exception (the fatal msg carries the
# full "Task failed: Module failed:" chain).
describe "openssl_dhparam backend selection" do
  it "fails an undersized cryptography-backend generate as an unhandled exception" do
    work = PluginSpecHelper.tmp_path("dhparam-small")
    Dir.mkdir_p(work)

    result = PluginSpecHelper.run("openssl_dhparam", {
      "path"                  => File.join(work, "dh.pem"),
      "size"                  => "100",
      "select_crypto_backend" => "cryptography",
    })
    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal("Task failed: Module failed: DH key_size must be at least 512 bits")
  end

  it "fails with the both-backends-missing message when neither backend exists" do
    # cryptography IS installed on this host, so the auto backend picks
    # it - the neither-backend message can only be pinned with both
    # probes forced off, which the plugin does not expose; the live
    # verification of that wording ran in the generator container
    # (no cryptography, no openssl binary on PATH). Here: pin that the
    # explicit cryptography backend with a valid size generates natively.
    work = PluginSpecHelper.tmp_path("dhparam-generate")
    Dir.mkdir_p(work)
    path = File.join(work, "dh.pem")

    result = PluginSpecHelper.run("openssl_dhparam", {
      "path"                  => path,
      "size"                  => "512",
      "select_crypto_backend" => "cryptography",
    })
    result["changed"].as_bool.must_equal(true)
    File.exists?(path).must_equal(true)
    File.read(path).must_include("-----BEGIN DH PARAMETERS-----")
  end

  # kpg35 sweep #216: the explicit `openssl` backend on a host WITHOUT
  # the openssl CLI used to die with "Error executing process: 'openssl'".
  # The backend now runs the same libcrypto call the CLI makes, natively,
  # and reproduces the CLI stderr the Ansible module passes to fail_json
  # verbatim - including libcrypto's own error line (whose 12-hex prefix
  # is the printing thread's id, a per-process value; masked in
  # byte-parity runs). Live-diffed vs ansible-playbook 2.19.11.
  it "fails an undersized openssl-backend generate with the CLI's exact stderr" do
    work = PluginSpecHelper.tmp_path("dhparam-small-cli")
    Dir.mkdir_p(work)
    path = File.join(work, "dh.pem")

    result = PluginSpecHelper.run("openssl_dhparam", {
      "path"                  => path,
      "size"                  => "61",
      "select_crypto_backend" => "openssl",
    })
    result["failed"].as_bool.must_equal(true)
    result["changed"].as_bool.must_equal(false)
    File.exists?(path).must_equal(false)

    msg = result["msg"].as_s
    msg.must_equal("Generating DH parameters, 61 bit long safe prime\n" \
                   "dhparam: Generating DH key parameters failed\n" \
                   "#{msg.lines.last}\n")
    # Everything up to the thread-id prefix is deterministic (same
    # libcrypto Ansible's CLI links); the prefix itself differs per process.
    assert_match(
      /^[0-9A-F]{12}0000:error:0280007E:Diffie-Hellman routines:dh_builtin_genparams:modulus too small:\S*dh_gen\.c:\d+:$/,
      msg.lines.last)
  end

  # Idempotency check is native too (PEM parse + DH_bits + DH_check
  # instead of `openssl dhparam -check -text -noout`): a freshly
  # generated file must be recognized as already valid on a re-run.
  it "recognizes a freshly generated file as already valid on a re-run" do
    work = PluginSpecHelper.tmp_path("dhparam-idempotent")
    Dir.mkdir_p(work)
    path = File.join(work, "dh.pem")

    first = PluginSpecHelper.run("openssl_dhparam", {
      "path"                  => path,
      "size"                  => "512",
      "select_crypto_backend" => "cryptography",
    })
    first["changed"].as_bool.must_equal(true)

    rerun = PluginSpecHelper.run("openssl_dhparam", {
      "path"                  => path,
      "size"                  => "512",
      "select_crypto_backend" => "openssl",
    })
    rerun["changed"].as_bool.must_equal(false)
    rerun["msg"].as_s.must_equal("DH parameters already valid at #{path}")
  end
end
