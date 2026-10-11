require "../minitest_helper"
require "../../src/krikri/plugin_helpers/facts_gatherer"

# znerol.ssh_kba (round 5466303): the role's server-host-key chain reads
# `hostvars[..]["ansible_ssh_host_key_*"]` behind `| default(False)`
# guards; krikri had NO implementation of Ansible's SshPubKeyFactCollector
# (ssh_pub_keys), so every guard went false, the chain collapsed to [],
# and the `when: ssh_kba_server_host_names_and_keys | length > 0` gate
# skipped the known-hosts include that ansible-playbook 2.19.11 expands
# into six loop items. Round 5460170's depth-cap fix (0.9.1622) was real
# but masked this: the loop ran empty on every real host for a different
# reason entirely.
describe Krikri::FactsGatherer do
  describe "#gather_ssh_pub_keys_facts" do
    def write_pub(dir : String, algo : String, keytype : String, key : String)
      Dir.mkdir_p(dir)
      File.write(File.join(dir, "ssh_host_#{algo}_key.pub"), "#{keytype} #{key} host comment\n")
    end

    it "collects key + keytype for each algo found in the first keydir" do
      root = PluginSpecHelper.tmp_path("ssh_pub_keys/basic")
      write_pub(root, "ecdsa", "ecdsa-sha2-nistp256", "AAAA-ECDSA")
      write_pub(root, "ed25519", "ssh-ed25519", "AAAA-ED25519")
      write_pub(root, "rsa", "ssh-rsa", "AAAA-RSA")

      facts = Krikri::FactsGatherer::FactSet.new
      Krikri::FactsGatherer.gather_ssh_pub_keys_facts(facts, [root])

      facts["ansible_ssh_host_key_ecdsa_public"].must_equal("AAAA-ECDSA")
      facts["ansible_ssh_host_key_ecdsa_public_keytype"].must_equal("ecdsa-sha2-nistp256")
      facts["ansible_ssh_host_key_ed25519_public"].must_equal("AAAA-ED25519")
      facts["ansible_ssh_host_key_ed25519_public_keytype"].must_equal("ssh-ed25519")
      facts["ansible_ssh_host_key_rsa_public"].must_equal("AAAA-RSA")
      facts["ansible_ssh_host_key_rsa_public_keytype"].must_equal("ssh-rsa")
      # dsa has no file here, so that fact stays undefined (Ansible too).
      facts.has_key?("ansible_ssh_host_key_dsa_public").must_equal(false)
    end

    it "keeps falling through later keydirs for algos the first dir lacked" do
      # The real collector's early return fires PER FACT NAME inside the
      # algo loop (dsa, rsa, ecdsa, ed25519), not per keydir: algos the
      # first dir lacks still search the second - but ONLY the ones
      # ordered before the first already-collected name, because the
      # return stops the whole walk. Here the first dir has only
      # ecdsa+ed25519, so the second dir still contributes dsa and rsa
      # (both ordered before ecdsa) before the walk stops.
      root = PluginSpecHelper.tmp_path("ssh_pub_keys/fallthrough")
      first = File.join(root, "etc_ssh")
      second = File.join(root, "etc_openssh")
      write_pub(first, "ecdsa", "ecdsa-sha2-nistp256", "AAAA-FIRST-ECDSA")
      write_pub(first, "ed25519", "ssh-ed25519", "AAAA-FIRST-ED25519")
      write_pub(second, "dsa", "ssh-dss", "AAAA-SECOND-DSS")
      write_pub(second, "rsa", "ssh-rsa", "AAAA-SECOND-RSA")

      facts = Krikri::FactsGatherer::FactSet.new
      Krikri::FactsGatherer.gather_ssh_pub_keys_facts(facts, [first, second])

      facts["ansible_ssh_host_key_ecdsa_public"].must_equal("AAAA-FIRST-ECDSA")
      facts["ansible_ssh_host_key_ed25519_public"].must_equal("AAAA-FIRST-ED25519")
      facts["ansible_ssh_host_key_dsa_public"].must_equal("AAAA-SECOND-DSS")
      facts["ansible_ssh_host_key_rsa_public"].must_equal("AAAA-SECOND-RSA")
    end

    it "does not overwrite a found key with a later keydir's copy" do
      root = PluginSpecHelper.tmp_path("ssh_pub_keys/firstwins")
      first = File.join(root, "a")
      second = File.join(root, "b")
      write_pub(first, "rsa", "ssh-rsa", "AAAA-FIRST")
      write_pub(second, "rsa", "ssh-rsa", "AAAA-SECOND")

      facts = Krikri::FactsGatherer::FactSet.new
      Krikri::FactsGatherer.gather_ssh_pub_keys_facts(facts, [first, second])

      facts["ansible_ssh_host_key_rsa_public"].must_equal("AAAA-FIRST")
    end

    it "skips missing and empty .pub files like get_file_content's nil default" do
      root = PluginSpecHelper.tmp_path("ssh_pub_keys/missing")
      Dir.mkdir_p(root)
      File.write(File.join(root, "ssh_host_ecdsa_key.pub"), "")

      facts = Krikri::FactsGatherer::FactSet.new
      Krikri::FactsGatherer.gather_ssh_pub_keys_facts(facts, [root])

      facts.has_key?("ansible_ssh_host_key_ecdsa_public").must_equal(false)
      facts.has_key?("ansible_ssh_host_key_ed25519_public").must_equal(false)
    end

    it "turns on with any of the collector's fact ids and off with !ssh_pub_keys" do
      # FAMILY_SUBSETS mirrors the collector's _fact_ids: asking for a
      # single fact id enables the whole family, and the negation drops
      # it - both like Ansible's fact_id -> collector alias map.
      Krikri::FactsGatherer.resolve_enabled_families(["all"]).includes?("ssh_pub_keys").must_equal(true)
      Krikri::FactsGatherer.resolve_enabled_families(["ssh_host_key_ecdsa_public"]).includes?("ssh_pub_keys").must_equal(true)
      Krikri::FactsGatherer.resolve_enabled_families(["ssh_pub_keys"]).includes?("ssh_pub_keys").must_equal(true)
      Krikri::FactsGatherer.resolve_enabled_families(["all", "!ssh_pub_keys"]).includes?("ssh_pub_keys").must_equal(false)
      # min-only gathers never carry it (the collector is outside min).
      Krikri::FactsGatherer.resolve_enabled_families(["!all"]).includes?("ssh_pub_keys").must_equal(false)
    end
  end
end
