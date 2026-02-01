require "json"

module CrystalPlay
  # UserFacts - Gathers user-related facts
  module UserFacts
    # Gather user facts
    # Populates: ansible_user_id, ansible_user_uid, ansible_user_gid, ansible_user_dir, ansible_user_shell
    def self.gather(facts : Hash(String, JSON::Any), execute_callback : Proc(String, String?))
      # ansible_user_id - current user
      user = execute_callback.call("whoami")
      facts["ansible_user_id"] = JSON::Any.new(user.strip) if user
      
      # ansible_user_uid - user ID
      uid = execute_callback.call("id -u")
      facts["ansible_user_uid"] = JSON::Any.new(uid.strip.to_i) if uid && !uid.strip.empty?
      
      # ansible_user_gid - group ID
      gid = execute_callback.call("id -g")
      facts["ansible_user_gid"] = JSON::Any.new(gid.strip.to_i) if gid && !gid.strip.empty?
      
      # ansible_user_dir - user home directory
      home = execute_callback.call("echo $HOME")
      facts["ansible_user_dir"] = JSON::Any.new(home.strip) if home
      
      # ansible_user_shell - user shell
      shell = execute_callback.call("echo $SHELL")
      facts["ansible_user_shell"] = JSON::Any.new(shell.strip) if shell
    end
  end
end
