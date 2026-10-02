require "../minitest_helper"

# Pins plugins/openssl_dhparam.cr's backend selection against real
# community.crypto.openssl_dhparam (live-diffed vs real ansible-playbook
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
end
