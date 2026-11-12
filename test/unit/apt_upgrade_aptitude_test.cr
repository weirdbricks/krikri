require "../minitest_helper"

# Regression spec for issue #1141 (thermistor.common on Ubuntu, round
# round29906946): the role's base packages install aptitude, so its WARM
# `apt: {upgrade: safe}` run takes apt.py's aptitude path
# (`use_apt_get = p['force_apt_get']`, forced true only when aptitude is
# ABSENT) while the cold run - aptitude not yet installed - used apt-get.
# The two backends treat Ubuntu phased updates oppositely (apt-get defers
# them, aptitude installs them regardless of the phasing percentage), so
# the warm run reported changed under real ansible where this engine -
# hardwired to `apt-get upgrade --with-new-pkgs` - reported ok. The
# `_aptitude_paths` seam (spec-only, like `_apt_get_paths`) points the
# aptitude probe at a fake binary so these specs run on any host.
describe "apt upgrade aptitude backend" do
  def write_fake_aptitude(output : String, exit_code : Int32) : String
    path = PluginSpecHelper.tmp_path("aptitude-fake")
    File.write(path, <<-SCRIPT)
      #!/bin/sh
      cat <<'KRIKRI_EOF'
      Reading package lists...
      #{output}
      KRIKRI_EOF
      exit #{exit_code}
      SCRIPT
    File.chmod(path, 0o755)
    path
  end

  it "runs aptitude safe-upgrade when aptitude is installed, not apt-get" do
    fake = write_fake_aptitude("The following packages will be upgraded:\n  krikri-fake\n1 packages upgraded, 0 newly installed, 0 to remove and 0 not upgraded.", 0)

    result = PluginSpecHelper.run("apt", {"upgrade" => "safe", "_aptitude_paths" => fake, "lock_timeout" => "1"})

    # Real upgrade(): exit_json(changed=True, msg=out, stdout=out, ...)
    # - and the stdout must be the aptitude output itself (the task
    # registers it and computes changed_when from it). "packages
    # upgraded" is aptitude's own summary wording; apt-get output can
    # never contain it, so this pins WHICH binary ran, not just the
    # result shape.
    result["changed"].as_bool.must_equal(true)
    result["stdout"].as_s.must_include("packages upgraded")
    result["stdout"].as_s.must_include("krikri-fake")
  end

  it "screenscrapes aptitude's own zero summary (0 packages upgraded), not apt-get's" do
    fake = write_fake_aptitude("0 packages upgraded, 0 newly installed, 0 to remove and 0 not upgraded.", 0)

    result = PluginSpecHelper.run("apt", {"upgrade" => "safe", "_aptitude_paths" => fake, "lock_timeout" => "1"})

    # apt.py's APTITUDE_ZERO marker ("\n0 packages upgraded, 0 newly
    # installed, 0 to remove") - reusing the apt-get marker here would
    # never match this output and report changed forever.
    result["changed"].as_bool.must_equal(false)
    result["stdout"].as_s.must_include("0 packages upgraded")
  end

  it "quotes the resolved aptitude path and the bare safe-upgrade command in the failure msg" do
    fake = write_fake_aptitude("boom", 1)
    File.write(fake, "#!/bin/sh\necho boom >&2\nexit 1\n")

    result = PluginSpecHelper.run("apt", {"upgrade" => "safe", "_aptitude_paths" => fake, "lock_timeout" => "1"})

    # Real upgrade() failure: fail_json("'aptitude safe-upgrade' failed:
    # ...") - no --auto-remove suffix is ever folded into the aptitude
    # command string (unlike the apt-get branches), and the msg quotes
    # the RESOLVED binary path (get_bin_path), i.e. our fake's path.
    result["failed"].as_bool.must_equal(true)
    # Real run_command's err carries the trailing newline verbatim into
    # the msg ("'%s %s' failed: %s" % (apt_cmd, upgrade_command, err)).
    result["msg"].as_s.must_equal("'#{fake} safe-upgrade' failed: boom\n")
    result["rc"].as_i.must_equal(1)
  end

  it "keeps upgrade dist on apt-get even with aptitude installed" do
    fake = write_fake_aptitude("aptitude-was-invoked", 0)
    marker = PluginSpecHelper.tmp_path("dist-aptitude-marker")

    # The fake is found by the probe (dist still resolves aptitude, like
    # real apt.py) but must never be EXECUTED: it touches the marker if
    # it runs. Check mode keeps the real apt-get run a --simulate.
    File.write(fake, "#!/bin/sh\ntouch #{marker}\necho aptitude-was-invoked\nexit 0\n")
    File.chmod(fake, 0o755)

    result = PluginSpecHelper.run("apt", {
      "upgrade"             => "dist",
      "_aptitude_paths"     => fake,
      "lock_timeout"        => "1",
      "_ansible_check_mode" => "true",
    })

    File.exists?(marker).must_equal(false)
    result["stdout"].as_s.wont_include("aptitude-was-invoked")
  end

  it "force_apt_get pins the upgrade back onto apt-get" do
    fake = write_fake_aptitude("aptitude-was-invoked", 0)
    marker = PluginSpecHelper.tmp_path("force-aptitude-marker")

    File.write(fake, "#!/bin/sh\ntouch #{marker}\necho aptitude-was-invoked\nexit 0\n")
    File.chmod(fake, 0o755)

    result = PluginSpecHelper.run("apt", {
      "upgrade"             => "safe",
      "force_apt_get"       => "true",
      "_aptitude_paths"     => fake,
      "lock_timeout"        => "1",
      "_ansible_check_mode" => "true",
    })

    File.exists?(marker).must_equal(false)
    result["stdout"].as_s.wont_include("aptitude-was-invoked")
  end

  it "warns and drops the flags aptitude does not support" do
    fake = write_fake_aptitude("0 packages upgraded, 0 newly installed, 0 to remove and 0 not upgraded.", 0)

    result = PluginSpecHelper.run("apt", {
      "upgrade"            => "safe",
      "fail_on_autoremove" => "true",
      "allow_downgrade"    => "true",
      "_aptitude_paths"    => fake,
      "lock_timeout"       => "1",
    })

    # Real upgrade(): m.warn for both, then exit_json - the warnings
    # attach to the result, and neither --no-remove nor --allow-downgrades
    # reaches the aptitude command line (the fake's fixed output would
    # have failed on an unknown-flag abort only if it parsed argv; the
    # warnings key itself is the pinned contract here).
    warnings = result["warnings"].as_a.map(&.as_s)
    warnings.must_equal([
      "APTITUDE does not support '--no-remove', ignoring the 'fail_on_autoremove' parameter.",
      "APTITUDE does not support '--allow-downgrades', ignoring the 'allow_downgrade' parameter.",
    ])
  end
end
