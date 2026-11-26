require "../minitest_helper"

# Regression spec for issue #1851 (mjcramer.java divergence): a template
# task's --check rerun must compare the dest's REAL mode, setuid/setgid/
# sticky bits included.
#
# `mode: 600` written unquoted is a YAML int, so real ansible keeps 600 as
# an int and chmods 600 DECIMAL = 0o1130 (sticky set); its --check rerun on
# that converged host is plain ok, because basic.py compares
# stat.S_IMODE(os.lstat(dest).st_mode) against the requested mode. krikri
# read the current side through Crystal's File::Info#permissions, which
# carries only the 0o777 bits, and called the same converged task changed.
#
# The role's own mode reaches a file with no read bit at all, so these use
# readable special-bit modes (0o4755 setuid, 0o1755 sticky): the comparison
# under test is the same, and a non-root spec process can still open the
# dest it repeats.

describe "template plugin - check mode compares the full mode word" do
  it "reports ok for a converged dest whose mode carries a setuid bit" do
    dest = File.tempname("template-special-mode-converged")
    File.write(dest, "if [ -e /opt/java ]; then\n")
    File.chmod(dest, 0o4755)

    result = PluginSpecHelper.run("template", {
      "content"             => "if [ -e /opt/java ]; then\n",
      "dest"                => dest,
      "mode"                => "4755",
      "_ansible_check_mode" => "true",
    })

    result["changed"].as_bool.must_equal(false)
    File.info(dest).permissions.value.must_equal(0o755)
  ensure
    File.delete(dest) if dest && File.exists?(dest)
  end

  it "reports ok for a converged dest whose mode carries the sticky bit" do
    # The issue's own case: `mode: 600` unquoted resolves to 0o1130, sticky
    # set. 0o1130 has no read bit, so a non-root check run cannot read the
    # converged file at all; 0o1755 is the readable spelling of the same
    # comparison.
    dest = File.tempname("template-special-mode-sticky")
    File.write(dest, "if [ -e /opt/java ]; then\n")
    File.chmod(dest, 0o1755)

    result = PluginSpecHelper.run("template", {
      "content"             => "if [ -e /opt/java ]; then\n",
      "dest"                => dest,
      "mode"                => "1755",
      "_ansible_check_mode" => "true",
    })

    result["changed"].as_bool.must_equal(false)
  ensure
    File.delete(dest) if dest && File.exists?(dest)
  end

  it "reports the special bits on the diff's before side when they differ" do
    dest = File.tempname("template-special-mode-drift")
    File.write(dest, "if [ -e /opt/java ]; then\n")
    File.chmod(dest, 0o4755)

    result = PluginSpecHelper.run("template", {
      "content"             => "if [ -e /opt/java ]; then\n",
      "dest"                => dest,
      "mode"                => "0755",
      "_ansible_check_mode" => "true",
      "_ansible_diff"       => "true",
    }).as_h["diff"]

    result["before"].as_h["mode"].as_s.must_equal("04755")
    result["after"].as_h["mode"].as_s.must_equal("0755")
  ensure
    File.delete(dest) if dest && File.exists?(dest)
  end
end
