require "../spec_helper"

# Real bug found benchmarking bertvv.mariadb's own "Add official
# MariaDB repository (yum)" task (template: dest: /etc/yum.repos.d/
# MariaDB.repo, on an Ubuntu host where /etc/yum.repos.d never
# exists). Real ansible-playbook fails with "Destination directory
# /etc/yum.repos.d does not exist" - template/copy do NOT create a
# missing single-file destination's parent directory. Both plugins
# used to silently `Dir.mkdir_p` it instead, which only diverged from
# real Ansible once the parent genuinely didn't exist yet (the common
# case - dest already inside an existing dir - never hit this path).
describe "template/copy plugins - missing destination directory" do
  it "template fails like real Ansible instead of creating the missing parent dir" do
    missing_parent = File.join(Dir.tempdir, "krikri-missing-dest-#{Random.new.hex(8)}")
    dest = File.join(missing_parent, "file.conf")

    result = PluginSpecHelper.run("template", {"content" => "hello {{ name }}\n", "dest" => dest}, {"name" => "world"})

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should eq("Destination directory #{missing_parent} does not exist")
    Dir.exists?(missing_parent).should be_false
  end

  it "copy (content:) fails like real Ansible instead of creating the missing parent dir" do
    missing_parent = File.join(Dir.tempdir, "krikri-missing-dest-#{Random.new.hex(8)}")
    dest = File.join(missing_parent, "file.txt")

    result = PluginSpecHelper.run("copy", {"content" => "hello\n", "dest" => dest})

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should eq("Destination directory #{missing_parent} does not exist")
    Dir.exists?(missing_parent).should be_false
  end

  it "copy (src:) fails like real Ansible instead of creating the missing parent dir" do
    src = File.tempname("krikri-copy-src")
    File.write(src, "hello\n")
    missing_parent = File.join(Dir.tempdir, "krikri-missing-dest-#{Random.new.hex(8)}")
    dest = File.join(missing_parent, "file.txt")

    result = PluginSpecHelper.run("copy", {"src" => src, "dest" => dest})

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should eq("Destination directory #{missing_parent} does not exist")
    Dir.exists?(missing_parent).should be_false
  ensure
    File.delete(src) if src && File.exists?(src)
  end
end
