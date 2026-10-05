require "../minitest_helper"

# java_cert's parameter-validation failures, exercised before anything
# shells out. Actually importing/removing certificates mutates a real
# Java keystore and needs a JVM (keytool); that belongs to the live
# benchmark rounds.
describe "java_cert plugin" do
  it "fails when keystore_pass is missing" do
    result = PluginSpecHelper.run("java_cert", {"cert_path" => "/tmp/x.pem", "cert_alias" => "x", "keystore_path" => "/tmp/ks"})

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_include("keystore_pass")
  end

  it "fails when state=present has no certificate source" do
    result = PluginSpecHelper.run("java_cert", {"keystore_path" => "/tmp/ks", "keystore_pass" => "pw"})

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_include("cert_path")
  end

  it "fails when certificate sources are mutually exclusive" do
    result = PluginSpecHelper.run("java_cert", {
      "cert_path"     => "/tmp/x.pem",
      "cert_url"      => "example.com",
      "cert_alias"    => "x",
      "keystore_path" => "/tmp/ks",
      "keystore_pass" => "pw",
    })

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_include("mutually exclusive")
  end

  it "fails on an invalid state" do
    result = PluginSpecHelper.run("java_cert", {
      "cert_path"     => "/tmp/x.pem",
      "cert_alias"    => "x",
      "keystore_path" => "/tmp/ks",
      "keystore_pass" => "pw",
      "state"         => "bogus",
    })

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_include("state")
  end

  it "fails when cert_path is used without an alias" do
    result = PluginSpecHelper.run("java_cert", {
      "cert_path"     => "/tmp/x.pem",
      "keystore_path" => "/tmp/ks",
      "keystore_pass" => "pw",
    })

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_include("requires alias argument")
  end

  it "fails when keytool is not installed" do
    result = PluginSpecHelper.run("java_cert", {
      "cert_path"     => "/tmp/x.pem",
      "cert_alias"    => "x",
      "keystore_path" => "/tmp/ks",
      "keystore_pass" => "pw",
    })

    skip "keytool is installed on this host" if system("command -v keytool >/dev/null")

    result["failed"].as_bool.must_equal(true)
    # Real test_keytool: module.run_command([executable], check_rc=True) -
    # the run_command OSError shape (live-verified vs 2.19.11): msg
    # "Error executing command.", the [Errno] text under exception.
    result["msg"].as_s.must_equal("Error executing command.")
    result["exception"].as_s.must_equal("[Errno 2] No such file or directory: b'keytool'")
  end

  # kpg35 sweep #101: the Ansible module has NO "pkcs12/content import
  # requires cert_alias" check - a content import without cert_alias
  # proceeds to test_keytool, which fails with the run_command OSError
  # shape before anything alias-related runs. Krikri used to reject the
  # invocation with its own fabricated message instead.
  it "reaches the keytool probe (not an alias check) for content without cert_alias" do
    result = PluginSpecHelper.run("java_cert", {
      "cert_content"    => "tqdtaa",
      "cert_port"       => "99",
      "executable"      => "coacvd",
      "keystore_create" => "false",
      "keystore_pass"   => "zhpnnz",
      "keystore_path"   => "/tmp/kpg-work/out3.cfg",
      "pkcs12_alias"    => "xrjrcm",
    })

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal("Error executing command.")
    result["cmd"].as_s.must_equal("coacvd")
    result["rc"].as_i.must_equal(2)
    result["exception"].as_s.must_equal("[Errno 2] No such file or directory: b'coacvd'")
  end

  # Round 995004 java_cert_fail: Ansible's failing openssl extract command
  # carries a python tempfile.mkstemp() path (/tmp/tmp + 8 chars from
  # [a-z0-9_]) as cmd[5]; krikri's File.tempname leaked a
  # date-pid-prefixed name instead. Shim keytool (bare probe exits 0,
  # the -list alias check exits nonzero) and a failing openssl to reach
  # the extract path without a JVM.
  it "reports a python-mkstemp-shaped temp path in the failing extract cmd" do
    shim_dir = PluginSpecHelper.tmp_path("java-cert-mkstemp-shim")
    Dir.mkdir_p(shim_dir)
    File.write(File.join(shim_dir, "keytool"), "#!/bin/sh\n[ $# -eq 0 ] && exit 0\nexit 1\n")
    File.write(File.join(shim_dir, "openssl"), "#!/bin/sh\necho 'fake openssl failure' >&2\nexit 1\n")
    %w[keytool openssl].each { |bin| File.chmod(File.join(shim_dir, bin), 0o755) }
    env = {"PATH" => "#{shim_dir}:#{ENV["PATH"]}"}

    result = PluginSpecHelper.run("java_cert", {
      "cert_path"       => "/nonexistent/kop_nosuch.pem",
      "keystore_path"   => "/nonexistent/kop_ks.jks",
      "keystore_pass"   => "kopKeystorePass1",
      "keystore_create" => "true",
      "cert_alias"      => "kopfail",
      "state"           => "present",
    }, env: env)

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_include("cannot extract certificate")
    cmd = result["cmd"].as_a.map(&.as_s)
    (cmd.size > 5).must_equal(true)
    cmd[5].must_match(/\A\/tmp\/tmp[a-z0-9_]{8}\z/)
  end
end
