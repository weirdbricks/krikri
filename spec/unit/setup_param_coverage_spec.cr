require "../spec_helper"
require "../../src/krikri/plugin_helpers/facts_gatherer"
require "file_utils"

# Proactive param-coverage pass for ansible.builtin.setup's four
# documented module params (gather_subset / gather_timeout / filter /
# fact_path), pinned against live ansible-core 2.19.4 behavior - every
# expected value below was either observed directly (`ansible localhost
# -m setup -a '...'`) or read out of the real module's source
# (modules/setup.py, plugins/action/gather_facts.py,
# module_utils/facts/{collector,timeout,system/local}.py).
private def config_with(params : String)
  JSON.parse(%({"host":{"name":"localhost","user":"root","port":22},"params":#{params},"vars":{}}))
end

describe Krikri::FactsGatherer do
  describe "#resolve_enabled_families" do
    it "gathers every family with no tokens (real get_collector_names' `gather_subset or ['all']`)" do
      families = Krikri::FactsGatherer.resolve_enabled_families([] of String)
      families.should eq(Set.new(%w[min local network hardware mounts]))
    end

    it "keeps the min floor for !all, exactly like real Ansible" do
      families = Krikri::FactsGatherer.resolve_enabled_families(["!all"])
      families.should eq(Set.new(%w[min local]))
    end

    it "gathers nothing but the min bundle for a bare !min" do
      # Real behavior (live-verified): !all,!min returns an ansible_facts
      # dict containing ONLY the gather_subset/module_setup meta keys -
      # a bare !min excludes the min bundle and nothing else is left.
      Krikri::FactsGatherer.resolve_enabled_families(["!all", "!min"]).should eq(Set(String).new)
      Krikri::FactsGatherer.resolve_enabled_families(["!min"]).should eq(Set(String).new)
    end

    it "restricts to the named families plus min" do
      Krikri::FactsGatherer.resolve_enabled_families(["network", "virtual"])
        .should eq(Set.new(%w[min local network]))
    end

    it "lets an explicit positive token override a negation of the same family (real exclude-minus-explicit rule)" do
      # Not "later tokens win": real Ansible's difference_update only
      # removes (exclude - explicitly_added), so a family named
      # positively is kept even when a negation elsewhere targets it.
      Krikri::FactsGatherer.resolve_enabled_families(["network", "!network"])
        .should eq(Set.new(%w[min local network]))
    end

    it "re-includes an explicitly named family excluded by !all" do
      Krikri::FactsGatherer.resolve_enabled_families(["!all", "network"])
        .should eq(Set.new(%w[min local network]))
    end

    it "ignores an unknown NEGATED token (real behavior: it disables nothing)" do
      # Live-verified against 2.19.4: gather_subset="!bogus" yields the
      # min bundle only - the unknown negation adds nothing to the
      # exclusion set, but the min floor is all that was ever added.
      Krikri::FactsGatherer.resolve_enabled_families(["!bogus"])
        .should eq(Set.new(%w[min local]))
    end

    it "activates a whole family from one of its per-fact aliases" do
      # real Ansible's fact_id -> collector map: all_ipv4_addresses is
      # an alias of the network collector's family.
      Krikri::FactsGatherer.resolve_enabled_families(["all_ipv4_addresses"])
        .should eq(Set.new(%w[min local network]))
      Krikri::FactsGatherer.resolve_enabled_families(["devices"])
        .should eq(Set.new(%w[min local hardware]))
    end

    it "accepts valid-but-unimplemented subset names without failing" do
      # virtual/dns/selinux/... are real collectors this engine has no
      # implementation for - real Ansible accepts the token, so this
      # must too (gathering nothing extra).
      Krikri::FactsGatherer.resolve_enabled_families(["virtual", "dns"])
        .should eq(Set.new(%w[min local]))
    end

    it "fails on an unknown positive token with real Ansible's message" do
      # Live-verified against 2.19.4: setup fails with "Bad subset
      # 'bogus' given to Ansible. gather_subset options allowed: all, ..."
      ex = expect_raises(Krikri::FactsGatherer::BadSubsetError) do
        Krikri::FactsGatherer.resolve_enabled_families(["bogus"])
      end
      ex.message.to_s.should start_with("Bad subset 'bogus' given to Ansible. gather_subset options allowed: all, ")
    end
  end

  describe "#run" do
    it "fails the module on a whitespace-padded token, exactly like real Ansible" do
      # real Ansible's type=list conversion splits on ',' WITHOUT
      # stripping (live-verified: `gather_subset: "network, virtual"`
      # fails with "Bad subset ' virtual'"). The old strip-on-split
      # behavior here was a divergence.
      result = JSON.parse(Krikri::FactsGatherer.run(config_with(%({"gather_subset": "network, virtual"}))))
      result["failed"].as_bool.should be_true
      result["msg"].as_s.should start_with("Bad subset ' virtual'")
    end

    it "returns only the meta facts for !all,!min" do
      result = JSON.parse(Krikri::FactsGatherer.run(config_with(%({"gather_subset": ["!all", "!min"]}))))
      result["failed"]?.try(&.as_bool).should be_falsey
      facts = result["ansible_facts"].as_h
      facts.keys.sort!.should eq(["gather_subset", "module_setup"])
      facts["gather_subset"].as_a.map(&.as_s).should eq(["!all", "!min"])
      facts["module_setup"].as_bool.should be_true
    end

    it "echoes the requested subset and module_setup in the facts (real meta keys)" do
      result = JSON.parse(Krikri::FactsGatherer.run(config_with(%({"gather_subset": "min"}))))
      facts = result["ansible_facts"].as_h
      facts["gather_subset"].as_a.map(&.as_s).should eq(["min"])
      facts["module_setup"].as_bool.should be_true
    end

    it "defaults the echoed subset to [\"all\"] (real argument-spec default)" do
      result = JSON.parse(Krikri::FactsGatherer.run(config_with(%({}))))
      result["ansible_facts"]["gather_subset"].as_a.map(&.as_s).should eq(["all"])
    end

    describe "filter" do
      it "keeps only fnmatch-matching top-level keys (string form)" do
        result = JSON.parse(Krikri::FactsGatherer.run(config_with(%({"filter": "ansible_hostname"}))))
        facts = result["ansible_facts"].as_h
        facts.keys.should eq(["ansible_hostname"])
      end

      it "splits a comma-separated string into multiple patterns" do
        result = JSON.parse(Krikri::FactsGatherer.run(config_with(%({"filter": "ansible_hostname,ansible_fips"}))))
        result["ansible_facts"].as_h.keys.sort!.should eq(["ansible_fips", "ansible_hostname"])
      end

      it "accepts YAML list form" do
        result = JSON.parse(Krikri::FactsGatherer.run(config_with(%({"filter": ["ansible_hostname", "ansible_fqdn"]}))))
        result["ansible_facts"].as_h.keys.sort!.should eq(["ansible_fqdn", "ansible_hostname"])
      end

      it "supports shell-style globs and char classes" do
        result = JSON.parse(Krikri::FactsGatherer.run(config_with(%({"filter": "ansible_all_ipv[4]_addresses"}))))
        result["ansible_facts"].as_h.keys.should eq(["ansible_all_ipv4_addresses"])
      end

      it "filters the meta keys too (live-verified shape)" do
        result = JSON.parse(Krikri::FactsGatherer.run(config_with(%({"filter": "ansible_hostname"}))))
        result["ansible_facts"].as_h.keys.should_not contain("module_setup")
      end

      it "treats an empty string as no filter (live-verified)" do
        result = JSON.parse(Krikri::FactsGatherer.run(config_with(%({"filter": ""}))))
        result["ansible_facts"].as_h.size.should be > 10
      end

      it "keeps a matched nested dict whole (filter only prunes level one)" do
        result = JSON.parse(Krikri::FactsGatherer.run(config_with(%({"filter": "ansible_memory_mb"}))))
        facts = result["ansible_facts"].as_h
        facts.size.should eq(1)
        facts["ansible_memory_mb"].as_h["swap"].as_h["total"]?.should_not be_nil
      end
    end

    describe "gather_timeout parsing" do
      it "accepts a JSON number" do
        result = JSON.parse(Krikri::FactsGatherer.run(config_with(%({"gather_timeout": 3, "gather_subset": "min"}))))
        result["failed"]?.try(&.as_bool).should be_falsey
      end

      it "accepts a numeric string" do
        result = JSON.parse(Krikri::FactsGatherer.run(config_with(%({"gather_timeout": "3", "gather_subset": "min"}))))
        result["failed"]?.try(&.as_bool).should be_falsey
      end

      it "fails with real check_type_int's message shape on a non-int" do
        # Live-verified: "argument 'gather_timeout' is of type str and
        # we were unable to convert to int: \"'abc'\" cannot be
        # converted to an int"
        result = JSON.parse(Krikri::FactsGatherer.run(config_with(%({"gather_timeout": "abc"}))))
        result["failed"].as_bool.should be_true
        result["msg"].as_s.should eq("argument 'gather_timeout' is of type str and we were unable to convert to int: \"'abc'\" cannot be converted to an int")
      end

      # The actual timeout TRIGGERING (a family collection genuinely
      # overrunning the deadline and being dropped with the "No ...
      # facts were gathered due to timeout." warning) is not asserted
      # here: it needs a deterministically slow collector, which none of
      # the real gatherers can be on CI. The fiber/scratch-drop
      # mechanism in gather_family_timed mirrors real Ansible's
      # ThreadPool-based timeout decorator; its parse/validate surface
      # is what this spec pins.
    end

    describe "fact_path (ansible_local)" do
      around_each do |example|
        FileUtils.mkdir_p("/tmp/krikri-fact-path-spec")
        example.run
        FileUtils.rm_rf("/tmp/krikri-fact-path-spec")
      end

      it "gathers JSON, sectioned ini, and script facts; stores real Ansible's error strings for the rest" do
        dir = "/tmp/krikri-fact-path-spec"
        File.write("#{dir}/json.fact", %({"json_key": 42, "nested": {"a": 1}}))
        File.write("#{dir}/ini.fact", "[main]\nhello=world\nfoo: bar\n")
        # A bare key=value with no [section] header is what real
        # configparser rejects (MissingSectionHeaderError) - the fact
        # becomes the same error string real Ansible stores.
        File.write("#{dir}/noheader.fact", "hello=world\n")
        File.write("#{dir}/plain.fact", "plain text\n")
        script = "#{dir}/script.fact"
        File.write(script, "#!/bin/sh\necho '{\"from\": \"script\"}'\n")
        File.chmod(script, 0o755)
        failing = "#{dir}/failing.fact"
        File.write(failing, "#!/bin/sh\nexit 3\n")
        File.chmod(failing, 0o755)

        result = JSON.parse(Krikri::FactsGatherer.run(config_with(%({"fact_path": "#{dir}"}))))
        local = result["ansible_facts"]["ansible_local"].as_h

        local["json"].as_h["json_key"].as_i.should eq(42)
        local["json"].as_h["nested"].as_h["a"].as_i.should eq(1)
        local["ini"].as_h["main"].as_h.should eq({"hello" => "world", "foo" => "bar"})
        local["script"].as_h["from"].as_s.should eq("script")
        local["noheader"].as_s.should eq("error loading facts as JSON or ini - please check content: #{dir}/noheader.fact")
        local["plain"].as_s.should eq("error loading facts as JSON or ini - please check content: #{dir}/plain.fact")
        local["failing"].as_s.should eq("Failure executing fact script (#{dir}/failing.fact), rc: 3, err: ")
      end

      it "always defines ansible_local, even with no fact_path directory at all" do
        # Real LocalFactCollector returns {'local': {}} unconditionally
        # when the path doesn't exist - ansible_local is {} there, never
        # undefined.
        result = JSON.parse(Krikri::FactsGatherer.run(config_with(%({"fact_path": "/tmp/krikri-fact-path-spec/does-not-exist"}))))
        result["ansible_facts"]["ansible_local"].as_h.should be_empty
      end
    end
  end

  describe "#fnmatch_to_regex" do
    it "translates the shell-style dialect real Ansible's fnmatch uses" do
      {
        {"ansible_*_mb", "ansible_memfree_mb", true},
        {"ansible_*_mb", "ansible_memfree_mb_total", false},
        {"ansible_eth[0-2]", "ansible_eth1", true},
        {"ansible_eth[0-2]", "ansible_eth3", false},
        {"ansible_enp0s?", "ansible_enp0s3", true},
        {"ansible_enp?", "ansible_enp0s3", false},
        {"ansible_[!x]ost", "ansible_host", true},
        {"ansible_[!x]ost", "ansible_xost", false},
        {"ansible_[", "ansible_[", true},
        {"*", "anything_at_all", true},
      }.each do |(pattern, key, matches)|
        Krikri::FactsGatherer.fnmatch_to_regex(pattern).matches?(key).should eq(matches)
      end
    end
  end
end
