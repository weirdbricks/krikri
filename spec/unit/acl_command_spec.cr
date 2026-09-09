require "../spec_helper"
require "../../src/krikri/plugin_helpers/acl_command"

# Command shapes and idempotency parsing verified against real
# ansible.posix acl.py source (build_command/split_entry/build_entry/
# acl_changed/run_acl, read from ansible-collections/ansible.posix) AND
# against the actual output of a real setfacl 2.3.2: `setfacl --test`
# prints the would-be result as trailing lines ending in `*,*` when
# nothing would change and a full comma-separated entry list ending
# `,*` when it would - see plugins/acl.cr's module comment for the
# round71000 claranet.acl gap this closes. The spec sandbox has no
# ACL-capable filesystem/superuser, so like ufw/iptables the pure
# command-construction half is what gets unit-tested.
describe Krikri::PluginHelpers::AclCommand do
  describe ".split_entry" do
    it "normalizes a full user entry shorthand" do
      Krikri::PluginHelpers::AclCommand.split_entry("user:joe:r--").should eq({nil, "user", "joe", "r--"})
    end

    it "maps u/g/m/o single-letter types to their full names" do
      Krikri::PluginHelpers::AclCommand.split_entry("u:joe:r").should eq({nil, "user", "joe", "r"})
      Krikri::PluginHelpers::AclCommand.split_entry("g:www-data:rw").should eq({nil, "group", "www-data", "rw"})
      Krikri::PluginHelpers::AclCommand.split_entry("m::rwx").should eq({nil, "mask", "", "rwx"})
      Krikri::PluginHelpers::AclCommand.split_entry("o::r-x").should eq({nil, "other", "", "r-x"})
    end

    it "flips the default flag for a d/default prefix (real module's quirk: any leading-d etype counts)" do
      Krikri::PluginHelpers::AclCommand.split_entry("default:user:joe:rw-").should eq({true, "user", "joe", "rw-"})
      Krikri::PluginHelpers::AclCommand.split_entry("d:u:joe:r--").should eq({true, "user", "joe", "r--"})
    end

    it "fills a nil permissions slot for the 2-section state: absent form" do
      Krikri::PluginHelpers::AclCommand.split_entry("user:joe").should eq({nil, "user", "joe", nil})
      Krikri::PluginHelpers::AclCommand.split_entry("default:group:www-data").should eq({true, "group", "www-data", nil})
    end

    it "leaves an unrecognized type as nil (flows through to setfacl and fails there, like real Ansible)" do
      Krikri::PluginHelpers::AclCommand.split_entry("bogus:joe:r--").should eq({nil, nil, "joe", "r--"})
    end
  end

  describe ".build_entry" do
    it "builds the -m entry with permissions" do
      Krikri::PluginHelpers::AclCommand.build_entry("user", "joe", "r").should eq("user:joe:r")
    end

    it "DROPS the permissions section when empty, matching Python's falsy '' - a `mask::` entry collapses to `mask:`" do
      Krikri::PluginHelpers::AclCommand.build_entry("mask", "", "").should eq("mask:")
    end

    it "omits permissions for the state: absent form" do
      Krikri::PluginHelpers::AclCommand.build_entry("user", "joe", nil).should eq("user:joe")
    end

    it "builds the NFSv4 'A' ACE form with the tcy suffix and the g flag for groups" do
      Krikri::PluginHelpers::AclCommand.build_entry("group", "www-data", "r", use_nfsv4_acls: true).should eq("A:g:www-data:rtcy")
      Krikri::PluginHelpers::AclCommand.build_entry("user", "joe", "r", use_nfsv4_acls: true).should eq("A::joe:rtcy")
    end
  end

  describe ".build_command" do
    it "builds the get query as getfacl --absolute-names --omit-header <path>" do
      Krikri::PluginHelpers::AclCommand.build_command("get", "/etc/foo.conf", true, false, false, "default").should eq(
        ["getfacl", "--absolute-names", "--omit-header", "/etc/foo.conf"]
      )
    end

    it "builds a set as setfacl -m <entry> <path> (entry last)" do
      Krikri::PluginHelpers::AclCommand.build_command("set", "/etc/foo.conf", true, false, false, "default", false, "user:joe:r--").should eq(
        ["setfacl", "-m", "user:joe:r--", "/etc/foo.conf"]
      )
    end

    it "builds a remove as setfacl -x <entry> <path>" do
      Krikri::PluginHelpers::AclCommand.build_command("rm", "/etc/foo.conf", true, false, false, "default", false, "user:joe").should eq(
        ["setfacl", "-x", "user:joe", "/etc/foo.conf"]
      )
    end

    it "inserts -d right after the binary name for default: true (so --test lands before it: setfacl --test -d ...)" do
      Krikri::PluginHelpers::AclCommand.build_command("set", "/etc/foo.d", true, true, false, "default", false, "user:joe:rw").should eq(
        ["setfacl", "-d", "-m", "user:joe:rw", "/etc/foo.d"]
      )
      Krikri::PluginHelpers::AclCommand.build_command("get", "/etc/foo.d", true, true, false, "default").should eq(
        ["getfacl", "-d", "--absolute-names", "--omit-header", "/etc/foo.d"]
      )
    end

    it "appends --recursive for mode set/rm/get alike but never for NFSv4 ACLs" do
      base = Krikri::PluginHelpers::AclCommand.build_command("get", "/d", true, false, true, "default")
      base.should eq(["getfacl", "--absolute-names", "--omit-header", "--recursive", "/d"])

      nfs = Krikri::PluginHelpers::AclCommand.build_command("set", "/d", true, false, true, "default", true, "A::joe:rtcy")
      nfs.should eq(["nfs4_setfacl", "-a", "A::joe:rtcy", "/d"])
    end

    it "appends --mask/--no-mask only for set/rm (never the get query)" do
      Krikri::PluginHelpers::AclCommand.build_command("set", "/p", true, false, false, "mask", false, "u:joe:r").should eq(
        ["setfacl", "-m", "u:joe:r", "--mask", "/p"]
      )
      Krikri::PluginHelpers::AclCommand.build_command("rm", "/p", true, false, false, "no_mask", false, "u:joe").should eq(
        ["setfacl", "-x", "u:joe", "--no-mask", "/p"]
      )
      Krikri::PluginHelpers::AclCommand.build_command("get", "/p", true, false, false, "mask").should eq(
        ["getfacl", "--absolute-names", "--omit-header", "/p"]
      )
    end

    it "appends --physical when follow: false" do
      Krikri::PluginHelpers::AclCommand.build_command("get", "/p", false, false, false, "default").should eq(
        ["getfacl", "--absolute-names", "--omit-header", "--physical", "/p"]
      )
    end
  end

  describe ".filter_lines" do
    it "drops # header lines, strips whitespace, and trims one trailing blank line" do
      raw = "# file: /tmp/f\n# owner: root\n\nuser::rw-\n  group::rw-\n\nother::r--\n\n"
      Krikri::PluginHelpers::AclCommand.filter_lines(raw).should eq(["", "user::rw-", "group::rw-", "", "other::r--"])
    end
  end

  describe ".changed?" do
    it "is false when every --test line ends in *,* (setfacl's own no-op signal)" do
      Krikri::PluginHelpers::AclCommand.changed?(["f.txt: *,*"], "u:root:r--").should be_false
      Krikri::PluginHelpers::AclCommand.changed?(["t: *,*", "t/a: *,*", "t/sub: *,*"], "u:root:r--").should be_false
    end

    it "is true when any line ends in a real entry list instead (verified against actual setfacl 2.3.2 --test output)" do
      Krikri::PluginHelpers::AclCommand.changed?(["f.txt: u::rw-,u:root:r--,g::rw-,m::rw-,o::r--,*"], "u:root:r--").should be_true
      Krikri::PluginHelpers::AclCommand.changed?(["t: *,*", "t/a: u::rw-,u:root:r--,g::rw-,m::rw-,o::r--,*"], "u:root:r--").should be_true
      # the default-ACL changed form does not end in *,* (verified: `d: *,d:u::rwx,...`)
      Krikri::PluginHelpers::AclCommand.changed?(["d: *,d:u::rwx,d:u:root:r--,d:g::rwx,d:m::rwx,d:o::r-x"], "u:root:r--").should be_true
    end

    it "uses the NFSv4 counted-twice rule instead" do
      Krikri::PluginHelpers::AclCommand.changed?(["A::joe:rtcy", "A::joe:rtcy"], "A::joe:rtcy", use_nfsv4_acls: true).should be_false
      Krikri::PluginHelpers::AclCommand.changed?(["A::joe:rtcy"], "A::joe:rtcy", use_nfsv4_acls: true).should be_true
    end
  end
end
