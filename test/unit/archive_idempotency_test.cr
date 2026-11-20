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

  it "reports changed when a log-like member grows between runs (ansible's own syslog writes do this to /var/log)" do
    work = PluginSpecHelper.tmp_path("archive-idem-growth")
    src = make_idem_src("archive-idem-growth-src")
    Dir.mkdir_p(work)
    dest = File.join(work, "pack.tar.bz2")

    PluginSpecHelper.run("archive", {"path" => src, "dest" => dest, "format" => "bz2", "mode" => "0644"})
    File.open(File.join(src, "a.txt"), "a") { |log| log.print("Invoked with\n") }
    File.touch(File.join(src, "a.txt"), Time.utc(2030, 1, 1))

    result = PluginSpecHelper.run("archive", {"path" => src, "dest" => dest, "format" => "bz2", "mode" => "0644"})
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
    # A write-only (0200) dest is unreadable but still rewritable, so the
    # plugin must fall back to real's size-only comparison. As root
    # nothing is unreadable, so the fallback cannot be exercised at all.
    skip "running as root: nothing is unreadable, so the size-only fallback cannot be exercised" if PluginSpecHelper.running_as_root?

    work = PluginSpecHelper.tmp_path("archive-idem-unreadable")
    src = make_idem_src("archive-idem-unreadable-src")
    Dir.mkdir_p(work)
    dest = File.join(work, "pack.tar.gz")

    first = PluginSpecHelper.run("archive", {"path" => src, "dest" => dest, "format" => "gz"})
    first["changed"].as_bool.must_equal(true)
    built_size = File.size(dest)

    ["x" * built_size, "x" * (built_size + 1)].each_with_index do |garbage, i|
      File.chmod(dest, 0o600)
      File.write(dest, garbage)
      File.chmod(dest, 0o200)

      result = PluginSpecHelper.run("archive", {"path" => src, "dest" => dest, "format" => "gz"})
      result["changed"].as_bool.must_equal(i == 1)
    end
  ensure
    FileUtils.rm_rf(src) if src
    FileUtils.rm_rf(work) if work
  end

  it "fails like real when dest can be neither read nor written" do
    # Real rewrites dest in place, so a mode-0000 dest is a hard failure
    # (live-verified vs ansible-playbook 2.21.6 as a non-root user): the
    # single-file compression path reports "Unable to write to compressed
    # file: [Errno 13] Permission denied: '<dest>'".
    skip "running as root: a 0000 dest is still writable, so the failure cannot be exercised" if PluginSpecHelper.running_as_root?

    work = PluginSpecHelper.tmp_path("archive-idem-unwritable")
    Dir.mkdir_p(work)
    # A single-FILE source: that is the compress path
    # (add_single_target), whose failure wording differs from tar/zip's.
    src = File.join(work, "source.txt")
    File.write(src, "compress me\n")
    dest = File.join(work, "pack.gz")

    PluginSpecHelper.run("archive", {"path" => src, "dest" => dest, "format" => "gz"})
    File.chmod(dest, 0o000)

    result = PluginSpecHelper.run("archive", {"path" => src, "dest" => dest, "format" => "gz"})
    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal("Unable to write to compressed file: [Errno 13] Permission denied: '#{dest}'")
  ensure
    FileUtils.rm_rf(src) if src
    FileUtils.rm_rf(work) if work
  end
end

