require "../minitest_helper"
require "file_utils"

# Round 993003 (kop_storage, warm run): real lvg, on an EXISTING VG, diffs
# the current PV list against the requested pvs and runs vgextend for the
# additions and `vgreduce --force` for the removals (remove_extra_pvs
# defaults to true). The probe role's cold-run cleanup cannot remove kop_vg
# (it still holds kop_lv; real refuses without force=true), so on the warm
# run the VG survived with its old PV while the role attached a fresh loop
# device - real then failed lvg_create/lvg_exists with
# "Unable to reduce kop_vg by /dev/loop3." (rc 5, "still in use") while
# krikri silently vgextend'ed and reported changed:true.
#
# Root-free pins via fake vgs/pvs/pvcreate/vgcreate/vgextend/vgreduce/
# vgremove shims on a restricted child PATH: every mutating command appends
# to a shared log so both the command sequence (real's exact argv shapes,
# including vgreduce's hardcoded --force and vgextend's lack of vg_options)
# and the registered result shapes are asserted.
private VGS_SHIM = "#!/bin/sh\ncat \"$LVG_TEST_DIR/vgs.out\" 2>/dev/null\n"
private PVS_SHIM = <<-SH
#!/bin/sh
if [ -f "$LVG_TEST_DIR/pvs.rc" ]; then
  cat "$LVG_TEST_DIR/pvs.err" >&2
  exit "$(cat "$LVG_TEST_DIR/pvs.rc")"
fi
cat "$LVG_TEST_DIR/pvs.out" 2>/dev/null
SH

private PVCREATE_SHIM = "#!/bin/sh\necho \"pvcreate $*\" >> \"$LVG_TEST_DIR/cmds.log\"\nexit 0\n"
private VGCREATE_SHIM = "#!/bin/sh\necho \"vgcreate $*\" >> \"$LVG_TEST_DIR/cmds.log\"\nexit 0\n"
private VGEXTEND_SHIM = "#!/bin/sh\necho \"vgextend $*\" >> \"$LVG_TEST_DIR/cmds.log\"\nexit 0\n"
private VGREMOVE_SHIM = "#!/bin/sh\necho \"vgremove $*\" >> \"$LVG_TEST_DIR/cmds.log\"\nexit 0\n"

private VGREDUCE_SHIM = <<-SH
  #!/bin/sh
  echo "vgreduce $*" >> "$LVG_TEST_DIR/cmds.log"
  if [ -f "$LVG_TEST_DIR/vgreduce.rc" ]; then
    cat "$LVG_TEST_DIR/vgreduce.err" >&2
    exit "$(cat "$LVG_TEST_DIR/vgreduce.rc")"
  fi
  exit 0
  SH

private def write_lvg_shims(bin_dir : String) : Nil
  FileUtils.mkdir_p(bin_dir)
  {
    "vgs"      => VGS_SHIM,
    "pvs"      => PVS_SHIM,
    "pvcreate" => PVCREATE_SHIM,
    "vgcreate" => VGCREATE_SHIM,
    "vgextend" => VGEXTEND_SHIM,
    "vgreduce" => VGREDUCE_SHIM,
    "vgremove" => VGREMOVE_SHIM,
  }.each do |name, body|
    path = File.join(bin_dir, name)
    File.write(path, body)
    File.chmod(path, 0o755)
  end
end

private def lvg_shim_dir : String
  dir = PluginSpecHelper.tmp_path("lvg-pv-diff")
  FileUtils.mkdir_p(dir)
  write_lvg_shims(File.join(dir, "bin"))
  dir
end

private def lvg_shim_env(dir : String) : Hash(String, String)
  {
    "PATH"         => "#{File.join(dir, "bin")}:#{ENV["PATH"]? || ""}",
    "LVG_TEST_DIR" => dir,
  }
end

private def logged_commands(dir : String) : Array(Array(String))
  log = File.join(dir, "cmds.log")
  return [] of Array(String) unless File.exists?(log)
  File.read_lines(log).map(&.split)
end

