require "../spec_helper"
require "../../src/krikri/task_executor/handler_runner"

private def make_host(name : String = "localhost") : Krikri::Host
  Krikri::Host.new(name, "user", 22)
end

private def make_handler(name : String) : Krikri::Task
  Krikri::Task.new(name, "ansible.builtin.debug")
end

private def fresh_results(host : Krikri::Host) : Hash(String, Hash(String, Int32))
  {host.name => {"ok" => 0, "changed" => 0, "failed" => 0, "skipped" => 0, "rescued" => 0}}
end

private def counting_callback(counter : Array(Int32)) : Proc(Krikri::Task, Krikri::Host, JSON::Any)
  ->(_handler : Krikri::Task, _host : Krikri::Host) {
    counter[0] += 1
    JSON.parse({"changed" => true, "failed" => false}.to_json)
  }
end

describe Krikri::HandlerRunner do
  it "runs a notified handler exactly once" do
    host = make_host
    runner = Krikri::HandlerRunner.new([make_handler("restart service")], [host])
    runner.notify(host, "restart service")

    counter = [0]
    runner.run(counting_callback(counter), fresh_results(host), false)

    counter[0].should eq(1)
  end

  it "does not run a handler that was never notified" do
    host = make_host
    runner = Krikri::HandlerRunner.new([make_handler("restart service")], [host])

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
    runner = Krikri::HandlerRunner.new([make_handler("greeted"), make_handler("greeted")], [host])
    runner.notify(host, "greeted")

    counter = [0]
    runner.run(counting_callback(counter), fresh_results(host), false)

    counter[0].should eq(1)
  end

  it "supports appending handlers after construction (used by include_role:)" do
    host = make_host
    runner = Krikri::HandlerRunner.new([] of Krikri::Task, [host])
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
    runner = Krikri::HandlerRunner.new([handler], [host])
    runner.notify(host, "web services restarted")

    counter = [0]
    runner.run(counting_callback(counter), fresh_results(host), false)

    counter[0].should eq(1)
  end

  it "runs handlers in definition order, not notification order" do
    host = make_host
    first = make_handler("first")
    second = make_handler("second")
    runner = Krikri::HandlerRunner.new([first, second], [host])
    # Notify in reverse order
    runner.notify(host, "second")
    runner.notify(host, "first")

    order = [] of String
    callback = ->(handler : Krikri::Task, _host : Krikri::Host) {
      order << handler.name
      JSON.parse({"changed" => true, "failed" => false}.to_json)
    }
    runner.run(callback, fresh_results(host), false)

    order.should eq(["first", "second"])
  end

  it "second-pass backward notification matches the earlier handler's RENDERED name" do
    # Regression: a handler re-notifying an EARLIER handler by the name
    # that name_resolver renders it to (the entire reason the resolver
    # exists - role handlers' names are frequently templates) used to be
    # matched against the raw `candidate.name` instead, never found its
    # target, and the second pass silently didn't fire.
    host = make_host
    early = make_handler("Restart {{ svc }}")
    late = make_handler("late")
    late.notify = ["Restart mysvc"]
    runner = Krikri::HandlerRunner.new([early, late], [host])
    runner.notify(host, "late")

    counts = Hash(String, Int32).new(0)
    callback = ->(handler : Krikri::Task, _host : Krikri::Host) {
      counts[handler.name] += 1
      JSON.parse({"changed" => true, "failed" => false}.to_json)
    }
    # Render "{{ svc }}" the way TaskExecutor's real resolver would.
    resolver = ->(task : Krikri::Task, _host : Krikri::Host) {
      task.name.gsub("{{ svc }}", "mysvc")
    }
    runner.run(callback, fresh_results(host), false, resolver)

    # "late" ran once (notified); the backward notification it raised for
    # "Restart mysvc" must resolve to `early` (defined before it) and run
    # it exactly once in the second pass - not zero times.
    counts["Restart {{ svc }}"].should eq(1)
    counts["late"].should eq(1)
  end
end