# community.general.archive's --check branch. Live-verified against
# ansible-playbook 2.21.6: with targets and an existing dest nothing is
# written, `destination_state` stays the STATE_ABSENT it was initialised
# to, `archived` stays empty, and `changed` is dest-absent/must_archive
# OR'd with update_permissions' pending owner:/group:/mode:/attributes:
# differences - so a seeded dest whose only difference is the requested
# mode still reports changed while staying byte- and mode-identical.
describe "archive check mode" do
  it "reports changed for a pending mode without touching the dest" do
    work = PluginSpecHelper.tmp_path("archive-check-mode")
    src = File.join(work, "tree", "b.conf")
    Dir.mkdir_p(File.dirname(src))
    File.write(src, "kpg-b\n")
    dest = File.join(work, "dest-0444.txt")
    File.write(dest, "kpg locked dest\nsecond line\n")
    File.chmod(dest, 0o444)

    result = PluginSpecHelper.run("archive", {
      "path"                => src,
      "dest"                => dest,
      "format"              => "gz",
      "mode"                => "0440",
      "_ansible_check_mode" => "true",
    })

    result["changed"].as_bool.must_equal(true)
    result["dest_state"].as_s.must_equal("absent")
    result["archived"].as_a.must_be_empty
    result["mode"].as_s.must_equal("0444")
    File.info(dest).permissions.value.must_equal(0o444)
    File.read(dest).must_equal("kpg locked dest\nsecond line\n")
  ensure
    FileUtils.rm_rf(work) if work
  end

  it "reports ok once the archive and its mode already match, still writing nothing" do
    work = PluginSpecHelper.tmp_path("archive-check-converged")
    src = File.join(work, "source.txt")
    Dir.mkdir_p(work)
    File.write(src, "compress me\n")
    dest = File.join(work, "pack.gz")

    PluginSpecHelper.run("archive", {"path" => src, "dest" => dest, "format" => "gz", "mode" => "0640"})
    info = File.info(dest)

    result = PluginSpecHelper.run("archive", {
      "path"                => src,
      "dest"                => dest,
      "format"              => "gz",
      "mode"                => "0640",
      "_ansible_check_mode" => "true",
    })

    result["changed"].as_bool.must_equal(false)
    result["dest_state"].as_s.must_equal("absent")
    result["archived"].as_a.must_be_empty
    File.info(dest).modification_time.must_equal(info.modification_time)
    File.info(dest).size.must_equal(info.size)
  ensure
    FileUtils.rm_rf(work) if work
  end

  it "reports changed for a missing dest and creates nothing" do
    work = PluginSpecHelper.tmp_path("archive-check-absent")
    src = File.join(work, "source.txt")
    Dir.mkdir_p(work)
    File.write(src, "compress me\n")
    dest = File.join(work, "pack.gz")

    result = PluginSpecHelper.run("archive", {
      "path"                => src,
      "dest"                => dest,
      "format"              => "gz",
      "_ansible_check_mode" => "true",
    })

    result["changed"].as_bool.must_equal(true)
    result["dest_state"].as_s.must_equal("absent")
    result["archived"].as_a.must_be_empty
    File.exists?(dest).must_equal(false)
  ensure
    FileUtils.rm_rf(work) if work
  end

  it "reports changed for a must_archive shape and keeps the sources" do
    work = PluginSpecHelper.tmp_path("archive-check-must-archive")
    src = File.join(work, "tree")
    Dir.mkdir_p(src)
    File.write(File.join(src, "a.txt"), "alpha\n")
    dest = File.join(work, "pack.tar")

    result = PluginSpecHelper.run("archive", {
      "path"                => src,
      "dest"                => dest,
      "format"              => "tar",
      "remove"              => "true",
      "_ansible_check_mode" => "true",
    })

    result["changed"].as_bool.must_equal(true)
    File.exists?(dest).must_equal(false)
    File.exists?(src).must_equal(true)
    File.exists?(File.join(src, "a.txt")).must_equal(true)
  ensure
    FileUtils.rm_rf(work) if work
  end

  it "reports changed in real mode when only the requested mode differs" do
    work = PluginSpecHelper.tmp_path("archive-mode-only")
    src = File.join(work, "source.txt")
    Dir.mkdir_p(work)
    File.write(src, "compress me\n")
    dest = File.join(work, "pack.gz")

    PluginSpecHelper.run("archive", {"path" => src, "dest" => dest, "format" => "gz", "mode" => "0640"})
    File.chmod(dest, 0o640)

    result = PluginSpecHelper.run("archive", {"path" => src, "dest" => dest, "format" => "gz", "mode" => "0600"})

    result["changed"].as_bool.must_equal(true)
    File.info(dest).permissions.value.must_equal(0o600)
  ensure
    FileUtils.rm_rf(work) if work
  end
end

# Python's gzip.open(<dest>, "wb"), which community.general.archive's
# single-file gz path uses, records the DESTINATION's basename in the
# gzip header's FNAME field and marks the stream as maximum-compression
# (XFL 2). The FNAME makes real's dest larger by the name plus its NUL,
# so a playbook that stats the archive sees a different size unless
# krikri writes the same header.
describe "archive single-file gzip header" do
  it "names the gzip stream after the dest, like Python's gzip.open" do
    work = PluginSpecHelper.tmp_path("archive-gzip-name")
    src = File.join(work, "source.txt")
    Dir.mkdir_p(work)
    File.write(src, "compress me\n")
    dest = File.join(work, "pack-0044.txt")

    PluginSpecHelper.run("archive", {"path" => src, "dest" => dest, "format" => "gz"})

    bytes = File.read(dest).to_slice
    (bytes[3] & 0x08).must_equal(0x08)
    bytes[8].must_equal(2_u8)
    name_end = bytes[10..].index(0_u8) || 0
    String.new(bytes[10, name_end]).must_equal(File.basename(dest))
  ensure
    FileUtils.rm_rf(work) if work
  end
end
