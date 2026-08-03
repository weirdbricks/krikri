module CrystalPlay
  module PluginHelpers
    # UfwCommand - pure logic for building the `ufw` command line for a
    # rule/state/default/logging change. No I/O here - the plugin itself
    # runs the resulting command and interprets its output.
    #
    # Rule command shape verified against community.general's actual
    # ufw.py source (the "long format" documented directly in its own
    # comment): `ufw [route] [delete | insert NUM] allow|deny|reject|limit
    # [in|out on INTERFACE] [log] [from ADDRESS [port PORT]]
    # [to ADDRESS [port PORT]] [proto protocol] [app application]
    # [comment COMMENT]`.
    module UfwCommand
      def self.state_command(state : String) : String?
        case state
        when "enabled"  then "ufw --force enable"
        when "disabled" then "ufw disable"
        when "reloaded" then "ufw --force reload"
        when "reset"    then "ufw --force reset"
        else                 nil
        end
      end

      def self.logging_command(value : String) : String
        "ufw logging #{value}"
      end

      def self.default_command(value : String, direction : String?) : String
        parts = ["ufw", "default", value]
        parts << direction if direction
        parts.join(" ")
      end

      # params keys read: route, delete, insert, rule, direction,
      # interface, interface_in, interface_out, log, from_ip, from_port,
      # to_ip, to_port, proto, name, comment. `dry_run` inserts ufw's own
      # `--dry-run` flag right after the binary name, matching its real
      # position in the "long format" (`ufw [--dry-run] [route] ...`).
      def self.rule_command(params : Hash(String, String), dry_run : Bool = false) : String
        parts = ["ufw"]
        parts << "--dry-run" if dry_run
        parts << "route" if truthy?(params["route"]?)
        parts << "delete" if truthy?(params["delete"]?)

        if insert = params["insert"]?
          parts << "insert #{insert}" unless truthy?(params["delete"]?)
        end

        parts << params["rule"].to_s
        if direction = params["direction"]?
          parts << direction
        end
        append_interface(parts, params)
        parts << "log" if truthy?(params["log"]?)
        append_endpoints(parts, params)
        parts << "proto #{params["proto"]}" if params["proto"]?
        parts << "app '#{params["name"]}'" if params["name"]?
        parts << "comment '#{params["comment"]}'" if params["comment"]?

        parts.join(" ")
      end

      # from_ip/from_port/to_ip/to_port are four independent appends in
      # real Ansible's source (a plain list of (key, template) pairs
      # each checked on their own), not two ip+port pairs - a port given
      # without its matching ip still gets appended alone.
      private def self.append_endpoints(parts : Array(String), params : Hash(String, String))
        parts << "from #{params["from_ip"]}" if params["from_ip"]?
        parts << "port #{params["from_port"]}" if params["from_port"]?
        parts << "to #{params["to_ip"]}" if params["to_ip"]?
        parts << "port #{params["to_port"]}" if params["to_port"]?
      end

      private def self.append_interface(parts : Array(String), params : Hash(String, String))
        if interface = params["interface"]?
          parts << "on #{interface}"
        elsif interface_in = params["interface_in"]?
          parts << "in on #{interface_in}"
        elsif interface_out = params["interface_out"]?
          parts << "out on #{interface_out}"
        end
      end

      private def self.truthy?(value : String?) : Bool
        return false unless value
        ["true", "yes", "1", "on"].includes?(value.downcase)
      end

      # Real ufw prints a line containing "Skipping" (e.g. "Skipping
      # adding existing rule") and exits 0 when a rule command is a
      # no-op - verified against community.general's actual ufw.py
      # source, which checks for exactly this substring
      # (`filter_line_that_contains("Skipping", rules_dry)`) to decide
      # `changed` in check mode. Used here as the changed signal for a
      # real (non-dry-run) application too, since replicating ufw's full
      # rule-tuple diffing logic would need actually-working netfilter
      # access to verify - not available in this project's Docker-based
      # compat harness (rootless podman container), so this is
      # source-verified but not further behavior-verified end-to-end the
      # way every other plugin in this codebase has been.
      def self.changed_from_output?(output : String) : Bool
        !output.includes?("Skipping")
      end
    end
  end
end
