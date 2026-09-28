require "../minitest_helper"
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
      "name"         => "dyn1",
      "groups"       => "mygroup",
      "ansible_host" => "1.2.3.4",
      "ansible_user" => "someuser",
    })

    result.success?.must_equal(true)
    final = result.final_result
    final.wont_be_nil
    final.not_nil!.as_h["changed"].as_bool.must_equal(true)

    host = inventory.hosts["dyn1"]?
    host.wont_be_nil
    host.not_nil!.vars["ansible_host"].as_s.must_equal("1.2.3.4")
    host.not_nil!.user.must_equal("someuser")
  end

  it "is visible to a later play's hosts: pattern by group name" do
    inventory = build_inventory
    run_add_host(inventory, {"name" => "dyn1", "groups" => "newgrp"})

    names = inventory.get_hosts("newgrp").map(&.name)
    names.must_equal(["dyn1"])
  end

  it "is visible to a later play's hosts: pattern by host name" do
    inventory = build_inventory
    run_add_host(inventory, {"name" => "dyn1", "groups" => "newgrp"})

    inventory.get_hosts("dyn1").map(&.name).must_equal(["dyn1"])
    inventory.get_hosts("web").map(&.name).sort.must_equal(%w[control1])
  end

  it "accepts groups as a JSON list (a literal YAML list or rendered Jinja list)" do
    inventory = build_inventory
    run_add_host(inventory, {"name" => "dyn1", "groups" => "[\"grp_a\", \"grp_b\"]"})

    inventory.get_hosts("grp_a").map(&.name).must_equal(["dyn1"])
    inventory.get_hosts("grp_b").map(&.name).must_equal(["dyn1"])
  end

  it "accepts the group: alias" do
    inventory = build_inventory
    run_add_host(inventory, {"name" => "dyn1", "group" => "solo"})

    inventory.get_hosts("solo").map(&.name).must_equal(["dyn1"])
  end

  it "updates/merges into the existing entry on a second call with the same name" do
    inventory = build_inventory
    run_add_host(inventory, {"name" => "dyn1", "groups" => "first", "ansible_host" => "1.2.3.4"})
    run_add_host(inventory, {"name" => "dyn1", "groups" => "second", "ansible_user" => "deploy"})

    inventory.hosts.size.must_equal(2)

    host = inventory.hosts["dyn1"].not_nil!
    host.vars["ansible_host"].as_s.must_equal("1.2.3.4")
    host.vars["ansible_user"].as_s.must_equal("deploy")

    inventory.get_hosts("first").map(&.name).must_equal(["dyn1"])
    inventory.get_hosts("second").map(&.name).must_equal(["dyn1"])
    inventory.get_hosts("dyn1").size.must_equal(1)
  end

  it "always reports changed: true" do
    inventory = build_inventory
    result = run_add_host(inventory, {"name" => "dyn1"})

    final = result.final_result.not_nil!
    final.as_h["changed"].as_bool.must_equal(true)
    expect(falsey?(final.as_h["failed"]?.try(&.as_bool))).must_equal(true)
  end

  it "fails cleanly without a name" do
    inventory = build_inventory
    result = run_add_host(inventory, {"groups" => "mygroup"})

    result.success?.must_equal(false)
    result.error_message.wont_be_nil
    inventory.hosts.size.must_equal(1)
  end

  it "is dispatched controller-only (no module upload, no plugins/*.cr binary)" do
    Krikri::ActionPluginManager.skips_module_dispatch?("ansible.builtin.add_host").must_equal(true)
    Krikri::ActionPluginManager.skips_module_dispatch?("add_host").must_equal(true)
  end
end
