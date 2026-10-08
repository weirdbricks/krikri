require "../minitest_helper"

# Regression spec for `package:`'s `deb:` dispatch. The package module's
# execute() entry gate returned "Nothing to do" for any task with no
# `name:` BEFORE the backend could see the `deb:` param - so a
# `package: {deb: URL}` task silently reported ok and the .deb never
# landed (rchouinard.mysql-community-repo round 5210000: real installed
# the mysql-apt-config deb (changed=1), krikri reported ok). The deb:
# dispatch now runs at the entry gate, shared verbatim with apt.cr via
# AptDebInstall (verified live in a jammy container: package: deb: URL
# installs changed=1, second run idempotent ok).
describe "package deb: dispatch" do
  it "does not return 'Nothing to do' for a deb:-only task" do
    result = PluginSpecHelper.run("package", {"deb" => "/nonexistent/no-such.deb", "state" => "present"})

    result["msg"].as_s.wont_equal("Nothing to do")
    # the dispatch reaches the shared deb machinery: the missing-file
    # check is install_deb_file's own DebPackage-construction failure
    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal(
      "Unable to install package: E:Could not open file /nonexistent/no-such.deb - open (2: No such file or directory)"
    )
  end

  it "rejects deb: with a non-present state like apt's own dispatch" do
    result = PluginSpecHelper.run("package", {"deb" => "/tmp/whatever.deb", "state" => "absent"})

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal("deb only supports state=present")
  end
end
