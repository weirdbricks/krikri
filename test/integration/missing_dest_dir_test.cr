require "../minitest_helper"

# Real bug found benchmarking bertvv.mariadb's own "Add official
# MariaDB repository (yum)" task (template: dest: /etc/yum.repos.d/
# MariaDB.repo, on an Ubuntu host where /etc/yum.repos.d never
# exists). ansible-playbook fails with "Destination directory
# /etc/yum.repos.d does not exist" - template/copy do NOT create a
# missing single-file destination's parent directory. Both plugins
# used to silently `Dir.mkdir_p` it instead, which only diverged from
# Ansible once the parent genuinely didn't exist yet (the common
# case - dest already inside an existing dir - never hit this path).
describe "template/copy plugins - missing destination directory" do
  it "template fails like Ansible instead of creating the missing parent dir" do
    missing_parent = File.join(Dir.tempdir, "krikri-missing-dest-#{Random.new.hex(8)}")
    dest = File.join(missing_parent, "file.conf")

    result = PluginSpecHelper.run("template", {"content" => "hello {{ name }}\n", "dest" => dest}, {"name" => "world"})

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal("Destination directory #{missing_parent} does not exist")
    Dir.exists?(missing_parent).must_equal(false)
  end

  it "copy (content:) fails like Ansible instead of creating the missing parent dir" do
    missing_parent = File.join(Dir.tempdir, "krikri-missing-dest-#{Random.new.hex(8)}")
    dest = File.join(missing_parent, "file.txt")

    result = PluginSpecHelper.run("copy", {"content" => "hello\n", "dest" => dest})

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal("Destination directory #{missing_parent} does not exist")
    Dir.exists?(missing_parent).must_equal(false)
  end

  it "copy (src:) fails like Ansible instead of creating the missing parent dir" do
    src = File.tempname("krikri-copy-src")
    File.write(src, "hello\n")
    missing_parent = File.join(Dir.tempdir, "krikri-missing-dest-#{Random.new.hex(8)}")
    dest = File.join(missing_parent, "file.txt")

    result = PluginSpecHelper.run("copy", {"src" => src, "dest" => dest})

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal("Destination directory #{missing_parent} does not exist")
    Dir.exists?(missing_parent).must_equal(false)
  ensure
    File.delete(src) if src && File.exists?(src)
  end

  # Round 5210220 (Azulinho.azulinho-yum-repo-epel): a directory-signaled
  # dest (`src=epel.repo dest=/etc/yum.repos.d/`) DOES create the missing
  # directory - copy.py's `dest.endswith(os.sep)` makedirs branch, which
  # only needs the action plugin's _original_basename, i.e. any src:
  # (inlined as content by the executor or staged as a file).
  it "copy (src:) creates a directory-signaled missing dest dir and writes into it" do
    src = File.tempname("krikri-copy-src")
    File.write(src, "hello\n")
    missing_parent = File.join(Dir.tempdir, "krikri-missing-dest-#{Random.new.hex(8)}")
    dest = "#{missing_parent}/"

    result = PluginSpecHelper.run("copy", {"src" => src, "dest" => dest})

    result["changed"].as_bool.must_equal(true)
    Dir.exists?(missing_parent).must_equal(true)
    File.read(File.join(missing_parent, File.basename(src))).must_equal("hello\n")
  ensure
    File.delete(src) if src && File.exists?(src)
  end

  it "copy through the inlined-content path creates a directory-signaled missing dest dir too" do
    missing_parent = File.join(Dir.tempdir, "krikri-missing-dest-#{Random.new.hex(8)}")
    # __original_src_basename is what the executor sets when it inlines a
    # small src: file as content: - the plugin sees content + basename,
    # exactly like Ansible's module after the action's inlining.
    result = PluginSpecHelper.run("copy", {
      "content"                 => "hello\n",
      "dest"                    => "#{missing_parent}/",
      "__original_src_basename" => "epel.repo",
    })

    result["changed"].as_bool.must_equal(true)
    Dir.exists?(missing_parent).must_equal(true)
    File.read(File.join(missing_parent, "epel.repo")).must_equal("hello\n")
  end

  # A bare content: with a directory dest fails in Ansible's copy ACTION
  # plugin ("can not use content with a dir as dest") - both for a
  # trailing-"/" dest and for an existing-directory dest.
  it "copy (bare content:) fails on a trailing-slash dest like Ansible's action plugin" do
    missing_parent = File.join(Dir.tempdir, "krikri-missing-dest-#{Random.new.hex(8)}")

    result = PluginSpecHelper.run("copy", {"content" => "hello\n", "dest" => "#{missing_parent}/"})

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal("can not use content with a dir as dest")
    Dir.exists?(missing_parent).must_equal(false)
  end

  it "copy (bare content:) fails on an existing-directory dest like Ansible's action plugin" do
    existing_dir = File.join(Dir.tempdir, "krikri-existing-dir-#{Random.new.hex(8)}")
    Dir.mkdir_p(existing_dir)

    result = PluginSpecHelper.run("copy", {"content" => "hello\n", "dest" => "#{existing_dir}/"})

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal("can not use content with a dir as dest")
  ensure
    Dir.delete(existing_dir) if existing_dir && Dir.exists?(existing_dir)
  end

  it "template still creates a directory-signaled missing dest dir (now with attributes applied)" do
    missing_parent = File.join(Dir.tempdir, "krikri-missing-dest-#{Random.new.hex(8)}")
    dest = "#{missing_parent}/"

    result = PluginSpecHelper.run("template", {
      "content"                 => "hello world\n",
      "dest"                    => dest,
      "_rendered_from_template" => "tpl.j2",
    })

    result["changed"].as_bool.must_equal(true)
    Dir.exists?(missing_parent).must_equal(true)
    File.read(File.join(missing_parent, "tpl.j2")).must_equal("hello world\n")
  end
end
