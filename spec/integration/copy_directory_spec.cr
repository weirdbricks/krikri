require "../spec_helper"

describe "copy plugin - directory src" do
  it "copies a directory's contents into dest when src: ends with a trailing /" do
    # Real bug found benchmarking cloudalchemy.prometheus's own
    # "propagate official console templates" task (`src: ".../console_
    # libraries/"`, both src and dest trailing-slash) - directory copy
    # was entirely unimplemented, always "Directory copy not yet
    # implemented".
    src = File.tempname("copy-dir-spec-src")
    Dir.mkdir_p(File.join(src, "sub"))
    File.write(File.join(src, "a.txt"), "file a\n")
    File.write(File.join(src, "sub", "b.txt"), "file b\n")

    dest = File.tempname("copy-dir-spec-dest")
    result = PluginSpecHelper.run("copy", {"src" => "#{src}/", "dest" => "#{dest}/"})

    result["changed"].as_bool.should be_true
    result["failed"].as_bool.should be_false
    File.read(File.join(dest, "a.txt")).should eq("file a\n")
    File.read(File.join(dest, "sub", "b.txt")).should eq("file b\n")
  end

  it "copies src as a subdirectory of dest when src: has no trailing /" do
    # Real Ansible's own rsync-style convention: no trailing slash means
    # src itself becomes a new directory under dest, not just its
    # contents.
    src = File.tempname("copy-dir-spec-src2")
    Dir.mkdir_p(src)
    File.write(File.join(src, "c.txt"), "file c\n")

    dest = File.tempname("copy-dir-spec-dest2")
    Dir.mkdir_p(dest)
    result = PluginSpecHelper.run("copy", {"src" => src, "dest" => dest})

    result["changed"].as_bool.should be_true
    basename = File.basename(src)
    File.read(File.join(dest, basename, "c.txt")).should eq("file c\n")
  end

  it "is idempotent on a second run with unchanged content" do
    src = File.tempname("copy-dir-spec-src3")
    Dir.mkdir_p(src)
    File.write(File.join(src, "d.txt"), "file d\n")

    dest = File.tempname("copy-dir-spec-dest3")
    first = PluginSpecHelper.run("copy", {"src" => "#{src}/", "dest" => "#{dest}/"})
    first["changed"].as_bool.should be_true

    second = PluginSpecHelper.run("copy", {"src" => "#{src}/", "dest" => "#{dest}/"})
    second["changed"].as_bool.should be_false
  end
end
