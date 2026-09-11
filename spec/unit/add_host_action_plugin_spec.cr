require "../spec_helper"
require "../../src/krikri/inventory_parser"
require "../../src/krikri/action_plugin_manager"

private def build_inventory
  inventory = Krikri::Inventory.new
  existing = Krikri::Host.new("control1")
  inventory.add_host(existing)
  web = inventory.get_or_create_group("web")
  web.add_host(existing)
  inventory
end

private def run_add_host(inventory : Krikri::Inventory, params : Hash(String, String)) : Krikri::ActionResult
  caller_host = Krikri::Host.new("control1")
  plugin = Krikri::AddHostActionPlugin.new(params, Hash(String, JSON::Any).new, caller_host, inventory)
  plugin.execute
end

describe "AddHostActionPlugin" do
  it "adds a host with name, groups and extra vars" do
    inventory = build_inventory
    result = run_add_host(inventory, {
      "name"       => "dyn1",
      "groups"     => "mygroup",
      "ansible_host" => "1.2.3.4",
      "ansible_user" => "someuser",
    })

    result.success?.should be_true
    final = result.final_result
    final.should_not be_nil
    final.not_nil!.as_h["changed"].as_bool.should be_true

    host = inventory.hosts["dyn1"]?
    host.should_not be_nil
    host.not_nil!.vars["ansible_host"].as_s.should eq("1.2.3.4")
    host.not_nil!.user.should eq("someuser")
  end

  it "is visible to a later play's hosts: pattern by group name" do
    inventory = build_inventory
    run_add_host(inventory, {"name" => "dyn1", "groups" => "newgrp"})

    names = inventory.get_hosts("newgrp").map(&.name)
    names.should eq(["dyn1"])
  end

  it "is visible to a later play's hosts: pattern by host name" do
    inventory = build_inventory
    run_add_host(inventory, {"name" => "dyn1", "groups" => "newgrp"})

    inventory.get_hosts("dyn1").map(&.name).should eq(["dyn1"])
    inventory.get_hosts("web").map(&.name).sort.should eq(%w[control1])
  end

  it "accepts groups as a JSON list (a literal YAML list or rendered Jinja list)" do
    inventory = build_inventory
    run_add_host(inventory, {"name" => "dyn1", "groups" => "[\"grp_a\", \"grp_b\"]"})

    inventory.get_hosts("grp_a").map(&.name).should eq(["dyn1"])
    inventory.get_hosts("grp_b").map(&.name).should eq(["dyn1"])
  end

  it "accepts the group: alias" do
    inventory = build_inventory
    run_add_host(inventory, {"name" => "dyn1", "group" => "solo"})

    inventory.get_hosts("solo").map(&.name).should eq(["dyn1"])
  end

  it "updates/merges into the existing entry on a second call with the same name" do
    inventory = build_inventory
    run_add_host(inventory, {"name" => "dyn1", "groups" => "first", "ansible_host" => "1.2.3.4"})
    run_add_host(inventory, {"name" => "dyn1", "groups" => "second", "ansible_user" => "deploy"})

    inventory.hosts.size.should eq(2)

    host = inventory.hosts["dyn1"].not_nil!
    host.vars["ansible_host"].as_s.should eq("1.2.3.4")
    host.vars["ansible_user"].as_s.should eq("deploy")

    inventory.get_hosts("first").map(&.name).should eq(["dyn1"])
    inventory.get_hosts("second").map(&.name).should eq(["dyn1"])
    inventory.get_hosts("dyn1").size.should eq(1)
  end

  it "always reports changed: true" do
    inventory = build_inventory
    result = run_add_host(inventory, {"name" => "dyn1"})

    final = result.final_result.not_nil!
    final.as_h["changed"].as_bool.should be_true
    final.as_h["failed"].as_bool.should be_false
  end

  it "fails cleanly without a name" do
    inventory = build_inventory
    result = run_add_host(inventory, {"groups" => "mygroup"})

    result.success?.should be_false
    result.error_message.should_not be_nil
    inventory.hosts.size.should eq(1)
  end

  it "is dispatched controller-only (no module upload, no plugins/*.cr binary)" do
    Krikri::ActionPluginManager.skips_module_dispatch?("ansible.builtin.add_host").should be_true
    Krikri::ActionPluginManager.skips_module_dispatch?("add_host").should be_true
  end
end
