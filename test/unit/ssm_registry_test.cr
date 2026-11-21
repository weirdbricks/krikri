require "../minitest_helper"
require "../../src/krikri/ssm_registry"

class FakeSsmSession
  include Krikri::SsmRegistry::SessionHandle

  getter? terminated = false

  def write(bytes : Bytes) : Nil
  end

  def write(text : String) : Nil
  end

  def read? : KrikriAwsSsm::Output?
    nil
  end

  def closed? : Bool
    @terminated
  end

  def close_reason : KrikriAwsSsm::CloseReason?
    nil
  end

  def error : Exception?
    nil
  end

  def exit_code : Int32?
    nil
  end

  def terminate : Nil
    @terminated = true
  end

  def resume : Nil
  end
end

private def registry_settings(region : String = "us-east-1", document : String? = nil) : Krikri::SsmSettings
  Krikri::SsmSettings.new("i-0123456789", region: region, document: document)
end

describe Krikri::SsmRegistry do
  serial!

  before_each do
    Krikri::SsmRegistry.close_all
    Krikri::SsmRegistry.session_factory = nil
  end

  after_each do
    Krikri::SsmRegistry.close_all
    Krikri::SsmRegistry.session_factory = nil
  end

  private def install_factory(created : Array(Krikri::SsmSettings)) : Nil
    Krikri::SsmRegistry.session_factory =
      ->(settings : Krikri::SsmSettings) : Krikri::SsmRegistry::SessionHandle {
        created << settings
        FakeSsmSession.new
      }
  end

  it "reuses one session for the same host and settings" do
    created = [] of Krikri::SsmSettings
    install_factory(created)
    settings = registry_settings

    first = Krikri::SsmRegistry.get_or_open("web1", settings)
    second = Krikri::SsmRegistry.get_or_open("web1", settings)

    first.same?(second).must_equal(true)
    created.size.must_equal(1)
    Krikri::SsmRegistry.size.must_equal(1)
  end

  it "does not alias two inventory names for one instance" do
    created = [] of Krikri::SsmSettings
    install_factory(created)
    settings = registry_settings

    one = Krikri::SsmRegistry.get_or_open("web1", settings)
    two = Krikri::SsmRegistry.get_or_open("web2", settings)

    one.same?(two).must_equal(false)
    created.size.must_equal(2)
    Krikri::SsmRegistry.size.must_equal(2)
  end

  it "opens a new session when the resolved settings identity changes" do
    created = [] of Krikri::SsmSettings
    install_factory(created)

    first = Krikri::SsmRegistry.get_or_open("web1", registry_settings(region: "us-east-1"))
    second = Krikri::SsmRegistry.get_or_open("web1", registry_settings(region: "us-west-2"))

    first.same?(second).must_equal(false)
    created.size.must_equal(2)
    Krikri::SsmRegistry.size.must_equal(2)
  end

  it "drops a closed session and opens a replacement" do
    created = [] of Krikri::SsmSettings
    install_factory(created)
    settings = registry_settings

    first = Krikri::SsmRegistry.get_or_open("web1", settings)
    first.terminate
    second = Krikri::SsmRegistry.get_or_open("web1", settings)

    first.same?(second).must_equal(false)
    created.size.must_equal(2)
  end

  it "reset terminates and forgets a host's sessions" do
    created = [] of Krikri::SsmSettings
    install_factory(created)
    settings = registry_settings

    one = Krikri::SsmRegistry.get_or_open("web1", settings)
    two = Krikri::SsmRegistry.get_or_open("web2", settings)
    Krikri::SsmRegistry.reset("web1")

    one.closed?.must_equal(true)
    two.closed?.must_equal(false)
    Krikri::SsmRegistry.size.must_equal(1)
  end

  it "close_all terminates and clears every session" do
    created = [] of Krikri::SsmSettings
    install_factory(created)
    settings = registry_settings

    one = Krikri::SsmRegistry.get_or_open("web1", settings)
    two = Krikri::SsmRegistry.get_or_open("web2", settings)
    Krikri::SsmRegistry.close_all

    one.closed?.must_equal(true)
    two.closed?.must_equal(true)
    Krikri::SsmRegistry.size.must_equal(0)
  end

  it "opens different hosts concurrently without holding the global mutex" do
    a_started = Channel(Nil).new(1)
    b_started = Channel(Nil).new(1)
    release_a = Channel(Nil).new(1)
    results = Channel(String).new(2)
    Krikri::SsmRegistry.session_factory =
      ->(settings : Krikri::SsmSettings) : Krikri::SsmRegistry::SessionHandle {
        if settings.target == "i-a"
          a_started.send(nil)
          release_a.receive
        else
          b_started.send(nil)
        end
        FakeSsmSession.new
      }

    spawn do
      Krikri::SsmRegistry.get_or_open("a", Krikri::SsmSettings.new("i-a"))
      results.send("a")
    end
    spawn do
      Krikri::SsmRegistry.get_or_open("b", Krikri::SsmSettings.new("i-b"))
      results.send("b")
    end

    a_started.receive
    select
    when b_started.receive
    when timeout(500.milliseconds)
      raise "host B's session open was blocked behind host A's"
    end
    release_a.send(nil)
    results.receive
    results.receive
    Krikri::SsmRegistry.size.must_equal(2)
  end

  it "opens one session when the same key is requested concurrently" do
    calls = Atomic(Int32).new(0)
    release = Channel(Nil).new(1)
    results = Channel(Krikri::SsmRegistry::SessionHandle).new(2)
    settings = registry_settings
    Krikri::SsmRegistry.session_factory =
      ->(_settings : Krikri::SsmSettings) : Krikri::SsmRegistry::SessionHandle {
        calls.add(1)
        release.receive
        FakeSsmSession.new
      }

    2.times do
      spawn { results.send(Krikri::SsmRegistry.get_or_open("same", settings)) }
    end
    sleep 100.milliseconds
    calls.get.must_equal(1)
    release.send(nil)
    first = results.receive
    second = results.receive
    first.same?(second).must_equal(true)
    calls.get.must_equal(1)
  end

  it "tracks the shell bootstrap state per session" do
    created = [] of Krikri::SsmSettings
    install_factory(created)
    session = Krikri::SsmRegistry.get_or_open("web1", registry_settings)

    Krikri::SsmRegistry.prepared?(session).must_equal(false)
    Krikri::SsmRegistry.mark_prepared(session)
    Krikri::SsmRegistry.prepared?(session).must_equal(true)

    Krikri::SsmRegistry.reset("web1")
    Krikri::SsmRegistry.prepared?(session).must_equal(false)
  end
end
