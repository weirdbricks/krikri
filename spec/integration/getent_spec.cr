require "../spec_helper"

# The getent plugin reads the real system database. These tests use only
# `passwd` (world-readable, present on every Unix-like host) and assert the
# shape Ansible's getent produces: getent_passwd[user] is the list of
# colon-fields after the username. The shadow database is root-only, so it's
# not exercised here (the parse logic is identical and runs as root on real
# targets).
describe "getent plugin" do
  it "returns getent_passwd keyed by username with field lists" do
    result = PluginSpecHelper.run("getent", {"database" => "passwd"})
    result["failed"].as_bool.should be_false
    result["changed"].as_bool.should be_false

    facts = result["ansible_facts"]
    passwd = facts["getent_passwd"]
    passwd.as_h.size.should be > 0

    # root exists on every host; its entry is the 6 passwd fields after the
    # username: [password, uid, gid, gecos, home, shell].
    root = passwd.as_h["root"].as_a.map(&.as_s)
    root.size.should eq(6)
    # UID is the second field ([1]) - the exact access os_hardening makes.
    root[1].to_i.should eq(0)
    # Home directory is the fifth field ([4]).
    root[4].should_not be_empty
  end

  it "fails on a missing required database parameter" do
    result = PluginSpecHelper.run("getent", {} of String => String)
    result["failed"].as_bool.should be_true
  end

  it "returns just one entry's fields for a single key lookup" do
    result = PluginSpecHelper.run("getent", {"database" => "passwd", "key" => "root"})
    result["failed"].as_bool.should be_false
    entry = result["ansible_facts"]["getent_passwd"].as_a.map(&.as_s)
    entry[1].to_i.should eq(0)
  end

  it "fails a single-key lookup when the key isn't in the database" do
    # Real bug found benchmarking robertdebock.users: a getent lookup for
    # a user being removed (who doesn't exist yet/anymore) previously
    # always succeeded by silently falling back to the whole passwd
    # dict, so a role's own `block:`/`rescue:` gated on this exact
    # failure (falling back to /home when the user isn't found) never
    # triggered its rescue path.
    result = PluginSpecHelper.run("getent", {"database" => "passwd", "key" => "definitely-not-a-real-user-xyz"})
    result["failed"].as_bool.should be_true
    result["msg"].as_s.should contain("could not be found")
  end

  it "does not fail a missing key when fail_key is false" do
    result = PluginSpecHelper.run("getent", {"database" => "passwd", "key" => "definitely-not-a-real-user-xyz", "fail_key" => "false"})
    result["failed"].as_bool.should be_false
    result["ansible_facts"]["getent_passwd"].as_a.size.should eq(0)
  end
end
