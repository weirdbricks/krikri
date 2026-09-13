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
    result["failed"]?.try(&.as_bool).should be_falsey
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

  it "returns just one entry, still keyed by username (not a bare field list), for a single key lookup" do
    # Real bug found benchmarking robertdebock.git: real Ansible's own
    # getent_passwd fact is ALWAYS a dict keyed by the looked-up
    # username, even for a single-key lookup (`{"root": [...]}` - never
    # a bare field-array). This plugin's single-key branch previously
    # returned the field list directly, unwrapped, so a role's own
    # `getent_passwd[git_username] != none` existence check (indexing
    # what it assumed was a dict) always got the wrong thing back -
    # either the raw list itself or "undefined" once `#[]` failed to
    # find an integer index - and the check behaved as if the user
    # never existed, regardless of whether it actually did.
    result = PluginSpecHelper.run("getent", {"database" => "passwd", "key" => "root"})
    result["failed"]?.try(&.as_bool).should be_falsey
    entry = result["ansible_facts"]["getent_passwd"].as_h["root"].as_a.map(&.as_s)
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

  it "does not fail a missing key when fail_key is false, and maps it to a real null (not an empty array)" do
    # Real bug found benchmarking filviu.activemq/.tomcat's own "env |
    # determine if <user> exists" -> "setup | create system user" pair
    # (when: getent_passwd[user] == none): real Ansible's own getent
    # module sets the value to None for a not-found key with fail_key:
    # false, not an empty list - `[] == none` is always false under
    # real Python/Jinja equality regardless of emptiness, so storing an
    # empty array here made that when: always evaluate false and the
    # user-creation task silently skip every single run.
    result = PluginSpecHelper.run("getent", {"database" => "passwd", "key" => "definitely-not-a-real-user-xyz", "fail_key" => "false"})
    result["failed"]?.try(&.as_bool).should be_falsey
    result["ansible_facts"]["getent_passwd"].as_h["definitely-not-a-real-user-xyz"].raw.should be_nil
  end

  it "splits non-colon databases on whitespace runs, not ':' (hosts)" do
    # Real ansible.builtin.getent (ansible/modules/getent.py) colon-splits
    # by default ONLY for passwd/shadow/group/gshadow (its own `colon`
    # list); every other database splits on runs of whitespace - live
    # verified against real ansible-playbook 2.19.4 on this machine
    # (`getent hosts localhost` emits "127.0.0.1  localhost ...", tab/
    # multi-space delimited, so `::1` maps to
    # ["localhost", "ip6-localhost", "ip6-loopback"]). The old always-
    # colon-split produced the entire line as the dict key with an empty
    # field list. Keys must be the first whitespace field (the IP), and
    # at least one entry must mention localhost.
    result = PluginSpecHelper.run("getent", {"database" => "hosts"})
    result["failed"]?.try(&.as_bool).should be_falsey
    hosts = result["ansible_facts"]["getent_hosts"].as_h
    hosts.size.should be > 0
    hosts.keys.each do |ip|
      ip.should_not contain(" ")
      ip.should_not contain("\t")
    end
    localhost_seen = hosts.values.any? do |fields|
      names = fields.as_a.map(&.as_s)
      names.includes?("localhost")
    end
    localhost_seen.should be_true
  end

  it "stores duplicate keys as a list of field-lists (services tcp/udp pairs)" do
    # Real Ansible 2.11+ keeps every result for the same key: a second
    # line with an already-seen key turns the value into a list of field
    # lists (ansible/modules/getent.py's `seen` bookkeeping). The old
    # parser silently kept only the last line. /etc/services on any
    # normal system lists many services for both tcp and udp (e.g.
    # "domain 53/tcp" and "domain 53/udp"), so enumeration must produce
    # at least one list-of-lists entry - live-verified against real
    # ansible-playbook 2.19.4 (`getent_services["http"] == ["80/tcp",
    # "www"]` single, duplicated names -> [[...], [...]]).
    result = PluginSpecHelper.run("getent", {"database" => "services"})
    result["failed"]?.try(&.as_bool).should be_falsey
    services = result["ansible_facts"]["getent_services"].as_h
    services.size.should be > 0

    duplicated = services.values.any? do |val|
      arr = val.as_a
      !arr.empty? && arr[0].raw.is_a?(Array)
    end
    duplicated.should be_true

    # Every value is a JSON array - a field list or a list of field
    # lists - never a bare string.
    services.values.each do |val|
      val.raw.is_a?(Array).should be_true
    end
  end

  it "honors an explicit split: value for any database" do
    # `split:` overrides the per-database default (real module: `split =
    # module.params.get('split')`, applied to every line regardless of
    # database). Passwd with an explicit ':' must match its own default
    # shape: root -> 6 colon fields.
    result = PluginSpecHelper.run("getent", {"database" => "passwd", "split" => ":"})
    result["failed"]?.try(&.as_bool).should be_falsey
    root = result["ansible_facts"]["getent_passwd"].as_h["root"].as_a.map(&.as_s)
    root.size.should eq(6)
  end

  it "returns only the FIRST matching line for a duplicated key (services tcp/udp)" do
    # Real `getent services domain` emits one line - "domain 53/tcp" -
    # so the real module's keyed fact is getent_services["domain"] ==
    # ["53/tcp"], a single field list (live-verified against real
    # ansible-playbook 2.19.4). The tcp+udp list-of-lists merge happens
    # only on enumeration, never on a keyed lookup.
    result = PluginSpecHelper.run("getent", {"database" => "services", "key" => "domain"})
    result["failed"]?.try(&.as_bool).should be_falsey
    domain = result["ansible_facts"]["getent_services"].as_h["domain"].as_a.map(&.as_s)
    domain.should eq(["53/tcp"])
  end

  it "accepts service: and keeps returning the files-backed data" do
    # `service:` is real Ansible's `-s <service>` NSS restriction. Krikri
    # always reads the local database files (the `files` backend), so the
    # param is accepted and a `service: files` lookup - pin the answer to
    # /etc/passwd and bypass LDAP/SSSD, the overwhelmingly common role
    # usage - behaves exactly like real Ansible. Redirecting to a
    # non-local backend (ldap, sss, ...) is a documented deliberate limit
    # (see KNOWN_MISSING.md and the plugin's own comment), not a failure.
    result = PluginSpecHelper.run("getent", {"database" => "passwd", "key" => "root", "service" => "files"})
    result["failed"]?.try(&.as_bool).should be_falsey
    root = result["ansible_facts"]["getent_passwd"].as_h["root"].as_a.map(&.as_s)
    root[1].to_i.should eq(0)
  end

  it "resolves a numeric UID key for passwd, fact keyed by the entry's own username" do
    # Real getent accepts a numeric UID: `getent passwd 0` emits root's
    # entry (verified live), and the real module keys the fact by the
    # OUTPUT's first field, so getent_passwd["root"] - not ["0"]. The old
    # literal-first-field lookup failed this outright.
    result = PluginSpecHelper.run("getent", {"database" => "passwd", "key" => "0"})
    result["failed"]?.try(&.as_bool).should be_falsey
    entry = result["ansible_facts"]["getent_passwd"].as_h["root"].as_a.map(&.as_s)
    entry[1].to_i.should eq(0)
  end

  it "resolves a hostname alias for hosts, fact keyed by the address" do
    # `getent hosts localhost` (verified live) emits the first /etc/hosts
    # line whose fields mention localhost - "127.0.0.1  localhost ..." -
    # so the real module's fact is getent_hosts["127.0.0.1"], not
    # getent_hosts["localhost"]. The old literal-first-field lookup
    # failed a plain `database: hosts, key: localhost` task outright.
    result = PluginSpecHelper.run("getent", {"database" => "hosts", "key" => "localhost"})
    result["failed"]?.try(&.as_bool).should be_falsey
    hosts = result["ansible_facts"]["getent_hosts"].as_h
    hosts.size.should eq(1)
    hosts.keys.first.should_not contain(" ")
    hosts.values.first.as_a.map(&.as_s).includes?("localhost").should be_true
  end

  it "does not resolve a numeric key for shadow (username-only database)" do
    # Real getent shadow has no numeric lookup: `getent shadow 0` is
    # rc 2, key-not-found (verified live).
    result = PluginSpecHelper.run("getent", {"database" => "shadow", "key" => "0"})
    result["failed"].as_bool.should be_true
  end
end
