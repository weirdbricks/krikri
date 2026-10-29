require "../minitest_helper"
require "file_utils"

# fetch's destination-file mode parity (issue #478, deekayen.log_mailer's
# fetched archives: ansible=0664 vs krikri=0644).
#
# Real fetch writes the destination through a plain open(): a NEW dest is
# created 0666 & ~umask (the source's mode never leaks) and a pre-existing
# dest keeps its own mode. The local-connection transfer is FileUtils.cp,
# which re-chmods the destination to the SOURCE's mode in both cases, so
# fetch.cr captures the dest's mode before the transfer and restores it
# after. The expected new-dest mode is read off a control file created in
# the suite process with the same File.open(path, "w", 0o666) call: the
# plugin subprocess inherits the suite's umask, so this stays correct no
# matter what umask the suite runs under.
describe "fetch dest mode" do
  it "creates a new dest with 0666 & ~umask, never the source's mode" do
    dir = PluginSpecHelper.tmp_path("fetch-mode-new")
    FileUtils.mkdir_p(dir)
    src = File.join(dir, "src.txt")
    File.write(src, "fetch me\n")
    File.chmod(src, 0o600)
    dest = File.join(dir, "dest.txt")

    control = File.join(dir, "control.txt")
    File.open(control, "w", 0o666) { }
    expected = File.info(control).permissions.value

    result = PluginSpecHelper.run("fetch", {"src" => src, "dest" => dest, "flat" => "true"})

    result["changed"].as_bool.must_equal(true)
    File.info?(dest).try(&.permissions.value).must_equal(expected)
    # Test validity guard: the source's mode must actually differ from the
    # expected dest mode under any umask below 0o100, or the regression
    # being checked (source-mode leakage via cp) would be invisible.
    File.info(src).permissions.value.wont_equal(expected)
    FileUtils.rm_rf(dir)
  end

  it "keeps a pre-existing dest's own mode while replacing its content" do
    dir = PluginSpecHelper.tmp_path("fetch-mode-existing")
    FileUtils.mkdir_p(dir)
    src = File.join(dir, "src.txt")
    File.write(src, "new content\n")
    File.chmod(src, 0o600)
    dest = File.join(dir, "dest.txt")
    File.write(dest, "old content\n")
    File.chmod(dest, 0o604)

    result = PluginSpecHelper.run("fetch", {"src" => src, "dest" => dest, "flat" => "true"})

    result["changed"].as_bool.must_equal(true)
    File.info?(dest).try(&.permissions.value).must_equal(0o604)
    File.read(dest).must_equal("new content\n")
    FileUtils.rm_rf(dir)
  end
end
