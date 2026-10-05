require "json"

module Krikri
  module PluginHelpers
    # DockerHealthWait - real community.docker's `docker_container
    # state=healthy` wait loop, behavior matched to the Ansible module
    # module.py's `wait_for_state` (as called for the healthy state with
    # `wait_states=['starting', 'unhealthy']`,
    # `complete_states=['healthy', None]`, `max_wait=healthy_wait_timeout`,
    # `health_state=True`) and its per-state failure wordings.
    #
    # Behavior mirrored exactly (live-verified against real
    # ansible-playbook 2.19.11 + the local docker/podman daemon unless
    # marked source-only):
    # - polls the container's inspect output, reading
    #   State.Health.Status; `None`/missing (no healthcheck) is
    #   immediately healthy - Ansible's own "`None` means that no health
    #   check enabled; simply treat this as 'healthy'".
    # - 'unhealthy' is a WAIT state, not an immediate failure: the loop
    #   keeps polling until the timeout expires (live-verified: real
    #   reports the timeout message, not an "unhealthy" message).
    # - poll delay starts at 1s and grows exponentially (*1.1) capped at
    #   10s (Ansible's own comment: 25 iterations to reach the cap).
    # - timeout: fires when `total_wait > max_wait or delay < 1e-4`
    #   (after clamping the last sleep to not overshoot max_wait) with
    #   Ansible's wording `Timeout of <max_wait> seconds exceeded while
    #   waiting for container "<id>"` (Float64 formatting, so
    #   healthy_wait_timeout: 8 renders as "8.0").
    # - a vanished container (inspect 404) fails with Ansible's
    #   (sic) "Encontered vanished container while waiting for container
    #   "<id>"" - the typo is Ansible's own, mirrored verbatim.
    # - any other health status fails with Ansible's "Encontered unexpected
    #   state "<status>" while waiting for container "<id>"" (in
    #   practice unreachable for real daemons, whose only health
    #   statuses are starting/healthy/unhealthy/none).
    # - other inspect errors fail with Ansible's "Error inspecting
    #   container: <error>".
    #
    # Both the inspect call and the sleep are injected so the loop is
    # unit-testable without a daemon (sleep_fn in tests returns
    # immediately; the plugin passes a real `sleep`).
    module DockerHealthWait
      # Ansible's fail() carries the last inspect result into the result
      # dict as `container:` (timeout and unexpected-state cases) - nil
      # for the vanished case, where there is nothing to inspect.
      class Failure < Exception
        getter container_json : JSON::Any?

        def initialize(message : String, @container_json : JSON::Any? = nil)
          super(message)
        end
      end

      # Returns the full inspect JSON (never nil) on success - real
      # replaces self.facts with the returned inspect result, which is
      # what lands in the module result's `container:` key.
      alias InspectFn = Proc(JSON::Any?)
      alias SleepFn = Proc(Float64, Nil)

      WAIT_STATES     = ["starting", "unhealthy"] of String?
      COMPLETE_STATES = ["healthy", nil] of String?

      # Ansible's `state_info.get('Status')` on `State.Health` - missing
      # State, missing Health (no healthcheck) or missing Status all
      # mean None (immediately healthy).
      def self.health_status(inspect_json : JSON::Any) : String?
        inspect_json.dig?("State", "Health", "Status").try(&.as_s?)
      end

      def self.wait_for_healthy(
        container_id : String,
        max_wait : Float64?,
        inspect_fn : InspectFn,
        sleep_fn : SleepFn,
      ) : JSON::Any
        delay = 1.0
        total_wait = 0.0
        loop do
          result = inspect_fn.call
          unless result
            raise Failure.new(
              %(Encontered vanished container while waiting for container "#{container_id}"))
          end
          inspect_json = result.as(JSON::Any)
          state = health_status(inspect_json)
          # Complete check first, exactly like real (nil = no
          # healthcheck => immediately healthy).
          return inspect_json if COMPLETE_STATES.includes?(state)
          unless WAIT_STATES.includes?(state)
            raise Failure.new(
              %(Encontered unexpected state "#{state}" while waiting for container "#{container_id}"),
              inspect_json)
          end
          if max_wait
            if total_wait > max_wait || delay < 1e-4
              raise Failure.new(
                %(Timeout of #{max_wait} seconds exceeded while waiting for container "#{container_id}"),
                inspect_json)
            end
            if total_wait + delay > max_wait
              delay = max_wait - total_wait
            end
          end
          sleep_fn.call(delay)
          total_wait += delay
          # Exponential backoff, never longer than 10 seconds (Ansible's
          # own comment: 25 iterations to reach the cap).
          delay = {delay * 1.1, 10.0}.min
        end
      end
    end
  end
end
