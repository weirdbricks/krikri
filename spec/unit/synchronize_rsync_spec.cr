require "../spec_helper"
require "../../src/krikri/plugin_helpers/synchronize_rsync"

# Unit specs for the synchronize (ansible.posix) rsync-invocation core:
# argv construction ported from real ansible.posix's
# plugins/modules/synchronize.py, and the itemize-changes protocol its
# changed detection rides on. The integration specs
# (spec/integration/synchronize_spec.cr) exercise the same code against a
# real rsync; these pin the flag algebra without needing the binary.
describe Krikri::SynchronizeRsync do
  describe "build_argv" do
    it "matches the real module's default flag set (delay-updates -F, compress, archive)" do
      argv = Krikri::SynchronizeRsync.build_argv("/a", "/b", Hash(String, String).new)
      argv.should eq([
        "rsync", "--delay-updates", "-F", "--compress", "--archive",
        "--out-format=<<CHANGED>>%i %n%L", "/a", "/b",
      ])
    end

    it "suppresses compress/delay-updates when explicitly false" do
      argv = Krikri::SynchronizeRsync.build_argv("/a", "/b", {
        "compress"      => "false",
        "delay_updates" => "no",
      })
      argv.should_not contain("--compress")
      argv.should_not contain("--delay-updates")
    end

    it "adds --no-X for toggles explicitly turned off under a default-on archive" do
      argv = Krikri::SynchronizeRsync.build_argv("/a", "/b", {
        "recursive" => "false",
        "times"     => "no",
        "group"     => "0",
      })
      argv.should contain("--no-recursive")
      argv.should contain("--no-times")
      argv.should contain("--no-group")
      argv.should_not contain("--no-perms")
      argv.should_not contain("--recursive")
    end

    it "uses individual flags instead of --archive when archive is false" do
      argv = Krikri::SynchronizeRsync.build_argv("/a", "/b", {
        "archive"   => "false",
        "recursive" => "yes",
        "links"     => "yes",
      })
      argv.should contain("--recursive")
      argv.should contain("--links")
      argv.should_not contain("--archive")
      argv.should_not contain("--perms")
    end

    it "maps the documented flag spellings" do
      argv = Krikri::SynchronizeRsync.build_argv("/a", "/b", {
        "delete"        => "true",
        "existing_only" => "true",
        "checksum"      => "true",
        "copy_links"    => "true",
        "dirs"          => "true",
        "partial"       => "true",
      })
      argv.should contain("--delete-after")
      argv.should contain("--existing")
      argv.should contain("--checksum")
      argv.should contain("--copy-links")
      argv.should contain("--dirs")
      argv.should contain("--partial")
    end

    it "adds --timeout for rsync_timeout and --rsync-path for rsync_path" do
      argv = Krikri::SynchronizeRsync.build_argv("/a", "/b", {
        "rsync_timeout" => "30",
        "rsync_path"    => "sudo rsync",
      })
      argv.should contain("--timeout=30")
      argv.should contain("--rsync-path=sudo rsync")
    end

    it "adds no --timeout when rsync_timeout is absent or zero" do
      argv = Krikri::SynchronizeRsync.build_argv("/a", "/b", {"rsync_timeout" => "0"})
      argv.none? { |arg| arg.starts_with?("--timeout") }.should be_true
    end

    it "appends raw rsync_opts (JSON array or comma-separated forms)" do
      json_form = Krikri::SynchronizeRsync.build_argv("/a", "/b", {
        "rsync_opts" => %(["--no-motd", "--exclude=.git"]).to_json,
      })
      json_form.should contain("--no-motd")
      json_form.should contain("--exclude=.git")

      csv_form = Krikri::SynchronizeRsync.build_argv("/a", "/b", {
        "rsync_opts" => "--exclude=foo, --exclude=bar",
      })
      csv_form.should contain("--exclude=foo")
      csv_form.should contain("--exclude=bar")
    end

    it "adds -H -vv and absolute --link-dest for link_dest" do
      argv = Krikri::SynchronizeRsync.build_argv("/a", "/b", {
        "link_dest" => %(["/snap/shot"]).to_json,
      })
      argv.should contain("-H")
      argv.should contain("-vv")
      argv.should contain("--link-dest=/snap/shot")
    end

    it "builds --rsh with the real module's ssh options for remote paths" do
      argv = Krikri::SynchronizeRsync.build_argv("/local", "root@web:/remote", {
        "dest_port" => "2222",
      }, private_key: "/id_ed25519", dest_port: 2222)
      rsh = argv.find! { |arg| arg.starts_with?("--rsh=") }
      rsh.should contain("ssh -S none")
      rsh.should contain("-i /id_ed25519")
      rsh.should contain("-o Port=2222")
      rsh.should contain("-o StrictHostKeyChecking=no")
      rsh.should contain("-o UserKnownHostsFile=/dev/null")
    end

    it "omits the host-key-check pair when verify_host is true" do
      argv = Krikri::SynchronizeRsync.build_argv("/local", "root@web:/remote", {
        "verify_host" => "yes",
      }, dest_port: 22)
      rsh = argv.find! { |arg| arg.starts_with?("--rsh=") }
      rsh.should_not contain("StrictHostKeyChecking")
    end

    it "adds no --rsh for two local paths" do
      argv = Krikri::SynchronizeRsync.build_argv("/a", "/b", Hash(String, String).new, dest_port: 22)
      argv.none? { |arg| arg.starts_with?("--rsh=") }.should be_true
    end

    it "respects an rsync_opts-supplied --rsh instead of its own" do
      argv = Krikri::SynchronizeRsync.build_argv("/local", "root@web:/remote", {
        "rsync_opts" => %(["--rsh=/usr/bin/ssh -p 2222"]).to_json,
      }, dest_port: 22)
      argv.any? { |arg| arg.starts_with?("--rsh=ssh -S none") }.should be_false
      argv.should contain("--rsh=/usr/bin/ssh -p 2222")
    end
  end

  describe "format_rsh_target" do
    it "prefixes user@host: for a plain remote path" do
      Krikri::SynchronizeRsync.format_rsh_target("web", "/srv", "deploy")
        .should eq("deploy@web:/srv")
    end

    it "omits user@ when there is no inventory user" do
      Krikri::SynchronizeRsync.format_rsh_target("web", "/srv", nil)
        .should eq("web:/srv")
    end

    it "leaves an already-qualified user@host:path untouched" do
      Krikri::SynchronizeRsync.format_rsh_target("web", "other@web:/srv", "deploy")
        .should eq("other@web:/srv")
    end

    it "leaves an rsync:// URL untouched" do
      Krikri::SynchronizeRsync.format_rsh_target("web", "rsync://web/mod", "deploy")
        .should eq("rsync://web/mod")
    end

    it "brackets IPv6 hosts" do
      Krikri::SynchronizeRsync.format_rsh_target("::1", "/srv", "deploy")
        .should eq("[deploy@::1]:/srv")
    end
  end

  describe "changed?" do
    it "is false for an empty (no-op) rsync output" do
      Krikri::SynchronizeRsync.changed?("").should be_false
      Krikri::SynchronizeRsync.changed?("some warning text\n").should be_false
    end

    it "is true when any itemize line is present" do
      Krikri::SynchronizeRsync.changed?("<<CHANGED>>>f.st...... file.txt\n").should be_true
      Krikri::SynchronizeRsync.changed?("<<CHANGED>>cd+++++++++ dir/\n").should be_true
      Krikri::SynchronizeRsync.changed?("<<CHANGED>>*deleting   stale.txt\n").should be_true
    end

    it "treats a leading . itemize char as no-change only under link_dest" do
      out_var = "<<CHANGED>>.f........ hardlinked.txt\n"
      Krikri::SynchronizeRsync.changed?(out_var, link_dest: true).should be_false
      Krikri::SynchronizeRsync.changed?(out_var).should be_true
      Krikri::SynchronizeRsync.changed?("<<CHANGED>>>f.st...... changed.txt\n", link_dest: true).should be_true
    end
  end

  describe "clean_output" do
    it "keeps one line per real change with markers and blanks stripped" do
      Krikri::SynchronizeRsync.clean_output("<<CHANGED>>>f.st...... a\n\n<<CHANGED>>cd+++++++++ b\n")
        .should eq(">f.st...... a\ncd+++++++++ b")
    end
  end

  describe "parse_list" do
    it "handles JSON arrays, python-repr lists, comma separation, and nil" do
      Krikri::SynchronizeRsync.parse_list(%(["--a", "--b"])).should eq(["--a", "--b"])
      Krikri::SynchronizeRsync.parse_list("['--a', '--b']").should eq(["--a", "--b"])
      Krikri::SynchronizeRsync.parse_list("--a, --b").should eq(["--a", "--b"])
      Krikri::SynchronizeRsync.parse_list(nil).should eq([] of String)
    end
  end
end
