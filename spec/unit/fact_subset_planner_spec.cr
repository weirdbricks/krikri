require "../spec_helper"
require "../../src/crystal_play/fact_subset_planner"
require "../../src/crystal_play/fast_mode"

# OPUS_PERFORMANCE_IMPROVEMENTS.md item 12, behind the
# crystal-ansible-fast binary.
#
# The planner decides which optional fact families a play never
# references, so gather_facts can skip them (~88ms -> ~37ms for the full
# skip, measured against the real plugin). It is BREAKING because the
# analysis is textual, so what is pinned here is mostly the CONSERVATIVE
# direction: a false "this is used" only costs speed, a false "unused"
# costs correctness.
# `plan` is nilable by design (nil = "gather everything"), and these
# examples have already asserted non-nil where it matters; this keeps
# the assertions readable without `not_nil!`.
private def planned(plan : Array(String)?) : Array(String)
  plan.should_not be_nil
  plan || [] of String
end

private def playbook_from(yaml : String) : CrystalPlay::Playbook
  path = File.tempname("planner-spec", ".yml")
  File.write(path, yaml)
  begin
    CrystalPlay::PlaybookParser.parse(path)
  ensure
    File.delete(path) rescue nil
  end
end

describe CrystalPlay::FactSubsetPlanner do
  it "skips every optional family when the play references none" do
    plan = CrystalPlay::FactSubsetPlanner.plan(playbook_from(<<-YAML))
    - hosts: all
      tasks:
        - debug:
            msg: "{{ ansible_distribution }}"
    YAML

    planned(plan).sort!.should eq(["!hardware", "!mounts", "!network", "all"])
  end

  it "keeps a family the play does reference" do
    plan = CrystalPlay::FactSubsetPlanner.plan(playbook_from(<<-YAML))
    - hosts: all
      tasks:
        - debug:
            msg: "{{ ansible_processor_vcpus }}"
    YAML

    planned(plan).includes?("!hardware").should be_false
    planned(plan).includes?("!network").should be_true
  end

  it "always emits `all` so the subtractions are subtractions" do
    # Load-bearing: FactsGatherer#subset_enabled? reads a non-empty
    # subset without `all` as an allow-list of nothing, which disabled
    # even the families the play referenced. Found live.
    plan = CrystalPlay::FactSubsetPlanner.plan(playbook_from(<<-YAML))
    - hosts: all
      tasks:
        - debug:
            msg: "{{ ansible_memtotal_mb }}"
    YAML

    planned(plan).first.should eq("all")
  end

  it "gives up entirely on a computed fact name" do
    # nil means "gather everything" - a name built at runtime cannot be
    # seen by any textual scan.
    CrystalPlay::FactSubsetPlanner.plan(playbook_from(<<-YAML)).should be_nil
    - hosts: all
      tasks:
        - debug:
            msg: "{{ vars['ansible_' ~ which] }}"
    YAML
  end

  it "gives up on hostvars, which reaches another host's facts" do
    CrystalPlay::FactSubsetPlanner.plan(playbook_from(<<-YAML)).should be_nil
    - hosts: all
      tasks:
        - debug:
            msg: "{{ hostvars['other'].ansible_mounts }}"
    YAML
  end

  it "sees facts referenced in when: and in nested block tasks" do
    # A fact used only as a condition, or only inside a block, still
    # counts - collect_text has to reach both.
    plan = CrystalPlay::FactSubsetPlanner.plan(playbook_from(<<-YAML))
    - hosts: all
      tasks:
        - block:
            - debug:
                msg: hi
              when: ansible_mounts | length > 0
    YAML

    planned(plan).includes?("!mounts").should be_false
  end

  it "returns nil when every family is referenced" do
    CrystalPlay::FactSubsetPlanner.plan(playbook_from(<<-YAML)).should be_nil
    - hosts: all
      tasks:
        - debug:
            msg: "{{ ansible_mounts }} {{ ansible_processor }} {{ ansible_default_ipv4 }}"
    YAML
  end
end

describe CrystalPlay::FastMode do
  it "is off for the parity binary name" do
    # The spec suite runs as neither name, so this is the real default.
    CrystalPlay::FastMode.enabled?.should be_false
  end

  it "names the breaking behaviour in its banner rather than just saying fast" do
    CrystalPlay::FastMode.banner.should contain("facts")
    CrystalPlay::FastMode.banner.should contain("crystal-ansible")
  end
end
