require "../minitest_helper"
require "file_utils"

# Zip-slip / hostile-archive regression specs for the unarchive plugin.
#
# Archive contents are attacker-controlled whenever src: is (remote_src
# archives, downloaded URLs, artifacts from a compromised build), and the
# plugin runs ON THE TARGET - typically as root under become:. A hostile
# archive must never be able to make krikri write, chmod or chown anything
# outside dest, and must never make krikri dereference a symlink member.
#
# Everything here was live-verified against real ansible-playbook 2.19.11
# (same vectors, same archives): real Ansible stays safe on every one of
# them - GNU tar refuses `..` members at extraction (exit 2), Info-ZIP
# unzip strips `../`/leading-`/` components and exits 1 (a warning real
# Ansible fails the task on, which is why extract_zip must not use -q:
# -q suppresses the warning AND the nonzero exit), and real Ansible's
# attribute pass uses os.lchown / chmod-with-restore so it never follows
# a symlink member either.
# crystal spec created this once in Spec.before_suite (rm_rf + mkdir
# fresh); the minitest entrypoint runs file-level setup at require time
# instead, unique per process.
private SLIP_DIR = File.join(Dir.tempdir, "unarchive-zip-slip-#{Random::Secure.hex(4)}")

# The canary lives OUTSIDE every dest used below, at
# SLIP_DIR/slip-canary - a hostile member name `../../slip-canary`
# relative to any `<SLIP_DIR>/<dest>` resolves exactly onto it, so any
# surviving escape shows up as a mode/content change on this file.
private CANARY = File.join(SLIP_DIR, "slip-canary")

private def reset_canary : Nil
  FileUtils.rm_rf(CANARY) if File.exists?(CANARY) || File.symlink?(CANARY)
  File.write(CANARY, "CANARY-SECRET")
  File.chmod(CANARY, 0o600)
end

private def fresh_dest(name : String) : String
  path = File.join(SLIP_DIR, name)
  FileUtils.rm_rf(path) if Dir.exists?(path) || File.symlink?(path)
  Dir.mkdir_p(path)
  path
end

FileUtils.rm_rf(SLIP_DIR) if Dir.exists?(SLIP_DIR)
Dir.mkdir_p(SLIP_DIR)
reset_canary

python = <<-PY
    import tarfile, zipfile, io, os
    d = #{SLIP_DIR.inspect}
    canary = #{CANARY.inspect}

    # tar whose second member escapes dest with '..' (GNU tar refuses it
    # at extraction, exit 2)
    with tarfile.open(os.path.join(d, "dotdot.tar"), "w") as t:
        ti = tarfile.TarInfo("good.txt"); ti.size = 5
        t.addfile(ti, io.BytesIO(b"hello"))
        ti = tarfile.TarInfo("../../slip-canary"); ti.size = 6
        t.addfile(ti, io.BytesIO(b"dotdot"))

    # zip with the same escaping member (Info-ZIP unzip strips it with a
    # warning and exits 1 - the exit code that must NOT be swallowed)
    with zipfile.ZipFile(os.path.join(d, "dotdot.zip"), "w") as z:
        z.writestr("good.txt", "hello")
        z.writestr("../../slip-canary", "dotdot")

    # tar + zip carrying a symlink member pointing straight at the
    # canary, alongside only benign members (so extraction exits 0 and
    # the post-extraction attribute pass is reached)
    for name, maker in (("slip-link.tar", tarfile.open), ("slip-link.zip", zipfile.ZipFile)):
        with maker(os.path.join(d, name), "w") as a:
            if name.endswith(".tar"):
                ti = tarfile.TarInfo("good.txt"); ti.size = 5
                a.addfile(ti, io.BytesIO(b"hello"))
                ti = tarfile.TarInfo("evil"); ti.type = tarfile.SYMTYPE
                ti.linkname = canary
                a.addfile(ti)
            else:
                a.writestr("good.txt", "hello")
                zi = zipfile.ZipInfo("evil"); zi.create_system = 3
                zi.external_attr = (0o120777 << 16)
                a.writestr(zi, canary)

    # symlink-DIRECTORY member followed by a member written THROUGH it
    # (the classic symlink-then-file zip-slip) for both formats
    for name, maker in (("dirlink.tar", tarfile.open), ("dirlink.zip", zipfile.ZipFile)):
        with maker(os.path.join(d, name), "w") as a:
            if name.endswith(".tar"):
                ti = tarfile.TarInfo("d"); ti.type = tarfile.SYMTYPE
                ti.linkname = os.path.join(d, "outside")
                a.addfile(ti)
                ti = tarfile.TarInfo("d/pwned.txt"); ti.size = 6
                a.addfile(ti, io.BytesIO(b"THRU-D"))
            else:
                zi = zipfile.ZipInfo("d"); zi.create_system = 3
                zi.external_attr = (0o120777 << 16)
                a.writestr(zi, os.path.join(d, "outside"))
                a.writestr("d/pwned.txt", "THRU-D")

    # absolute member name - must be treated exactly the way tar/unzip/
    # real Ansible treat it: leading '/' stripped, extracted INSIDE dest
    with tarfile.open(os.path.join(d, "abs.tar"), "w") as t:
        ti = tarfile.TarInfo(canary); ti.size = 5
        t.addfile(ti, io.BytesIO(b"hello"))
    PY
