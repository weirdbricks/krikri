require "../minitest_helper"

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

    result["changed"].as_bool.must_equal(true)
    falsey?(result["failed"]?.try(&.as_bool)).must_equal(true)
    File.read(File.join(dest, "a.txt")).must_equal("file a\n")
    File.read(File.join(dest, "sub", "b.txt")).must_equal("file b\n")
  end

  it "copies src as a subdirectory of dest when src: has no trailing /" do
    # Ansible's own rsync-style convention: no trailing slash means
    # src itself becomes a new directory under dest, not just its
    # contents.
    src = File.tempname("copy-dir-spec-src2")
    Dir.mkdir_p(src)
    File.write(File.join(src, "c.txt"), "file c\n")

    dest = File.tempname("copy-dir-spec-dest2")
    Dir.mkdir_p(dest)
    result = PluginSpecHelper.run("copy", {"src" => src, "dest" => dest})

    result["changed"].as_bool.must_equal(true)
    basename = File.basename(src)
    File.read(File.join(dest, basename, "c.txt")).must_equal("file c\n")
  end

  it "keeps the user's src basename when src is a staged scratch dir" do
    # After TaskExecutor#stage_directory_copy_source SCPs a directory tree
    # to the target, the plugin's src is a random-named scratch dir whose
    # CONTENTS are the user's directory (scp -r debian host:scratch makes
    # scratch itself a copy of debian) - so the dest/<basename> subdir
    # must come from __original_src_basename, not File.basename(src).
    # Found live via derbunman.debuild_rofi's `copy: src: debian`, which
    # landed as dest/.krikri-playbook-copy-dir-<hex>/ and made the role's
    # following `test -d debian` command fail where Ansible succeeds.
    scratch = File.tempname("krikri-playbook-copy-dir")
    Dir.mkdir_p(scratch)
    File.write(File.join(scratch, "control"), "Package: rofi\n")

    dest = File.tempname("copy-dir-spec-dest4")
    Dir.mkdir_p(dest)
    result = PluginSpecHelper.run("copy", {
      "src"                     => scratch,
      "dest"                    => dest,
      "__original_src_basename" => "debian",
    })

    result["changed"].as_bool.must_equal(true)
    File.read(File.join(dest, "debian", "control")).must_equal("Package: rofi\n")
    Dir.exists?(File.join(dest, File.basename(scratch))).must_equal(false)
  end

  it "is idempotent on a second run with unchanged content" do
    src = File.tempname("copy-dir-spec-src3")
    Dir.mkdir_p(src)
    File.write(File.join(src, "d.txt"), "file d\n")

    dest = File.tempname("copy-dir-spec-dest3")
    first = PluginSpecHelper.run("copy", {"src" => "#{src}/", "dest" => "#{dest}/"})
    first["changed"].as_bool.must_equal(true)

    second = PluginSpecHelper.run("copy", {"src" => "#{src}/", "dest" => "#{dest}/"})
    second["changed"].as_bool.must_equal(false)
  end
end
