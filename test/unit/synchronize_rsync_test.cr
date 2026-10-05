require "../minitest_helper"
require "../../src/krikri/plugin_helpers/synchronize_rsync"

# Unit specs for the synchronize (ansible.posix) rsync-invocation core:
# argv construction behavior matched to Ansible.posix's
# the Ansible module, and the itemize-changes protocol its
# changed detection rides on. The integration specs
# (test/integration/synchronize_test.cr) exercise the same code against a
# real rsync; these pin the flag algebra without needing the binary.
describe Krikri::SynchronizeRsync do
  describe "build_argv" do
    it "matches the Ansible module's default flag set (delay-updates -F, compress, archive)" do
      argv = Krikri::SynchronizeRsync.build_argv("/a", "/b", Hash(String, String).new)
      argv.must_equal([
        "rsync", "--delay-updates", "-F", "--compress", "--archive",
        "--out-format=<<CHANGED>>%i %n%L", "/a", "/b",
      ])
    end

    it "suppresses compress/delay-updates when explicitly false" do
      argv = Krikri::SynchronizeRsync.build_argv("/a", "/b", {
        "compress"      => "false",
        "delay_updates" => "no",
      })
      argv.wont_include("--compress")
      argv.wont_include("--delay-updates")
    end

    it "adds --no-X for toggles explicitly turned off under a default-on archive" do
      argv = Krikri::SynchronizeRsync.build_argv("/a", "/b", {
        "recursive" => "false",
        "times"     => "no",
        "group"     => "0",
      })
      argv.must_include("--no-recursive")
      argv.must_include("--no-times")
      argv.must_include("--no-group")
      argv.wont_include("--no-perms")
      argv.wont_include("--recursive")
    end

    it "uses individual flags instead of --archive when archive is false" do
      argv = Krikri::SynchronizeRsync.build_argv("/a", "/b", {
        "archive"   => "false",
        "recursive" => "yes",
        "links"     => "yes",
      })
      argv.must_include("--recursive")
      argv.must_include("--links")
      argv.wont_include("--archive")
      argv.wont_include("--perms")
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
      argv.must_include("--delete-after")
      argv.must_include("--existing")
      argv.must_include("--checksum")
      argv.must_include("--copy-links")
      argv.must_include("--dirs")
      argv.must_include("--partial")
    end

    it "adds --timeout for rsync_timeout and --rsync-path for rsync_path" do
      argv = Krikri::SynchronizeRsync.build_argv("/a", "/b", {
        "rsync_timeout" => "30",
        "rsync_path"    => "sudo rsync",
      })
      argv.must_include("--timeout=30")
      argv.must_include("--rsync-path=sudo rsync")
    end

    it "adds no --timeout when rsync_timeout is absent or zero" do
      argv = Krikri::SynchronizeRsync.build_argv("/a", "/b", {"rsync_timeout" => "0"})
      argv.none? { |arg| arg.starts_with?("--timeout") }.must_equal(true)
    end

    it "appends raw rsync_opts (JSON array or comma-separated forms)" do
      json_form = Krikri::SynchronizeRsync.build_argv("/a", "/b", {
        "rsync_opts" => %(["--no-motd", "--exclude=.git"]).to_json,
      })
      json_form.must_include("--no-motd")
      json_form.must_include("--exclude=.git")

      csv_form = Krikri::SynchronizeRsync.build_argv("/a", "/b", {
        "rsync_opts" => "--exclude=foo, --exclude=bar",
      })
      csv_form.must_include("--exclude=foo")
      csv_form.must_include("--exclude=bar")
    end

    it "adds -H -vv and absolute --link-dest for link_dest" do
      argv = Krikri::SynchronizeRsync.build_argv("/a", "/b", {
        "link_dest" => %(["/snap/shot"]).to_json,
      })
      argv.must_include("-H")
      argv.must_include("-vv")
      argv.must_include("--link-dest=/snap/shot")
    end

    it "builds --rsh with the Ansible module's ssh options for remote paths" do
      argv = Krikri::SynchronizeRsync.build_argv("/local", "root@web:/remote", {
        "dest_port" => "2222",
      }, private_key: "/id_ed25519", dest_port: 2222)
      rsh = argv.find! { |arg| arg.starts_with?("--rsh=") }
      rsh.must_include("ssh -S none")
      rsh.must_include("-i /id_ed25519")
      rsh.must_include("-o Port=2222")
      rsh.must_include("-o StrictHostKeyChecking=no")
      rsh.must_include("-o UserKnownHostsFile=/dev/null")
    end

    it "omits the host-key-check pair when verify_host is true" do
      argv = Krikri::SynchronizeRsync.build_argv("/local", "root@web:/remote", {
        "verify_host" => "yes",
      }, dest_port: 22)
      rsh = argv.find! { |arg| arg.starts_with?("--rsh=") }
      rsh.wont_include("StrictHostKeyChecking")
    end

    it "adds no --rsh for two local paths" do
      argv = Krikri::SynchronizeRsync.build_argv("/a", "/b", Hash(String, String).new, dest_port: 22)
      argv.none? { |arg| arg.starts_with?("--rsh=") }.must_equal(true)
    end

    it "respects an rsync_opts-supplied --rsh instead of its own" do
      argv = Krikri::SynchronizeRsync.build_argv("/local", "root@web:/remote", {
        "rsync_opts" => %(["--rsh=/usr/bin/ssh -p 2222"]).to_json,
      }, dest_port: 22)
      argv.any? { |arg| arg.starts_with?("--rsh=ssh -S none") }.must_equal(false)
      argv.must_include("--rsh=/usr/bin/ssh -p 2222")
    end
  end

  describe "format_rsh_target" do
    it "prefixes user@host: for a plain remote path" do
      Krikri::SynchronizeRsync.format_rsh_target("web", "/srv", "deploy")
        .must_equal("deploy@web:/srv")
    end

    it "omits user@ when there is no inventory user" do
      Krikri::SynchronizeRsync.format_rsh_target("web", "/srv", nil)
        .must_equal("web:/srv")
    end

    it "leaves an already-qualified user@host:path untouched" do
      Krikri::SynchronizeRsync.format_rsh_target("web", "other@web:/srv", "deploy")
        .must_equal("other@web:/srv")
    end

    it "leaves an rsync:// URL untouched" do
      Krikri::SynchronizeRsync.format_rsh_target("web", "rsync://web/mod", "deploy")
        .must_equal("rsync://web/mod")
    end

    it "brackets IPv6 hosts" do
      Krikri::SynchronizeRsync.format_rsh_target("::1", "/srv", "deploy")
        .must_equal("[deploy@::1]:/srv")
    end
  end

  describe "changed?" do
    it "is false for an empty (no-op) rsync output" do
      Krikri::SynchronizeRsync.changed?("").must_equal(false)
      Krikri::SynchronizeRsync.changed?("some warning text\n").must_equal(false)
    end

    it "is true when any itemize line is present" do
      Krikri::SynchronizeRsync.changed?("<<CHANGED>>>f.st...... file.txt\n").must_equal(true)
      Krikri::SynchronizeRsync.changed?("<<CHANGED>>cd+++++++++ dir/\n").must_equal(true)
      Krikri::SynchronizeRsync.changed?("<<CHANGED>>*deleting   stale.txt\n").must_equal(true)
    end

    it "treats a leading . itemize char as no-change only under link_dest" do
      out_var = "<<CHANGED>>.f........ hardlinked.txt\n"
      Krikri::SynchronizeRsync.changed?(out_var, link_dest: true).must_equal(false)
      Krikri::SynchronizeRsync.changed?(out_var).must_equal(true)
      Krikri::SynchronizeRsync.changed?("<<CHANGED>>>f.st...... changed.txt\n", link_dest: true).must_equal(true)
    end
  end

  describe "clean_output" do
    it "keeps one line per real change with markers and blanks stripped" do
      Krikri::SynchronizeRsync.clean_output("<<CHANGED>>>f.st...... a\n\n<<CHANGED>>cd+++++++++ b\n")
        .must_equal(">f.st...... a\ncd+++++++++ b\n")
    end

    it "keeps Ansible's trailing newline on the msg but not on an empty capture" do
      # Ansible's msg is out.replace(changed_marker, '') - rsync's raw
      # stdout, trailing newline included (round 995004
      # synchronize_push). An empty stdout stays empty (the idempotent
      # rerun's msg key must keep its "" value).
      Krikri::SynchronizeRsync.clean_output("<<CHANGED>>>f+++++++++ a\n")
        .must_equal(">f+++++++++ a\n")
      Krikri::SynchronizeRsync.clean_output("").must_equal("")
    end
  end

  describe "parse_list" do
    it "parses JSON arrays and comma separation, keeps a repr-looking string raw, and maps nil to empty" do
      # A whole-value `{{ list_var }}` container arg arrives as
      # double-quoted JSON (see substitute_task_params's
      # whole-single-span comment). A value that merely LOOKS like a
      # container (single-quoted repr text - a literal string, or a
      # `{% if %}...{% else %}['a']{% endif %}` block's rendered output)
      # is a plain STRING in ansible-core (live-verified vs
      # ansible-playbook 2.19.11, see apt.cr's parse_package_names) -
      # the old single-quote "repair" turned it into a list
      # Ansible never had.
      Krikri::SynchronizeRsync.parse_list(%(["--a", "--b"])).must_equal(["--a", "--b"])
      Krikri::SynchronizeRsync.parse_list("['--a', '--b']").must_equal(["['--a'", "'--b']"])
      Krikri::SynchronizeRsync.parse_list("--a, --b").must_equal(["--a", "--b"])
      Krikri::SynchronizeRsync.parse_list(nil).must_equal([] of String)
    end
  end
end
