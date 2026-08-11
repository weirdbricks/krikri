require "../spec_helper"
require "system/user"

describe "copy plugin - owner/group" do
  it "actually applies owner: (previously a dead stub, never chown'd at all)" do
    # Real bug found benchmarking cloudalchemy.grafana's own "Create/
    # Update dashboards file (provisioning)" task (copy: content: ...,
    # owner: root, group: grafana) - apply_file_attributes' own owner:/
    # group: handling was a literal no-op stub ("Would need: File.chown
    # - not available in Crystal stdlib", which is simply wrong; file.cr
    # already uses File.chown successfully elsewhere in this codebase).
    # The file silently kept its default group (whatever the process
    # happened to be running as), which meant Grafana's own service user
    # couldn't read its own dashboard provisioning config - the whole
    # service refused to start.
    #
    # No root needed here: chown-ing a file to the CURRENT user's own
    # uid is always permitted, and is enough to exercise the previously-
    # dead code path.
    dest = File.tempname("copy-owner-spec")
    me = System::User.find_by?(id: LibC.getuid.to_s).not_nil!.username

    result = PluginSpecHelper.run("copy", {"content" => "hello\n", "dest" => dest, "owner" => me})

    result["changed"].as_bool.should be_true
    File.info(dest).owner_id.should eq(LibC.getuid.to_s)
  ensure
    File.delete(dest) if dest && File.exists?(dest)
  end
end
