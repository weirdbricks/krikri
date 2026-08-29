require "../spec_helper"
require "../../src/crystal_play/package_coalescer"

# OPUS_PERFORMANCE_IMPROVEMENTS.md item 11, behind crystal-ansible-fast.
#
# Merging consecutive package installs into one transaction is worth
# seconds per role, and is BREAKING: ordering, per-task `changed`, and
# handler granularity all move. So what is pinned here is the
# eligibility rules - every one of them exists to stop a task whose
# behaviour depends on running separately from being swept into a merge.
private def task(mod : String, name : String, **opts) : CrystalPlay::Task
  t = CrystalPlay::Task.new("install #{name}", mod)
  t.params = {"name" => name}
  opts.each do |key, value|
    case key
    when :state    then t.params["state"] = value.as(String)
    when :when     then t.when_condition = value.as(String)
    when :register then t.register = value.as(String)
    when :notify   then t.notify = [value.as(String)]
    end
  end
  t
end

describe CrystalPlay::PackageCoalescer do
  it "merges a consecutive run of plain installs" do
    plan = CrystalPlay::PackageCoalescer.plan([
      task("apt", "curl"), task("apt", "git"), task("apt", "vim"),
    ])
    plan.size.should eq(3)
    plan.values.first.names.should eq(["curl", "git", "vim"])
  end

  it "leaves a lone package task completely alone" do
    # A run of one is not a merge; it must take the ordinary path.
    CrystalPlay::PackageCoalescer.plan([task("apt", "curl")]).should be_empty
  end

  it "refuses to merge across a conditional task" do
    # A `when:` task might not run, so merging its packages into a
    # neighbour would install something the play said not to.
    plan = CrystalPlay::PackageCoalescer.plan([
      task("apt", "curl"), task("apt", "git", when: "false"), task("apt", "vim"),
    ])
    # curl and vim are separated by the conditional, so neither run
    # reaches two members.
    plan.should be_empty
  end

  it "refuses a task whose result is registered" do
    plan = CrystalPlay::PackageCoalescer.plan([
      task("apt", "curl", register: "r"), task("apt", "git"),
    ])
    plan.should be_empty
  end

  it "refuses a task that notifies a handler" do
    # A follower reports unchanged, so it would stop firing its handler.
    plan = CrystalPlay::PackageCoalescer.plan([
      task("apt", "curl", notify: "restart thing"), task("apt", "git"),
    ])
    plan.should be_empty
  end

  it "does not merge across different modules" do
    plan = CrystalPlay::PackageCoalescer.plan([task("apt", "curl"), task("dnf", "git")])
    plan.should be_empty
  end

  it "does not merge a non-present state" do
    # absent/latest carry their own ordering hazards.
    plan = CrystalPlay::PackageCoalescer.plan([
      task("apt", "curl", state: "absent"), task("apt", "git", state: "absent"),
    ])
    plan.should be_empty
  end

  it "does not merge an unrendered templated name" do
    # The text has not been substituted yet; merging it is nonsense.
    plan = CrystalPlay::PackageCoalescer.plan([
      task("apt", "{{ pkg }}"), task("apt", "git"),
    ])
    plan.should be_empty
  end

  it "splits a comma list from one task across the merge correctly" do
    plan = CrystalPlay::PackageCoalescer.plan([
      task("apt", "curl,git"), task("apt", "vim"),
    ])
    plan.values.first.names.should eq(["curl", "git", "vim"])
  end

  it "names the first task of the run as leader" do
    tasks = [task("apt", "curl"), task("apt", "git")]
    CrystalPlay::PackageCoalescer.plan(tasks).values.first.leader.same?(tasks.first).should be_true
  end
end