describe "lvg plugin - PV diff on an existing VG (round 993003 warm run)" do
  it "pvcreates+vgextends the new PV, then vgreduces the stale one, failing with real's rc/err/message" do
    dir = lvg_shim_dir
    pv_old = File.join(dir, "pv_old")
    pv_new = File.join(dir, "pv_new")
    File.touch(pv_old)
    File.touch(pv_new)
    File.write(File.join(dir, "vgs.out"), "kop_vg;1;1\n")
    File.write(File.join(dir, "pvs.out"), "  #{pv_old};kop_vg\n")
    File.write(File.join(dir, "vgreduce.rc"), "5")
    File.write(File.join(dir, "vgreduce.err"), "  Physical volume \"#{pv_old}\" still in use\n")

    result = PluginSpecHelper.run("lvg", {
      "vg"    => "kop_vg",
      "pvs"   => pv_new,
      "state" => "present",
    }, env: lvg_shim_env(dir))

    result.as_h.keys.must_equal(["rc", "err", "failed", "msg", "changed", "exception"])
    result["failed"].as_bool.must_equal(true)
    result["changed"].as_bool.must_equal(false)
    result["rc"].as_i64.must_equal(5)
    result["err"].as_s.must_equal("  Physical volume \"#{pv_old}\" still in use\n")
    result["msg"].as_s.must_equal("Unable to reduce kop_vg by #{pv_old}.")

    # Real's exact command sequence: adds first (pvcreate -f then vgextend,
    # no vg_options on vgextend), then `vgreduce --force` with the removals.
    logged_commands(dir).must_equal([
      ["pvcreate", "-f", pv_new],
      ["vgextend", "kop_vg", pv_new],
      ["vgreduce", "--force", "kop_vg", pv_old],
    ])
  end

  it "skips the vgreduce when remove_extra_pvs=false" do
    dir = lvg_shim_dir
    pv_old = File.join(dir, "pv_old")
    pv_new = File.join(dir, "pv_new")
    File.touch(pv_old)
    File.touch(pv_new)
    File.write(File.join(dir, "vgs.out"), "kop_vg;1;1\n")
    File.write(File.join(dir, "pvs.out"), "  #{pv_old};kop_vg\n")

    result = PluginSpecHelper.run("lvg", {
      "vg"               => "kop_vg",
      "pvs"              => pv_new,
      "state"            => "present",
      "remove_extra_pvs" => "false",
    }, env: lvg_shim_env(dir))

    falsey?(result["failed"]?.try(&.as_bool)).must_equal(true)
    result["changed"].as_bool.must_equal(true)
    logged_commands(dir).must_equal([
      ["pvcreate", "-f", pv_new],
      ["vgextend", "kop_vg", pv_new],
    ])
  end

  it "reports changed with no commands in check mode when the PV list differs" do
    dir = lvg_shim_dir
    pv_old = File.join(dir, "pv_old")
    pv_new = File.join(dir, "pv_new")
    File.touch(pv_old)
    File.touch(pv_new)
    File.write(File.join(dir, "vgs.out"), "kop_vg;1;1\n")
    File.write(File.join(dir, "pvs.out"), "  #{pv_old};kop_vg\n")

    result = PluginSpecHelper.run("lvg", {
      "vg"                  => "kop_vg",
      "pvs"                 => pv_new,
      "state"               => "present",
      "_ansible_check_mode" => "true",
    }, env: lvg_shim_env(dir))

    result["changed"].as_bool.must_equal(true)
    falsey?(result["failed"]?.try(&.as_bool)).must_equal(true)
    logged_commands(dir).must_be_empty
  end

  it "is idempotent when the requested PVs already match the VG's PVs" do
    dir = lvg_shim_dir
    pv_old = File.join(dir, "pv_old")
    File.touch(pv_old)
    File.write(File.join(dir, "vgs.out"), "kop_vg;1;0\n")
    File.write(File.join(dir, "pvs.out"), "  #{pv_old};kop_vg\n")

    result = PluginSpecHelper.run("lvg", {
      "vg"    => "kop_vg",
      "pvs"   => pv_old,
      "state" => "present",
    }, env: lvg_shim_env(dir))

    result["changed"].as_bool.must_equal(false)
    falsey?(result["failed"]?.try(&.as_bool)).must_equal(true)
    logged_commands(dir).must_be_empty
  end

  it "fails with real's used-PV message when a requested PV belongs to another VG" do
    dir = lvg_shim_dir
    pv_new = File.join(dir, "pv_new")
    pv_other = File.join(dir, "pv_other")
    File.touch(pv_new)
    File.touch(pv_other)
    File.write(File.join(dir, "vgs.out"), "kop_vg;1;0\n")
    File.write(File.join(dir, "pvs.out"), "  #{pv_new};other_vg\n  #{pv_other};kop_vg\n")

    result = PluginSpecHelper.run("lvg", {
      "vg"    => "kop_vg",
      "pvs"   => pv_new,
      "state" => "present",
    }, env: lvg_shim_env(dir))

    result["failed"].as_bool.must_equal(true)
    result["changed"].as_bool.must_equal(false)
    result["msg"].as_s.must_equal("Device #{pv_new} is already in other_vg volume group.")
    logged_commands(dir).must_be_empty
  end

  it "creates PVs then the VG with real's argument order on a fresh VG" do
    dir = lvg_shim_dir
    pv_new = File.join(dir, "pv_new")
    File.touch(pv_new)
    File.write(File.join(dir, "vgs.out"), "")
    File.write(File.join(dir, "pvs.out"), "")

    result = PluginSpecHelper.run("lvg", {
      "vg"    => "kop_vg",
      "pvs"   => pv_new,
      "state" => "present",
    }, env: lvg_shim_env(dir))

    falsey?(result["failed"]?.try(&.as_bool)).must_equal(true)
    result["changed"].as_bool.must_equal(true)
    logged_commands(dir).must_equal([
      ["pvcreate", "-f", pv_new],
      ["vgcreate", "-s", "4", "kop_vg", pv_new],
    ])
  end

  it "refuses to remove a non-empty VG without force=true (real's exact message, no vgremove)" do
    dir = lvg_shim_dir
    File.write(File.join(dir, "vgs.out"), "kop_vg;1;1\n")

    result = PluginSpecHelper.run("lvg", {
      "vg"    => "kop_vg",
      "state" => "absent",
    }, env: lvg_shim_env(dir))

    result["failed"].as_bool.must_equal(true)
    result["changed"].as_bool.must_equal(false)
    result["msg"].as_s.must_equal("Refuse to remove non-empty volume group kop_vg without force=true")
    logged_commands(dir).must_be_empty
  end

  it "removes with vgremove --force when force=true despite the VG holding LVs" do
    dir = lvg_shim_dir
    File.write(File.join(dir, "vgs.out"), "kop_vg;1;1\n")

    result = PluginSpecHelper.run("lvg", {
      "vg"    => "kop_vg",
      "state" => "absent",
      "force" => "true",
    }, env: lvg_shim_env(dir))

    falsey?(result["failed"]?.try(&.as_bool)).must_equal(true)
    result["changed"].as_bool.must_equal(true)
    logged_commands(dir).must_equal([["vgremove", "--force", "kop_vg"]])
  end

  it "surfaces real's Failed executing pvs command. failure with the probe's rc/err" do
    dir = lvg_shim_dir
    pv_new = File.join(dir, "pv_new")
    File.touch(pv_new)
    File.write(File.join(dir, "vgs.out"), "kop_vg;1;0\n")
    File.write(File.join(dir, "pvs.rc"), "7")
    File.write(File.join(dir, "pvs.err"), "pvs boom\n")

    result = PluginSpecHelper.run("lvg", {
      "vg"    => "kop_vg",
      "pvs"   => pv_new,
      "state" => "present",
    }, env: lvg_shim_env(dir))

    result.as_h.keys.must_equal(["rc", "err", "failed", "msg", "changed", "exception"])
    result["failed"].as_bool.must_equal(true)
    result["rc"].as_i64.must_equal(7)
    result["err"].as_s.must_equal("pvs boom\n")
    result["msg"].as_s.must_equal("Failed executing pvs command.")
  end
end
