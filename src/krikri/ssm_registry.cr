require "krikri-aws-ssm"
require "./ssm_settings"
require "./task_executor/result_display"

module Krikri
  # The live KrikriAwsSsm sessions for one run, keyed by the exact
  # dispatch tuple: the inventory host name plus the resolved
  # SsmSettings identity.
  #
  # Two inventory names for one instance therefore get two sessions (their
  # tasks may run concurrently), and a task-level ansible_connection flip
  # to different SSM settings gets a new entry rather than reusing the
  # first host's session. `closed?` sessions are dropped and reopened
  # lazily; nothing here decides whether a host is SSM - that is always
  # ConnectionSettings/ConnectionTypes, so a lazily-created session can
  # never make a host take the SSM path.
  class SsmRegistry
    # The slice of KrikriAwsSsm::Session the registry and transport use.
    # The shard class includes it below, and test doubles include it too,
    # so the registry's session factory can be injected without a network.
    module SessionHandle
      abstract def write(bytes : Bytes) : Nil
      abstract def write(text : String) : Nil
      abstract def read? : KrikriAwsSsm::Output?
      abstract def closed? : Bool
      abstract def close_reason : KrikriAwsSsm::CloseReason?
      abstract def error : Exception?
      abstract def exit_code : Int32?
      abstract def terminate : Nil
      abstract def resume : Nil
    end

    alias Key = {String, String}
    alias SessionFactory = Proc(SsmSettings, SessionHandle)

    @@mutex = Mutex.new
    @@entries = Hash(Key, SessionHandle).new
    @@prepared = Set(UInt64).new
    # One mutex per dispatch key: two fibers for the same host/settings
    # must not open two sessions, but different hosts must open in
    # parallel (the factory blocks on StartSession/handshake/websocket).
    @@key_mutexes = Hash(Key, Mutex).new
    # One operation mutex per live session: the shell protocol is not
    # reentrant (markers from two commands would interleave), so exec,
    # script, upload and download serialize on it.
    @@operation_locks = Hash(UInt64, Mutex).new
    @@factory : SessionFactory? = nil
    @@default_factory : SessionFactory? = nil
    @@at_exit_installed = false

    # An injected factory wins over the shard-backed default (tests use
    # this); nil restores the default.
    def self.session_factory=(factory : SessionFactory?) : Nil
      @@mutex.synchronize { @@factory = factory }
    end

    # Installed by ssm_transport.cr once the shard is in the compile.
    def self.default_factory=(factory : SessionFactory?) : Nil
      @@mutex.synchronize { @@default_factory = factory }
    end

    # Returns the live session for (host_name, settings), opening one on
    # first use. A closed session is dropped and replaced.
    #
    # The session is opened while holding only its own key mutex, never the
    # registry-wide mutex: StartSession + websocket handshake can take
    # hundreds of milliseconds and must not serialize every other host.
    def self.get_or_open(host_name : String, settings : SsmSettings) : SessionHandle
      key = {host_name, settings.identity_key}
      key_mutex = @@mutex.synchronize { @@key_mutexes[key] ||= Mutex.new }
      opened = false

      session = key_mutex.synchronize do
        existing = @@mutex.synchronize { @@entries[key]? }
        if existing
          if existing.closed?
            @@mutex.synchronize do
              @@entries.delete(key)
              @@prepared.delete(existing.object_id)
            end
          else
            next existing
          end
        end

        factory = @@mutex.synchronize { @@factory || @@default_factory } ||
                  raise "no SSM session factory configured (ssm_transport.cr not loaded)"
        opened_session = factory.call(settings)
        @@mutex.synchronize do
          @@entries[key] = opened_session
          install_at_exit
        end
        opened = true
        opened_session
      end

      # Emitted outside the mutex: the display layer may redirect a task's
      # output and the warning is deduped process-wide, so repeated opens
      # still print each ignored option once.
      if opened
        settings.ignored_warnings.each { |text| ResultDisplay.emit_action_warning(text) }
      end

      session
    end

    # The mutex serializing shell operations on one session. The hash entry
    # is deliberately not removed on reset/close: an object-id collision
    # merely serializes two unrelated sessions, while removing a lock a
    # fiber still holds would let a second operation interleave.
    def self.operation_lock(session : SessionHandle) : Mutex
      @@mutex.synchronize { @@operation_locks[session.object_id] ||= Mutex.new }
    end

    # Whether the transport already ran the shell bootstrap (stty -echo,
    # prompt suppression) on this session.
    def self.prepared?(session : SessionHandle) : Bool
      @@mutex.synchronize { @@prepared.includes?(session.object_id) }
    end

    def self.mark_prepared(session : SessionHandle) : Nil
      @@mutex.synchronize { @@prepared << session.object_id }
    end

    # meta: reset_connection - terminate this host's SSM sessions and
    # forget them so the next task opens fresh ones.
    def self.reset(host_name : String) : Nil
      dropped = [] of SessionHandle
      @@mutex.synchronize do
        keys = @@entries.keys.select { |(host, _)| host == host_name }
        keys.each do |key|
          session = @@entries.delete(key)
          next unless session
          @@prepared.delete(session.object_id)
          dropped << session
        end
      end
      dropped.each { |session| terminate_quietly(session) }
    end

    # Explicit alias for the plan's "reset/terminate" lifecycle wording.
    def self.terminate(host_name : String) : Nil
      reset(host_name)
    end

    # close_connection's SSM analogue. The SSH method receives the
    # connect address, not the inventory name, so match either the
    # host-name key or the session's resolved target.
    def self.close_connection(host_name : String, target : String? = nil) : Nil
      dropped = [] of SessionHandle
      @@mutex.synchronize do
        keys = @@entries.keys.select { |(host, _)| host == host_name || host == target }
        keys.each do |key|
          session = @@entries.delete(key)
          next unless session
          @@prepared.delete(session.object_id)
          dropped << session
        end
      end
      dropped.each { |session| terminate_quietly(session) }
    end

    # Terminates every live session. *bounded* caps how long the caller
    # waits (used by the at_exit safety net so a wedged control-plane
    # call cannot hold the process open).
    def self.close_all(bounded : Time::Span? = nil) : Nil
      sessions = [] of SessionHandle
      @@mutex.synchronize do
        @@entries.each_value { |session| sessions << session }
        @@entries.clear
        @@prepared.clear
      end
      return if sessions.empty?

      if bound = bounded
        done = Channel(Nil).new(1)
        spawn do
          sessions.each { |session| terminate_quietly(session) }
          done.send(nil)
        end
        select
        when done.receive
        when timeout(bound)
        end
      else
        sessions.each { |session| terminate_quietly(session) }
      end
    end

    # Spec/diagnostic seam: how many live entries the registry holds.
    def self.size : Int32
      @@mutex.synchronize { @@entries.size }
    end

    private def self.terminate_quietly(session : SessionHandle) : Nil
      session.terminate
    rescue
    end

    private def self.install_at_exit : Nil
      return if @@at_exit_installed
      @@at_exit_installed = true
      at_exit do
        SsmRegistry.close_all(bounded: 2.seconds)
      rescue
      end
    end
  end
end

# Make the shard's session satisfy the registry/transport interface
# without wrapping it: the shard already implements every member.
module KrikriAwsSsm
  class Session
    include Krikri::SsmRegistry::SessionHandle
  end
end
