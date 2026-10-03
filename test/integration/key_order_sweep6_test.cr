require "../minitest_helper"

# Real ansible-core 2.19.11 (community.crypto 3.1.1) registered-result key
# order for the crypto plugins - live-verified via `{{ r | to_json }}` dumps
# on localhost plays (changed / unchanged rerun / check mode where they
# differ). `failed: false` is backfilled by the executor after the plugin
# JSON, so the plugin-level pins omit it, exactly as real's wire shows it
# between the module keys and the trailing `warnings`.
describe "openssl_privatekey plugin result key order" do
  it "serializes a fresh RSA generation as type-size-fingerprint before filename" do
    dir = PluginSpecHelper.tmp_path("ko-pk1")
    FileUtils.mkdir_p(dir)
    path = File.join(dir, "key.pem")
    result = PluginSpecHelper.run("openssl_privatekey", {"path" => path, "size" => "2048"})

    result["changed"].as_bool.must_equal(true)
    result.as_h.keys.must_equal([
      "type", "size", "fingerprint", "filename", "changed",
    ])
  end

  it "keeps the same order on an idempotent unchanged rerun" do
    dir = PluginSpecHelper.tmp_path("ko-pk2")
    FileUtils.mkdir_p(dir)
    path = File.join(dir, "key.pem")
    PluginSpecHelper.run("openssl_privatekey", {"path" => path, "size" => "2048"})
    result = PluginSpecHelper.run("openssl_privatekey", {"path" => path, "size" => "2048"})

    result["changed"].as_bool.must_equal(false)
    result.as_h.keys.must_equal([
      "type", "size", "fingerprint", "filename", "changed",
    ])
  end

  it "places curve between fingerprint and filename for ECC keys" do
    dir = PluginSpecHelper.tmp_path("ko-pk3")
    FileUtils.mkdir_p(dir)
    path = File.join(dir, "key.pem")
    result = PluginSpecHelper.run("openssl_privatekey",
      {"path" => path, "type" => "ECC", "curve" => "secp256r1", "size" => "256"})

    result["changed"].as_bool.must_equal(true)
    result.as_h.keys.must_equal([
      "type", "size", "fingerprint", "curve", "filename", "changed",
    ])
  end
end

describe "openssl_privatekey_info plugin result key order" do
  it "serializes an RSA key read with the info keys in real's order" do
    dir = PluginSpecHelper.tmp_path("ko-pki1")
    FileUtils.mkdir_p(dir)
    path = File.join(dir, "key.pem")
    PluginSpecHelper.run("openssl_privatekey", {"path" => path, "size" => "2048"})
    result = PluginSpecHelper.run("openssl_privatekey_info", {"path" => path})

    result["can_load_key"].as_bool.must_equal(true)
    result.as_h.keys.must_equal([
      "can_load_key", "can_parse_key", "key_is_consistent", "public_key",
      "public_key_fingerprints", "type", "public_data", "changed",
    ])
  end

  it "places private_data after public_data with return_private_key_data" do
    dir = PluginSpecHelper.tmp_path("ko-pki2")
    FileUtils.mkdir_p(dir)
    path = File.join(dir, "key.pem")
    PluginSpecHelper.run("openssl_privatekey", {"path" => path, "size" => "2048"})
    result = PluginSpecHelper.run("openssl_privatekey_info",
      {"path" => path, "return_private_key_data" => "true"})

    result["can_load_key"].as_bool.must_equal(true)
    result.as_h.keys.must_equal([
      "can_load_key", "can_parse_key", "key_is_consistent", "public_key",
      "public_key_fingerprints", "type", "public_data", "private_data", "changed",
    ])
  end
end
