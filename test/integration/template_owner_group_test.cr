require "../minitest_helper"

# Regression spec for template: ownership application (gokev.motd-splash
# round 5210000): the template plugin's apply_file_attributes shelled out
# to chown/chgrp with stdout, stderr AND the exit status all discarded,
# so a template task whose group: named a nonexistent group silently
# reported changed where real ansible fails the task ("chgrp failed:
# failed to look up group wheel" - ansible's basic.py). The template
# path now goes through BasePlugin#apply_owner_group_mode, which
# resolves the name first and raises Ansible's own text (the copy/file
# plugins already did this - only template: was still shelling blind).
describe "template plugin - owner/group" do
  it "fails with Ansible's exact message when group: names a nonexistent group" do
    dest = File.tempname("template-bad-group-spec")

    result = PluginSpecHelper.run("template", {
      "content" => "splash\n",
      "dest"    => dest,
      "group"   => "no-such-group-krikri-spec",
    })

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal("chgrp failed: failed to look up group no-such-group-krikri-spec")
  ensure
    File.delete(dest) if dest && File.exists?(dest)
  end
end
