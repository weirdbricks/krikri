require "../spec_helper"
require "file_utils"

# Pins plugins/archive.cr's dest-already-exists behavior against real
# community.general.archive: when dest exists but is NOT a valid archive
# of the requested format, the real module's dest-checksums fallback
# fails outright for format=tar ("tar is not a valid format" - the
# fallback routes a non-tar dest through _open_compressed_file, which
# fail_json's on "tar") but overwrites with changed=True for every other
# format (gz/bz2/xz/zip fall back to an empty checksum set, and the new
# archive's non-empty set always differs). Confirmed against real
# ansible-playbook via testing/podman-diff/cases/archive_edge_cases.yml
# case B6. Runs the compiled plugin binary via PluginSpecHelper.
private def make_src_dir : String
  src = File.join(Dir.tempdir, "krikri-archive-spec-#{Random::Secure.hex(6)}")
  Dir.mkdir_p(File.join(src, "sub"))
  File.write(File.join(src, "a.txt"), "alpha")
  File.write(File.join(src, "sub", "b.txt"), "beta")
  src
end

describe "archive dest-already-exists-as-plain-file behavior" do
  it "fails changed=False for format=tar over a non-tar dest (matches real fail_json)" do
    src = make_src_dir
    dest = File.join(Dir.tempdir, "krikri-archive-spec-#{Random::Secure.hex(6)}.tar")
    File.write(dest, "not an archive")
    begin
      result = PluginSpecHelper.run("archive", {
        "path"   => src,
        "dest"   => dest,
        "format" => "tar",
      })

      result["failed"].as_bool.should be_true
      result["changed"].as_bool.should be_false
      File.read(dest).should eq("not an archive")
    ensure
      FileUtils.rm_rf(src)
      File.delete?(dest)
    end
  end

  it "overwrites changed=False->True for format=zip over a non-zip dest (matches real)" do
    src = make_src_dir
    dest = File.join(Dir.tempdir, "krikri-archive-spec-#{Random::Secure.hex(6)}.zip")
    File.write(dest, "not an archive")
    begin
      result = PluginSpecHelper.run("archive", {
        "path"   => src,
        "dest"   => dest,
        "format" => "zip",
      })

      # Success results omit "failed" entirely; absence means false.
      result["changed"].as_bool.should be_true
      result["failed"]?.nil?.should be_true
      File.read(dest)[0, 2].should eq("PK")
    ensure
      FileUtils.rm_rf(src)
      File.delete?(dest)
    end
  end
end
