# The ssh transport-failure wrapper an unreachable msg carries, shared by
# PluginManager (which books the transport failure) and the TaskExecutor's
# display/loop paths (which recompose it). Own leaf file for the same
# require-cycle reason become_messages.cr is one.
module Krikri
  module SSHUnreachableMsg
    # Ansible's ssh connection plugin leads a 255 exit's msg with one of two
    # wrappers, chosen by whether the failing exec carried pipelined stdin:
    # under pipelining the module payload rides exec_command's in_data, so
    # ssh.py's _bare_run raises 'Data could not be sent to remote host
    # "<host>". Make sure this host can be reached over ssh: <stderr>'
    # (host = the connection host), while every exec without stdin -
    # interpreter discovery, tmpdir creation, the task-end tmpdir cleanup -
    # falls to _handle_error's plain 'Failed to connect to the host via ssh:
    # <stderr>' (live-verified vs 2.21.5: an unreachable task shows the Data
    # lead only when pipelining lets the module exec be the host's FIRST ssh
    # usage, e.g. the implicit localhost or an explicit
    # ansible_python_interpreter; a host that still needs interpreter
    # discovery fails there first and keeps the plain lead). This engine's
    # upload-then-exec dispatch stands in for the module exec, so the
    # caller's pipelining setting picks the lead.
    def self.unreachable_msg(detail : String, pipelining : Bool, connection_host : String) : String
      if pipelining
        %(Data could not be sent to remote host "#{connection_host}". Make sure this host can be reached over ssh: #{detail})
      else
        "Failed to connect to the host via ssh: #{detail}"
      end
    end

    # Convenience form for the sites that hold the host and a vars context:
    # the connection host ansible embeds is its own (ansible_host or the
    # inventory name - Host#connection_host), and pipelining resolves from
    # the context with the env fallback below.
    def self.unreachable_msg(detail : String, vars : Hash(String, JSON::Any)?, host : Host) : String
      unreachable_msg(detail, pipelining_enabled?(vars), host.connection_host)
    end

    # The pipelining option's resolution, abbreviated to the layers this
    # engine models: the ansible_pipelining / ansible_ssh_pipelining vars
    # (ansible's highest-precedence layer) then the ANSIBLE_PIPELINING /
    # ANSIBLE_SSH_PIPELINING env vars, each parsed with ansible's boolean()
    # forms. An unparseable value leaves that layer unset - ansible would
    # fail the config load instead, but no other krikri behavior hangs on
    # the option, so guessing false beats crashing.
    def self.pipelining_enabled?(vars : Hash(String, JSON::Any)? = nil) : Bool
      if vars
        {"ansible_pipelining", "ansible_ssh_pipelining"}.each do |name|
          if raw = vars[name]?
            value = ansible_boolean?(raw)
            return value unless value.nil?
          end
        end
      end
      {"ANSIBLE_PIPELINING", "ANSIBLE_SSH_PIPELINING"}.each do |name|
        if raw = ENV[name]?
          value = ansible_boolean?(JSON::Any.new(raw))
          return value unless value.nil?
        end
      end
      false
    end

    # convert_bool.boolean()'s accepted forms over a config value; nil for
    # anything else so the caller falls through to the next layer.
    private def self.ansible_boolean?(raw : JSON::Any) : Bool?
      case value = raw.raw
      when Bool   then value
      when Int    then value == 1 ? true : value == 0 ? false : nil
      when String then ansible_boolean_string?(value)
      end
    end

    private def self.ansible_boolean_string?(value : String) : Bool?
      case value.strip.downcase
      when "y", "yes", "on", "1", "true", "t"  then true
      when "n", "no", "off", "0", "false", "f" then false
      end
    end
  end
end