Process.run("python3", args: ["-c", python], output: Process::Redirect::Inherit, error: Process::Redirect::Inherit)
raise "hostile archive fixtures failed to build" unless File.exists?(File.join(SLIP_DIR, "dotdot.zip"))

Dir.mkdir_p(File.join(SLIP_DIR, "outside"))

describe "unarchive plugin: hostile-archive (zip-slip class) containment" do
  it "never chmods outside dest via a '..' tar member (extraction refuses it, attributes never run)" do
    reset_canary
    dest = fresh_dest("tar-dotdot")
    result = PluginSpecHelper.run("unarchive", {"src" => File.join(SLIP_DIR, "dotdot.tar"), "dest" => dest, "mode" => "0644"})

    result["failed"].as_bool.must_equal(true)
    File.info(CANARY).permissions.value.must_equal(0o600)
    File.read(CANARY).must_equal("CANARY-SECRET")
  end

  it "never chmods outside dest via a '..' zip member (unzip's rc=1 warning must fail the task, not be swallowed by -q)" do
    reset_canary
    dest = fresh_dest("zip-dotdot")
    result = PluginSpecHelper.run("unarchive", {"src" => File.join(SLIP_DIR, "dotdot.zip"), "dest" => dest, "mode" => "0644"})

    result["failed"].as_bool.must_equal(true)
    File.info(CANARY).permissions.value.must_equal(0o600)
    File.read(CANARY).must_equal("CANARY-SECRET")
  end

  it "never chmods through a tar symlink member (real Ansible's set_mode_if_different net effect: target mode unchanged)" do
    reset_canary
    dest = fresh_dest("tar-link")
    result = PluginSpecHelper.run("unarchive", {"src" => File.join(SLIP_DIR, "slip-link.tar"), "dest" => dest, "mode" => "0644"})

    result["changed"].as_bool.must_equal(true)
    File.symlink?(File.join(dest, "evil")).must_equal(true)
    File.info(CANARY).permissions.value.must_equal(0o600)
    File.read(CANARY).must_equal("CANARY-SECRET")
    # the benign member still gets the requested mode
    File.info(File.join(dest, "good.txt")).permissions.value.must_equal(0o644)
  end

  it "never chmods through a zip symlink member" do
    reset_canary
    dest = fresh_dest("zip-link")
    result = PluginSpecHelper.run("unarchive", {"src" => File.join(SLIP_DIR, "slip-link.zip"), "dest" => dest, "mode" => "0644"})

    result["changed"].as_bool.must_equal(true)
    File.symlink?(File.join(dest, "evil")).must_equal(true)
    File.info(CANARY).permissions.value.must_equal(0o600)
    File.read(CANARY).must_equal("CANARY-SECRET")
    File.info(File.join(dest, "good.txt")).permissions.value.must_equal(0o644)
  end

  it "does not write through a tar symlink-directory member (tar refuses: d/pwned.txt cannot be opened)" do
    reset_canary
    dest = fresh_dest("tar-dirlink")
    result = PluginSpecHelper.run("unarchive", {"src" => File.join(SLIP_DIR, "dirlink.tar"), "dest" => dest, "mode" => "0644"})

    result["failed"].as_bool.must_equal(true)
    Dir.children(File.join(SLIP_DIR, "outside")).must_be_empty
    File.read(CANARY).must_equal("CANARY-SECRET")
  end

  it "does not write through a zip symlink-directory member (unzip refuses: checkdir error)" do
    reset_canary
    dest = fresh_dest("zip-dirlink")
    result = PluginSpecHelper.run("unarchive", {"src" => File.join(SLIP_DIR, "dirlink.zip"), "dest" => dest, "mode" => "0644"})

    result["failed"].as_bool.must_equal(true)
    Dir.children(File.join(SLIP_DIR, "outside")).must_be_empty
    File.read(CANARY).must_equal("CANARY-SECRET")
  end

  it "treats an absolute member name the way tar/unzip/real Ansible do: leading '/' stripped, extracted inside dest" do
    reset_canary
    dest = fresh_dest("tar-abs")
    result = PluginSpecHelper.run("unarchive", {"src" => File.join(SLIP_DIR, "abs.tar"), "dest" => dest, "mode" => "0644"})

    # member "/spec/tmp/unarchive-zip-slip/slip-canary" -> dest/<same path
    # minus leading '/'>, NOT the canary itself
    result["changed"].as_bool.must_equal(true)
    File.exists?(File.join(dest, CANARY.lstrip('/'))).must_equal(true)
    File.info(CANARY).permissions.value.must_equal(0o600)
    File.read(CANARY).must_equal("CANARY-SECRET")
  end

  it "stays idempotent on a benign archive with a symlink member when mode: is set (mode exempt from the --compare diff)" do
    dest = fresh_dest("link-idempotent")
    params = {"src" => File.join(SLIP_DIR, "slip-link.tar"), "dest" => dest, "mode" => "0644"}
    first = PluginSpecHelper.run("unarchive", params)
    first["changed"].as_bool.must_equal(true)

    second = PluginSpecHelper.run("unarchive", params)
    second["changed"].as_bool.must_equal(false)
    File.info(CANARY).permissions.value.must_equal(0o600)
  end
end
