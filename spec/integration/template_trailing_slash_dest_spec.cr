require "../spec_helper"
require "file_utils"

describe "template plugin - directory-style dest (trailing /)" do
  it "appends template basename to a trailing-/ dest whose directory does not exist yet" do
    # Same l3d.unbound failure shape as copy's trailing-slash case: the
    # role's config-fragment tasks pass `dest: /etc/unbound/unbound.conf.d/`
    # (trailing slash, directory created by an earlier file: task in the
    # play). Real Ansible's template appends the template's own basename
    # whenever dest signals a directory; this used to rename the rendered
    # tmp file straight onto the literal directory path and failed with
    # "Not a directory".
    dest_dir = File.join(Dir.tempdir, "krikri-template-trailing-#{Random.new.hex(8)}.d")

    result = PluginSpecHelper.run("template",
      {"content" => "fragment\n", "_rendered_from_template" => "/etc/ansible/roles/l3d.unbound/templates/fragment.conf.j2", "dest" => "#{dest_dir}/"})

    result["failed"].as_bool.should be_false
    result["changed"].as_bool.should be_true
    Dir.exists?(dest_dir).should be_true
    File.read(File.join(dest_dir, "fragment.conf.j2")).should eq("fragment\n")
  ensure
    FileUtils.rm_rf(dest_dir) if dest_dir
  end

  it "appends template basename to an existing directory dest without a trailing /" do
    dest_dir = File.tempname("krikri-template-existing-dir")
    Dir.mkdir_p(dest_dir)

    result = PluginSpecHelper.run("template",
      {"content" => "existing-dir\n", "_rendered_from_template" => "/srv/templates/motd.j2", "dest" => dest_dir})

    result["failed"].as_bool.should be_false
    File.read(File.join(dest_dir, "motd.j2")).should eq("existing-dir\n")
  ensure
    FileUtils.rm_rf(dest_dir) if dest_dir
  end

  it "does not append a basename to a non-directory dest without a trailing /" do
    dest_dir = File.tempname("krikri-template-literal")
    Dir.mkdir_p(dest_dir)
    dest = File.join(dest_dir, "named.conf")

    result = PluginSpecHelper.run("template",
      {"content" => "literal\n", "_rendered_from_template" => "/srv/templates/named.conf.j2", "dest" => dest})

    result["failed"].as_bool.should be_false
    File.read(dest).should eq("literal\n")
    Dir.children(dest_dir).size.should eq(1)
  ensure
    FileUtils.rm_rf(dest_dir) if dest_dir
  end
end
