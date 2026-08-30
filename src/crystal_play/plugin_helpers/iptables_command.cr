module CrystalPlay
  module PluginHelpers
    # Pure rule-construction logic for `plugins/iptables.cr`, split out so
    # it can be unit-tested without a real `iptables` binary/root
    # (`-C`/`-A`/`-D` all require CAP_NET_ADMIN, unavailable in the spec
    # sandbox - see `plugins/iptables.cr`'s own doc comment). Mirrors
    # real Ansible's `construct_rule()` flag-for-flag, including its
    # exact ordering (matters for `-C` to actually match what `-A`
    # would insert).
    module IptablesCommand
      def self.construct_rule(params : Hash(String, String)) : Array(String)
        rule = [] of String
        append_param(rule, params["protocol"]?, "-p")
        append_param(rule, params["source"]?, "-s")
        append_param(rule, params["destination"]?, "-d")
        each_csv(params["match"]?) { |mat| rule.concat(["-mat", mat]) }
        append_param(rule, params["jump"]?, "-j")
        append_param(rule, params["log_prefix"]?, "--log-prefix")
        append_param(rule, params["log_level"]?, "--log-level")
        append_param(rule, params["to_destination"]?, "--to-destination")
        if dports = params["destination_ports"]?
          rule.concat(["-m", "multiport"]) unless rule.includes?("multiport")
          rule.concat(["--dports", dports])
        end
        append_param(rule, params["to_source"]?, "--to-source")
        append_param(rule, params["in_interface"]?, "-i")
        append_param(rule, params["out_interface"]?, "-o")
        append_param(rule, params["fragment"]?, "-f")
        append_param(rule, params["source_port"]?, "--source-port")
        append_param(rule, params["destination_port"]?, "--destination-port")
        append_param(rule, params["to_ports"]?, "--to-ports")
        append_syn(rule, params["syn"]?)
        if ctstate = params["ctstate"]?
          append_ctstate(rule, ctstate, params["match"]? || "")
        end
        append_param(rule, params["limit"]?, "--limit")
        append_param(rule, params["limit_burst"]?, "--limit-burst")
        if params["jump"]?.nil?
          append_jump(rule, params["reject_with"]?, "REJECT")
        end
        append_param(rule, params["reject_with"]?, "--reject-with")
        icmp_flag = (params["ip_version"]? == "ipv6") ? "--icmpv6-type" : "--icmp-type"
        append_param(rule, params["icmp_type"]?, icmp_flag)
        if comment = params["comment"]?
          rule.concat(["-m", "comment", "--comment", shell_single_quote(comment)])
        end
        rule
      end

      private def self.append_syn(rule : Array(String), syn : String?)
        if syn == "match"
          rule << "--syn"
        elsif syn == "negate"
          rule.concat(["!", "--syn"])
        end
      end

      private def self.append_ctstate(rule : Array(String), ctstate : String, matches : String)
        if matches.includes?("conntrack")
          rule.concat(["--ctstate", ctstate])
        elsif matches.includes?("state")
          rule.concat(["--state", ctstate])
        else
          rule.concat(["-m", "conntrack", "--ctstate", ctstate])
        end
      end

      private def self.append_jump(rule : Array(String), value : String?, jump : String)
        return unless value
        rule.concat(["-j", jump])
      end

      private def self.append_param(rule : Array(String), value : String?, flag : String)
        return unless value
        if value.starts_with?('!')
          rule.concat(["!", flag, value[1..]])
        else
          rule.concat([flag, value])
        end
      end

      private def self.each_csv(value : String?, &)
        return unless value
        value.split(',').each { |v| yield v.strip unless v.strip.empty? }
      end

      def self.shell_single_quote(str : String) : String
        "'" + str.gsub("'", "'\\\\''") + "'"
      end
    end
  end
end
