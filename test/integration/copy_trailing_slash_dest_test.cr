require "../minitest_helper"
require "file_utils"

describe "copy plugin - directory-style dest (trailing /)" do
  it "appends src basename to a trailing-/ dest whose directory does not exist yet" do
    # Real bug found benchmarking l3d.unbound, whose config-fragment
    # tasks pass `dest: /etc/unbound/unbound.conf.d/` (trailing slash,
    # directory created by an earlier file: task in the play). Real
    # Ansible's copy treats a trailing path separator as an explicit
    # "this is a directory" signal regardless of whether it exists on
    # disk yet; this used to append the basename only when
    # Dir.exists?(dest), so the raw slash-terminated dest reached the
    # final move and failed with "Not a directory".
    src = File.tempname("copy-trailing-slash-src")
    File.write(src, "fragment\n")

    dest_dir = File.join(Dir.tempdir, "krikri-trailing-#{Random.new.hex(8)}.d")

    result = PluginSpecHelper.run("copy", {"src" => src, "dest" => "#{dest_dir}/"})

    falsey?(result["failed"]?.try(&.as_bool)).must_equal(true)
    result["changed"].as_bool.must_equal(true)
    Dir.exists?(dest_dir).must_equal(true)
    File.read(File.join(dest_dir, File.basename(src))).must_equal("fragment\n")
  ensure
    File.delete(src) if src && File.exists?(src)
    FileUtils.rm_rf(dest_dir) if dest_dir
  end

  it "still appends src basename to an existing directory dest without a trailing /" do
    src = File.tempname("copy-existing-dir-src")
    File.write(src, "existing-dir\n")

    dest_dir = File.tempname("copy-existing-dir-dest")
    Dir.mkdir_p(dest_dir)

    result = PluginSpecHelper.run("copy", {"src" => src, "dest" => dest_dir})

    falsey?(result["failed"]?.try(&.as_bool)).must_equal(true)
    File.read(File.join(dest_dir, File.basename(src))).must_equal("existing-dir\n")
  ensure
    File.delete(src) if src && File.exists?(src)
    FileUtils.rm_rf(dest_dir) if dest_dir
  end

  it "does not append a basename to a non-directory dest without a trailing /" do
    src = File.tempname("copy-literal-src")
    File.write(src, "literal\n")

    dest_dir = File.tempname("copy-literal-dest")
    Dir.mkdir_p(dest_dir)
    dest = File.join(dest_dir, "named.conf")

    result = PluginSpecHelper.run("copy", {"src" => src, "dest" => dest})

    falsey?(result["failed"]?.try(&.as_bool)).must_equal(true)
    File.read(dest).must_equal("literal\n")
    Dir.children(dest_dir).size.must_equal(1)
  ensure
    File.delete(src) if src && File.exists?(src)
    FileUtils.rm_rf(dest_dir) if dest_dir
  end
end
