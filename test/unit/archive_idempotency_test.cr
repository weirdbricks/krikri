require "../minitest_helper"
require "file_utils"

# Pins plugins/archive.cr's rerun comparison against real
# community.general.archive's semantics (round 5466309
# deekayen.log_mailer): the module always rebuilds dest and compares the
# pre-rewrite destination's checksum set against the rebuilt one. For
# the tar formats that set is (member name, tar header chksum) pairs,
# so a member mtime change re-reports changed even when every member's
# content is byte-identical - verified live against ansible-playbook
# 2.19.11: an untouched rerun is changed=false, a touch -m-only rerun
# changed=true, a content append changed=true. Runs the compiled plugin
# binary via PluginSpecHelper.
private def make_idem_src(prefix : String) : String
  src = File.join(PluginSpecHelper.tmp_path(prefix), "src")
  Dir.mkdir_p(src)
  File.write(File.join(src, "a.txt"), "alpha\n")
  File.write(File.join(src, "b.txt"), "beta\n")
  src
end

describe "archive rerun idempotency" do
  it "reports ok on an untouched rerun (real is not always-rebuild-changed)" do
    work = PluginSpecHelper.tmp_path("archive-idem-untouched")
    src = make_idem_src("archive-idem-untouched-src")
    Dir.mkdir_p(work)
    dest = File.join(work, "pack.tar.gz")

    first = PluginSpecHelper.run("archive", {"path" => src, "dest" => dest, "format" => "gz"})
    first["changed"].as_bool.must_equal(true)

    second = PluginSpecHelper.run("archive", {"path" => src, "dest" => dest, "format" => "gz"})
    second["changed"].as_bool.must_equal(false)
  ensure
    FileUtils.rm_rf(src) if src
    FileUtils.rm_rf(work) if work
  end

  it "reports changed on a rerun after only a member mtime change (contents untouched)" do
    work = PluginSpecHelper.tmp_path("archive-idem-mtime")
    src = make_idem_src("archive-idem-mtime-src")
    Dir.mkdir_p(work)
    dest = File.join(work, "pack.tar.bz2")

    PluginSpecHelper.run("archive", {"path" => src, "dest" => dest, "format" => "bz2", "mode" => "0644"})
    File.touch(File.join(src, "a.txt"), Time.utc(2020, 1, 1))

    result = PluginSpecHelper.run("archive", {"path" => src, "dest" => dest, "format" => "bz2", "mode" => "0644"})
    result["changed"].as_bool.must_equal(true)
  ensure
    FileUtils.rm_rf(src) if src
    FileUtils.rm_rf(work) if work
  end

  it "reports changed on a rerun after member content changes" do
    work = PluginSpecHelper.tmp_path("archive-idem-content")
    src = make_idem_src("archive-idem-content-src")
    Dir.mkdir_p(work)
    dest = File.join(work, "pack.tar.gz")

    PluginSpecHelper.run("archive", {"path" => src, "dest" => dest, "format" => "gz"})
    File.write(File.join(src, "b.txt"), "beta\nmore\n")

    result = PluginSpecHelper.run("archive", {"path" => src, "dest" => dest, "format" => "gz"})
    result["changed"].as_bool.must_equal(true)
  ensure
    FileUtils.rm_rf(src) if src
    FileUtils.rm_rf(work) if work
  end

  it "stays content-sensitive only for zip (real compares filename+CRC, no mtimes)" do
    work = PluginSpecHelper.tmp_path("archive-idem-zip")
    src = make_idem_src("archive-idem-zip-src")
    Dir.mkdir_p(work)
    dest = File.join(work, "pack.zip")

    PluginSpecHelper.run("archive", {"path" => src, "dest" => dest, "format" => "zip"})
    File.touch(File.join(src, "a.txt"), Time.utc(2020, 1, 1))

    result = PluginSpecHelper.run("archive", {"path" => src, "dest" => dest, "format" => "zip"})
    result["changed"].as_bool.must_equal(false)
  ensure
    FileUtils.rm_rf(src) if src
    FileUtils.rm_rf(work) if work
  end

  it "stays ok for a same-second, same-size, content-only rewrite (real's header chksum is content-blind)" do
    # Live-verified against ansible-playbook 2.19.11: with size and the
    # second-truncated header mtime unchanged, real's (member name,
    # tar header chksum) set is identical however the bytes differ -
    # its comparison reads no member content - so it reports
    # changed=false, and this pin keeps krikri from re-introducing the
    # content-digest over-sensitivity the old comparison had.
    work = PluginSpecHelper.tmp_path("archive-idem-blind")
    Dir.mkdir_p(work)
    src = File.join(work, "src")
    Dir.mkdir_p(src)
    member = File.join(src, "f.txt")
    File.write(member, "v1")
    dest = File.join(work, "pack.tar.gz")

    PluginSpecHelper.run("archive", {"path" => src, "dest" => dest, "format" => "gz"})
    info = File.info(member)
    File.write(member, "v2")
    File.utime(info.modification_time, info.modification_time, member)

    result = PluginSpecHelper.run("archive", {"path" => src, "dest" => dest, "format" => "gz"})
    result["changed"].as_bool.must_equal(false)
  ensure
    FileUtils.rm_rf(work) if work
  end

  it "falls back to a size-only comparison when dest exists but is unreadable" do
    work = PluginSpecHelper.tmp_path("archive-idem-unreadable")
    src = make_idem_src("archive-idem-unreadable-src")
    Dir.mkdir_p(work)
    dest = File.join(work, "pack.tar.gz")

    first = PluginSpecHelper.run("archive", {"path" => src, "dest" => dest, "format" => "gz"})
    first["changed"].as_bool.must_equal(true)
    built_size = File.size(dest)

    ["x" * built_size, "x" * (built_size + 1)].each_with_index do |garbage, i|
      File.write(dest, garbage)
      File.chmod(dest, 0o000)

      result = PluginSpecHelper.run("archive", {"path" => src, "dest" => dest, "format" => "gz"})
      result["changed"].as_bool.must_equal(i == 1)
    end
  ensure
    FileUtils.rm_rf(src) if src
    FileUtils.rm_rf(work) if work
  end
end
