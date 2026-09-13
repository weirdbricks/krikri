module Krikri
  module PluginHelpers
    # The pure half of real Ansible's ServiceMgrFactCollector
    # (module_utils/facts/system/service_mgr.py): what PID 1's comm
    # contributes to the ansible_service_mgr fact.
    #
    # Real Ansible discards "init" (too many systems name it) and
    # anything ending in "sh" (a container's PID 1 shell) as
    # unidentifiable - those fall through to the Linux fallbacks
    # (systemd canaries, upstart, openrc, the OFFLINE systemd check of
    # systemctl + /sbin/init symlinked to systemd, sysvinit, dinit,
    # generic "service"). Every other comm value is taken AT FACE
    # VALUE as the manager name - including ones that name no service
    # module at all (a container whose PID 1 is `sleep infinity`
    # reports the fact "sleep"), which the service action plugin then
    # treats as "no known manager module" and falls back to the
    # generic service module.
    #
    # The filesystem-dependent fallback chain itself lives twice, once
    # natively in FactsGatherer (which runs on the target) and once as
    # the equivalent shell in ServicePlugin's probe (which goes through
    # remote_exec) - both reproduce this collector's own order.
    module ServiceMgrFact
      extend self

      # Real Ansible's proc_1_map: PID 1 comm values that mean a custom
      # init, mapped to the fact value real Ansible reports for them.
      PROC1_MAP = {
        "procd"       => "openwrt_init",
        "runit-init"  => "runit",
        "svscan"      => "svc",
        "openrc-init" => "openrc",
      }

      # Returns the fact value PID 1's comm yields, or nil when real
      # Ansible would discard it and fall through to the Linux
      # fallback chain.
      def from_proc1(comm : String?) : String?
        return nil if comm.nil? || comm.empty? || comm == "init" || comm.ends_with?("sh")

        PROC1_MAP.fetch(comm, comm)
      end

      # The service ACTION plugin's module resolution
      # (ansible/plugins/action/service.py): an explicit `use:` names
      # the manager module directly ("auto"/absent means detect, and a
      # use: value that names no module falls back to the generic
      # service module); with auto, the ansible_service_mgr fact picks
      # the module - fact "systemd" runs the SYSTEMD module (whose
      # systemctl calls then fail honestly on a host with no running
      # init), every other fact value - including ones that name no
      # module at all, like a container's PID 1 "sleep" - runs the
      # generic service module's own detection.
      def runs_systemd_module?(use : String?, fact : String?) : Bool
        return false unless use.nil? || use.empty? || use.downcase == "auto"

        fact == "systemd"
      end
    end
  end
end
