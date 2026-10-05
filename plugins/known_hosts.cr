#!/usr/bin/env crystal

# known_hosts module (ansible.builtin.known_hosts) - adds/removes a host
# key entry from an SSH known_hosts file, using the real `ssh-keygen`
# binary for lookup/removal (same approach Ansible's own module uses
# for the -F/-R side, though it also hand-parses the file itself - this
# implementation leans on ssh-keygen throughout, including for the
# present-with-matching-key idempotency check, since it already
# understands hashed (`hash_host: true`) entries without needing to
# replicate that hashing here). The hash_host itself is done the way
# the Ansible module does: hashing happens BEFORE the lookup/mutation (its
# hash_host_key replaces the hostname field with |1|<salt>|<HMAC-SHA1>
# before sanity_check/search_for_host_key run), never on the rest of the
# file; the echoed `key` in the result is the original param.
#
# Parameters:
#   name (required, alias host): hostname/IP the entry is for
#   key (required for state=present): full known_hosts-formatted key
#     line(s) (e.g. "example.com ssh-ed25519 AAAA...")
#   path (optional): known_hosts file (default ~/.ssh/known_hosts)
#   state (optional): "present" (default) or "absent"
#   hash_host (optional bool): hash the hostname portion once added

require "json"
require "base64"
require "../src/krikri/base_plugin"
require "../src/krikri/plugin_helpers/known_hosts_key"

