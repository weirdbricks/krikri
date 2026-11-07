require "../minitest_helper"

# Issue #938 (kpg rpm_key chaos, WrongType on `key`): real rpm_key resolves
# `key` as URL -> bare key ID -> a file that exists on the target, and
# anything else fails right there with "Not a valid key <key>"
# (rpm_key.py's RpmKey.__init__), before the PGP parser is ever asked for
# key material. `key: 67` is not 8+ hex chars and is not a file, so
# ansible-playbook reports "Not a valid key 67" - krikri used to fall
# through to the parser and report its "Failed to get keyid" wording
# instead. A fake `rpm` sits first on the plugin's own PATH so the module's
# `command -v rpm` precondition (checked before key resolution) passes
# without any RPM database on this host.
describe "rpm_key key resolution (issue #938)" do
  it "rejects a key that is neither a key ID, a URL nor a target file" do
    shim = PluginSpecHelper.tmp_path("rpm-key-invalid-shim-#{Random::Secure.hex(4)}")
    FileUtils.mkdir_p(shim)
    rpm = File.join(shim, "rpm")
    File.write(rpm, "#!/bin/sh\nexit 0\n")
    File.chmod(rpm, 0o755)

    begin
      result = PluginSpecHelper.run("rpm_key", {"key" => "67", "state" => "present"},
        env: {"PATH" => "#{shim}:#{ENV["PATH"]?}"})
      result["failed"].as_bool.must_equal(true)
      result["changed"].as_bool.must_equal(false)
      result["msg"].as_s.must_equal("Not a valid key 67")
    ensure
      FileUtils.rm_r(shim)
    end
  end

  # `key: 0xdeadbeefcafeb00d` is a YAML integer, so the real module's
  # `type: str` hands Python str(int) = "16045690984503095309" - whose
  # leading 8 characters are hex, i.e. Ansible's is_keyid matches and the
  # key resolves as a key ID, not as a file (live-verified on the kpg
  # Rocky container: state=absent exits ok with changed=False). krikri
  # marks such a wide integer with BIGINT_SENTINEL_PREFIX on its param
  # wire, so the plugin must see the bare digits, never the marker.
  it "reads a too-wide integer key as the digits Python's str(int) gives" do
    shim = PluginSpecHelper.tmp_path("rpm-key-invalid-shim3-#{Random::Secure.hex(4)}")
    FileUtils.mkdir_p(shim)
    rpm = File.join(shim, "rpm")
    File.write(rpm, "#!/bin/sh\nexit 1\n")
    File.chmod(rpm, 0o755)

    wide_int = Krikri::BIGINT_SENTINEL_PREFIX + "16045690984503095309"
    begin
      result = PluginSpecHelper.run("rpm_key", {"key" => wide_int, "state" => "absent"},
        env: {"PATH" => "#{shim}:#{ENV["PATH"]?}"})
      falsey?(result["failed"]?.try(&.as_bool)).must_equal(true)
      result["changed"].as_bool.must_equal(false)
      result["msg"]?.must_be_nil
    ensure
      FileUtils.rm_r(shim)
    end
  end

  it "rejects the same key for state=absent, which resolves it the same way" do
    shim = PluginSpecHelper.tmp_path("rpm-key-invalid-shim2-#{Random::Secure.hex(4)}")
    FileUtils.mkdir_p(shim)
    rpm = File.join(shim, "rpm")
    File.write(rpm, "#!/bin/sh\nexit 0\n")
    File.chmod(rpm, 0o755)

    begin
      result = PluginSpecHelper.run("rpm_key", {"key" => "67", "state" => "absent"},
        env: {"PATH" => "#{shim}:#{ENV["PATH"]?}"})
      result["failed"].as_bool.must_equal(true)
      result["msg"].as_s.must_equal("Not a valid key 67")
    ensure
      FileUtils.rm_r(shim)
    end
  end
end
