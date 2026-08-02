require "../spec_helper"
require "../../src/crystal_play/task_executor/handler_runner"

private def make_host(name : String = "localhost") : CrystalPlay::Host
  CrystalPlay::Host.new(name, "user", 22)
end

private def make_handler(name : String) : CrystalPlay::Task
  CrystalPlay::Task.new(name, "ansible.builtin.debug")
end

private def fresh_results(host : CrystalPlay::Host) : Hash(String, Hash(String, Int32))
  {host.name => {"ok" => 0, "changed" => 0, "failed" => 0, "skipped" => 0, "rescued" => 0}}
end

private def counting_callback(counter : Array(Int32)) : Proc(CrystalPlay::Task, CrystalPlay::Host, JSON::Any)
  ->(_handler : CrystalPlay::Task, _host : CrystalPlay::Host) {
    counter[0] += 1
    JSON.parse({"changed" => true, "failed" => false}.to_json)
  }
end

describe CrystalPlay::HandlerRunner do
  it "runs a notified handler exactly once" do
    host = make_host
    runner = CrystalPlay::HandlerRunner.new([make_handler("restart service")], [host])
    runner.notify(host, "restart service")

    counter = [0]
    runner.run(counting_callback(counter), fresh_results(host), false)

    counter[0].should eq(1)
  end

  it "does not run a handler that was never notified" do
    host = make_host
    runner = CrystalPlay::HandlerRunner.new([make_handler("restart service")], [host])

    counter = [0]
    runner.run(counting_callback(counter), fresh_results(host), false)

    counter[0].should eq(0)
  end

  it "runs each uniquely named handler at most once per host, even across multiple distinct Task objects sharing that name" do
    # Regression: include_role: (possibly looped) dynamically appends new
    # Task objects to @handlers. Two loop iterations of the same role
    # produce two separate Task objects both named "greeted" - without
    # dedup by name, each independently matched the notified set and the
    # handler fired twice for a single notification.
    host = make_host
    runner = CrystalPlay::HandlerRunner.new([make_handler("greeted"), make_handler("greeted")], [host])
    runner.notify(host, "greeted")

    counter = [0]
    runner.run(counting_callback(counter), fresh_results(host), false)

    counter[0].should eq(1)
  end

  it "supports appending handlers after construction (used by include_role:)" do
    host = make_host
    runner = CrystalPlay::HandlerRunner.new([] of CrystalPlay::Task, [host])
    runner.handlers.concat([make_handler("dynamic handler")])
    runner.notify(host, "dynamic handler")

    counter = [0]
    runner.run(counting_callback(counter), fresh_results(host), false)

    counter[0].should eq(1)
  end

  it "fires a handler notified by its listen: topic" do
    host = make_host
    handler = make_handler("restart web")
    handler.listen = "web services restarted"
    runner = CrystalPlay::HandlerRunner.new([handler], [host])
    runner.notify(host, "web services restarted")

    counter = [0]
    runner.run(counting_callback(counter), fresh_results(host), false)

    counter[0].should eq(1)
  end

  it "runs handlers in definition order, not notification order" do
    host = make_host
    first = make_handler("first")
    second = make_handler("second")
    runner = CrystalPlay::HandlerRunner.new([first, second], [host])
    # Notify in reverse order
    runner.notify(host, "second")
    runner.notify(host, "first")

    order = [] of String
    callback = ->(handler : CrystalPlay::Task, _host : CrystalPlay::Host) {
      order << handler.name
      JSON.parse({"changed" => true, "failed" => false}.to_json)
    }
    runner.run(callback, fresh_results(host), false)

    order.should eq(["first", "second"])
  end
end