module Krikri
  class KnownHostsPlugin < BasePlugin
    # ansible.builtin.known_hosts's `type: bool` options, in the real argument-spec
    # declaration order (ansible-doc -j ansible.builtin.known_hosts). Validated at
    # module setup by BasePlugin#validate_bool_params! - see its block
    # comment for the real-Ansible semantics and message wording.
    protected def bool_params : Array(String)
      %w[hash_host]
    end

    # Registered-result key order (live-verified vs ansible-core 2.19.11 on
    # Ubuntu 22.04, round 992000 + local container replay): known_hosts.py's
    # main() does `results = copy.copy(module.params)` (echoing every param)
    # and `results.update(enforce_state(...))` (changed, then diff), then
    # AnsibleModule._return_formatted's add_path_info appends the stat block
    # (uid, gid, owner, group, mode, size) and overwrites `state` with the
    # path's kind ("file") - the executor backfills failed last. The echo
    # order itself follows the same rule as authorized_key's: explicitly-
    # passed params alphabetically (the controller sorts the module-args
    # handoff), then not-passed params in a fixed order (path, hash_host,
    # key), live-verified with key-less and hash_host-explicit subsets too.
    # The check-mode path exits INSIDE enforce_state with
    # exit_json(changed=, diff=) before the params echo ever merges, so it
    # registers [changed, diff, failed] with no echo keys and no stat block.
    KH_PARAM_DEFAULT_ORDER  = ["path", "hash_host", "key"]
    KH_STAT_ORDER           = ["uid", "gid", "owner", "group", "mode", "size"]
    KNOWN_HOSTS_CHECK_ORDER = ["changed", "diff"]

    private record HostKeySearch, found : Bool, replace_or_add : Bool, found_line : Int32?
    private record NormalizedKey, options : String?, host : String, type : String, key : String

    def execute : PluginResult
      validate_bool_params!
      name = @params["name"]? || @params["host"]?
      return PluginResult.new(changed: false, failed: true, msg: "missing required arguments: name") unless name

      state = normalized_state
      return state if state.is_a?(PluginResult)

      path = expanded_path
      key_param = @params["key"]?.presence
      work_key = working_key(key_param, name)

      if failure = pre_search_failure(state, key_param, work_key, name)
        return failure
      end

      search = search_for_host_key(name, path, work_key)
      return search if search.is_a?(PluginResult)

      diff = compute_diff(path, search.found_line, search.replace_or_add, state, work_key)

      # Real: removing a key that doesn't match any entry returns early
      # with no change (the full echo shape, not the bare check-mode one -
      # main()'s params echo still merges around this early return).
      if state == "absent" && search.found_line.nil? && key_param
        return full_result(name, path, state, changed: false, diff: diff)
      end

      if true?(@params["_ansible_check_mode"]?)
        changed = search.replace_or_add || (state == "present") != search.found
        return PluginResult.new(changed: changed, failed: false, diff: diff,
          key_order: KNOWN_HOSTS_CHECK_ORDER)
      end

      if failure = mutate(name, path, search, state, work_key, key_param)
        return failure
      end

      full_result(name, path, state, changed: mutation_changed?(search, state, key_param), diff: diff)
    end

    private def normalized_state : String | PluginResult
      state = @params["state"]?
      state = "present" if state.nil? || state.empty?
      unless {"present", "absent"}.includes?(state)
        return PluginResult.new(changed: false, failed: true, msg: "state must be 'present' or 'absent', got '#{state}'")
      end
      state
    end

    private def expanded_path : String
      raw_path = @params["path"]?
      raw_path = "~/.ssh/known_hosts" if raw_path.nil? || raw_path.empty?
      expand_tilde(raw_path)
    end

    # Real order: hash_host hashing happens BEFORE the sanity check and
    # the search, and a trailing newline is guaranteed on the working
    # key. The echoed `key` stays the original param.
    private def working_key(key_param : String?, name : String) : String?
      return nil unless key_param

      key = true?(@params["hash_host"]?) ? PluginHelpers::KnownHostsKey.hash_host_line(name, key_param.strip) : key_param
      key.ends_with?('\n') ? key : key + "\n"
    end

    private def pre_search_failure(state : String, key_param : String?, work_key : String?, name : String) : PluginResult?
      # Real enforce_state: "No key specified when adding a host" fires
      # before the sanity check (plain fail_json - no param echo).
      unless key_param || state == "absent"
        return PluginResult.new(changed: false, failed: true, msg: "No key specified when adding a host")
      end

      sanity_check(name, work_key) if work_key
    end

    # Whether the executed mutation (whole-host ssh-keygen -R for a
    # key-less absent, or the line rewrite) changed the file - the same
    # conditions Ansible's enforce_state sets `results['changed']` under.
    private def mutation_changed?(search : HostKeySearch, state : String, key_param : String?) : Bool
      whole_host_removal = search.found && key_param.nil? && state == "absent"
      rewrite = search.replace_or_add || search.found != (state == "present")
      whole_host_removal || rewrite
    end

    # The executed mutation: Ansible only ever runs ssh-keygen -R when
    # removing a whole host WITHOUT a key; with a key it rewrites the
    # file, dropping just the matched line (and appending the key for
    # state=present). Returns a failure result or nil on success.
    private def mutate(name : String, path : String, search : HostKeySearch, state : String, work_key : String?, key_param : String?) : PluginResult?
      if search.found && key_param.nil? && state == "absent"
        result = remote_exec("ssh-keygen -R #{shell_quote(name)} -f #{shell_quote(path)}")
        return PluginResult.new(changed: false, failed: true, msg: "failed to remove #{name}: #{result[:stderr].strip}") unless result[:exit_code] == 0
      end

      if search.replace_or_add || search.found != (state == "present")
        return rewrite(path, search.found_line, search.replace_or_add, state, work_key)
      end

      nil
    end

    # The non-check-mode registered shape: the echoed params (key may be
    # JSON null when state=absent was given without one), changed, diff,
    # then - because the result carries an existing `path` - add_path_info's
    # stat block, with `state` overwritten to the path's kind.
    private def full_result(name : String, path : String, state : String, changed : Bool, diff : JSON::Any) : PluginResult
      result = PluginResult.new(changed: changed, failed: false, diff: diff, key_order: result_key_order)
      if raw_key = @params["key"]?
        result.extra["key"] = JSON::Any.new(raw_key)
      else
        result.extra["key"] = JSON::Any.new(nil)
      end
      result.extra["name"] = JSON::Any.new(name)
      result.extra["path"] = JSON::Any.new(path)
      result.extra["hash_host"] = JSON::Any.new(true?(@params["hash_host"]?))
      if stat = path_stat(path)
        result.extra["uid"] = JSON::Any.new(stat[:uid])
        result.extra["gid"] = JSON::Any.new(stat[:gid])
        result.extra["owner"] = JSON::Any.new(stat[:owner])
        result.extra["group"] = JSON::Any.new(stat[:group])
        result.extra["mode"] = JSON::Any.new(stat[:mode])
        result.extra["size"] = JSON::Any.new(stat[:size])
        result.extra["state"] = JSON::Any.new(stat[:kind])
      else
        result.extra["state"] = JSON::Any.new(state)
      end
      result
    end

    private def result_key_order : Array(String)
      given = @params.keys.select { |key| !key.starts_with?("_ansible_") && key != "host" }.sort!
      given << "name" unless given.includes?("name")
      order = given.dup
      KH_PARAM_DEFAULT_ORDER.each do |key|
        order << key unless given.includes?(key)
      end
      order + ["changed", "diff"] + KH_STAT_ORDER
    end

    # add_path_info's stat block: uid/gid as ints, owner/group as names,
    # mode as Ansible's '0%03o' octal string, size as int, and the path kind
    # ('link' / 'directory' / 'hard' / 'file') that overwrites the echoed
    # state param. nil when the path doesn't exist (no stat keys at all,
    # state stays the original param).
    private def path_stat(path : String) : NamedTuple(uid: Int64, gid: Int64, owner: String, group: String, mode: String, size: Int64, kind: String)?
      result = remote_exec("stat -c '%u|%g|%U|%G|%s|%a|%h|%F' -- #{shell_quote(path)}")
      return nil unless result[:exit_code] == 0

      parts = result[:stdout].strip.split("|")
      return nil unless parts.size == 8

      uid = parts[0].to_i64?
      gid = parts[1].to_i64?
      size = parts[4].to_i64?
      nlink = parts[6].to_i64?
      return nil unless uid && gid && size && nlink

      kind = if parts[7].starts_with?("symbolic link")
               "link"
             elsif parts[7].starts_with?("directory")
               "directory"
             elsif nlink > 1
               "hard"
             else
               "file"
             end

      {
        uid:   uid,
        gid:   gid,
        owner: parts[2],
        group: parts[3],
        mode:  "0" + parts[5].rjust(3, '0'),
        size:  size,
        kind:  kind,
      }
    end

    # known_hosts.py sanity_check(): whenever a key is supplied, let
    # ssh-keygen -F look the host up in a temp file holding just that key -
    # a garbage key (or one whose host field does not match) finds nothing.
    private def sanity_check(host : String, key : String) : PluginResult?
      if host =~ /\S+(\s+)?,(\s+)?/
        return PluginResult.new(changed: false, failed: true,
          msg: "Comma separated list of names is not supported. Please pass a single name to lookup in the known_hosts file.")
      end

      tmp = "/tmp/krikri_known_hosts_#{Random::Secure.hex(6)}"
      remote_exec("printf '%s' #{shell_quote(key)} > #{shell_quote(tmp)}")
      lookup = remote_exec("ssh-keygen -F #{shell_quote(host)} -f #{shell_quote(tmp)}")
      remote_exec("rm -f #{shell_quote(tmp)}")
      return nil unless lookup[:stdout].empty?

      PluginResult.new(changed: false, failed: true, msg: "Host parameter does not match hashed host field in supplied key")
    end

    # known_hosts.py search_for_host_key(): (found, replace_or_add,
    # found_line) from one ssh-keygen -F run over the file. found_line is
    # the 1-based line number of the same-key-type entry (parsed from the
    # "# Host ... found: line N" comment lines ssh-keygen prints).
    private def search_for_host_key(name : String, path : String, key : String?) : HostKeySearch | PluginResult
      return HostKeySearch.new(false, false, nil) unless File.exists?(path)

      stdout = ssh_keygen_lookup(name, path)
      return stdout if stdout.is_a?(PluginResult)

      # No key supplied: found, but never replace anything with it.
      return HostKeySearch.new(true, false, nil) unless key

      new_key = normalize_key(key)
      return HostKeySearch.new(true, true, nil) unless new_key

      found_line : Int32? = nil
      stdout.split('\n').each do |line|
        next if line.empty?

        if line.starts_with?('#')
          if match = line.match(/found: line (\d+)/)
            found_line = match[1].to_i
          end
          next
        end
        found_key = normalize_key(line)
        next unless found_key

        if classified = classify_match(new_key, found_key, found_line)
          return classified
        end
      end

      HostKeySearch.new(true, true, nil)
    end

    # The raw ssh-keygen -F stdout for *name* in *path* ("" when the host
    # is simply absent), or the failure Ansible's module raises when
    # ssh-keygen itself goes wrong.
    private def ssh_keygen_lookup(name : String, path : String) : String | PluginResult
      result = remote_exec("ssh-keygen -F #{shell_quote(name)} -f #{shell_quote(path)}")
      if result[:stdout].empty? && result[:stderr].empty? && (result[:exit_code] == 0 || result[:exit_code] == 1)
        return ""
      end
      if result[:exit_code] != 0
        return PluginResult.new(changed: false, failed: true,
          msg: "ssh-keygen failed (rc=#{result[:exit_code]}, stdout='#{result[:stdout]}',stderr='#{result[:stderr]}')")
      end
      result[:stdout]
    end

    # Ansible's per-entry comparison: @cert-authority/@revoked entries only
    # ever match exactly; otherwise a hashed-vs-hashed host borrows the
    # found entry's host (the salts differ), an exact dict match is a
    # no-op, and a same-type mismatch means replace.
    private def classify_match(new_key : NormalizedKey, found_key : NormalizedKey, found_line : Int32?) : HostKeySearch?
      if opts = found_key.options
        if opts.starts_with?("@cert-authority") || opts.starts_with?("@revoked")
          return HostKeySearch.new(true, false, found_line) if new_key == found_key
          return nil
        end
      end

      host = new_key.host
      host = found_key.host if new_key.host.starts_with?("|1|") && found_key.host.starts_with?("|1|")
      effective = NormalizedKey.new(new_key.options, host, new_key.type, new_key.key)
      return HostKeySearch.new(true, false, found_line) if effective == found_key
      return HostKeySearch.new(true, true, found_line) if effective.type == found_key.type
      nil
    end

    # known_hosts.py normalize_known_hosts_key(): optional marker field,
    # then host, key type, blob - trailing comment information dropped.
    private def normalize_key(line : String) : NormalizedKey?
      parts = line.strip.split(/\s+/)
      return nil if parts.empty?

      if parts[0].starts_with?('@')
        return nil unless parts.size >= 4
        NormalizedKey.new(parts[0], parts[1], parts[2], parts[3])
      else
        return nil unless parts.size >= 3
        NormalizedKey.new(nil, parts[0], parts[1], parts[2])
      end
    end

    # known_hosts.py compute_diff(): before/after file content around the
    # planned mutation - computed BEFORE any mutation, so an unchanged
    # file yields before == after and a whole-host -R removal (which real
    # performs outside this function's line logic) still shows an
    # unmodified diff, exactly like real.
    private def compute_diff(path : String, found_line : Int32?, replace_or_add : Bool, state : String, key : String?) : JSON::Any
      before = ""
      before_header = path
      if File.exists?(path)
        begin
          before = File.read(path)
        rescue
          before = ""
        end
      else
        before_header = "/dev/null"
      end

      after = planned_lines(before, found_line, replace_or_add, state, key).join
      JSON.parse({
        "before_header" => before_header,
        "after_header"  => path,
        "before"        => before,
        "after"         => after,
      }.to_json)
    end

    # The line list Ansible's compute_diff (and, identically, its mutation
    # block) derives: drop the found_line-th line when removing/replacing,
    # append the (newline-terminated) key at the end for state=present.
    private def planned_lines(content : String, found_line : Int32?, replace_or_add : Bool, state : String, key : String?) : Array(String)
      lines = [] of String
      content.each_line(chomp: false) { |line| lines << line }

      if (replace_or_add || state == "absent") && found_line && found_line >= 1 && found_line <= lines.size
        lines.delete_at(found_line - 1)
      end
      if state == "present" && (replace_or_add || found_line.nil?) && key
        lines << key
      end
      lines
    end

    # The mutation real performs for keyed add/replace/remove: rewrite the
    # file (drop the matched line, append the key for state=present) via a
    # temp file in the same directory + rename. Attributes mirror Ansible's
    # atomic_move: an existing dest keeps its mode/owner, a newly created
    # file gets 0666 & ~umask. Returns a failure result (Ansible raises out
    # of enforce_state with "Failed to write to file '<path>'.") or nil.
    private def rewrite(path : String, found_line : Int32?, replace_or_add : Bool, state : String, key : String?) : PluginResult?
      existed = File.exists?(path)
      content = existed ? File.read(path) : ""
      new_content = planned_lines(content, found_line, replace_or_add, state, key).join

      tmp = "#{path}.krikri-tmp-#{Random::Secure.hex(6)}"
      begin
        File.write(tmp, new_content)
        copy_or_init_attributes(tmp, path) if existed
        File.chmod(tmp, 0o666 & ~creation_umask) unless existed
        File.rename(tmp, path)
      rescue
        cleanup_tmp(tmp)
        return PluginResult.new(changed: false, failed: true, msg: "Failed to write to file '#{path}'.")
      end
      nil
    end

    private def copy_or_init_attributes(tmp : String, path : String) : Nil
      stat = File.info(path)
      File.chmod(tmp, stat.permissions)
      begin
        File.chown(tmp, stat.owner_id.to_s.to_i, stat.group_id.to_s.to_i)
      rescue File::AccessDeniedError
        # real tolerates EPERM on the attr copy (root-only operation)
      end
    end

    private def cleanup_tmp(tmp : String) : Nil
      File.delete(tmp)
    rescue File::NotFoundError
      nil
    end

    private def shell_quote(str : String) : String
      "'" + str.gsub("'", "'\\''") + "'"
    end
  end
end

input = STDIN.gets_to_end
config = JSON.parse(input)
plugin = Krikri::KnownHostsPlugin.new(config)
plugin.run
