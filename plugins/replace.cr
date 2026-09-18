#!/usr/bin/env crystal

require "json"
require "system/user"
require "system/group"
require "../src/krikri/base_plugin"

module Krikri
  # Replace Plugin - Replace each regex match in a file with a replacement
  # string, matching ansible.builtin.replace semantics.
  #
  # Parameters:
  #   path (required): File to operate on
  #   regexp (required): Regex pattern to match (re.MULTILINE semantics)
  #   replace (optional): Replacement string (default: empty, i.e. delete
  #     matches). `\1`, `\2` etc. are backreferences to capture groups.
  #   after (optional): Only the portion AFTER the first match of this
  #     regex is subject to the regexp substitution (re.DOTALL semantics)
  #   before (optional): Mirror of `after` - substitution confined to the
  #     portion BEFORE the first match (re.DOTALL). With both, the
  #     substitution runs on the region between them.
  #   backup (optional, default no): timestamped backup of the original
  #     before any write, reported as `backup_file` in the result
  #   validate (optional): shell command template containing %s run
  #     against a staged temp copy; non-zero exit fails the task without
  #     touching the real file
  #   encoding (optional, default utf-8): encoding used to read/write
  #   owner/group/mode (optional): attribute changes to apply after the
  #     write (real replace.py's add_file_common_args=True)
  #   check_mode (optional): Dry-run mode
  #
  # Only rewrites the file when the substitution actually changes its
  # contents (idempotent), matching real Ansible: a "changed" result means
  # the file was modified, and re-running with no remaining matches reports
  # changed: false. Real Ansible fails if the file doesn't exist.
  class ReplacePlugin < BasePlugin
    property? check_mode : Bool

    def initialize(config : JSON::Any)
      super(config)
      @check_mode = true?(@params["_ansible_check_mode"]?)
    end

    def execute : PluginResult
      # Real ansible's replace module rejects ANY parameter outside its
      # own argument_spec at module-arg validation, before any action
      # runs - notably `ignorecase:`, which belongs to lineinfile, not
      # replace, so a role that copies lineinfile's params onto a
      # replace task fails loudly under real Ansible while this engine
      # silently ignored the unknown key and ran anyway. Found via the
      # podman-diff replace_edge_cases R9 harness case; message live-
      # verified against the real module's own output for this exact
      # task. check_mode/diff_mode/_verbosity/_environment are engine-
      # internal keys injected by the executor (see build_plugin_config),
      # not part of the real argument_spec, so none are rejected. The
      # parenthesized alias list mirrors real Ansible's msg (attr, dest,
      # destfile, name).
      replace_supported = {"after", "attributes", "backup", "before", "encoding", "group", "mode", "owner", "path", "regexp", "replace", "selevel", "serole", "setype", "seuser", "unsafe_writes", "validate", "attr", "dest", "destfile", "name"}
      replace_internal = {"_ansible_check_mode", "_ansible_diff", "_module_name", "_verbosity", "_environment"}
      unsupported = @params.keys.reject { |k| replace_supported.includes?(k) || replace_internal.includes?(k) }
      unless unsupported.empty?
        return PluginResult.new(
          changed: false,
          failed: true,
          msg: "Unsupported parameters for (ansible.builtin.replace) module: #{unsupported.sort.join(", ")}. " \
               "Supported parameters include: after, attributes, backup, before, encoding, group, mode, owner, " \
               "path, regexp, replace, selevel, serole, setype, seuser, unsafe_writes, validate " \
               "(attr, dest, destfile, name)."
        )
      end

      # path (aliases: dest, name) - matches real Ansible's own
      # argument_spec, where `dest:` is the long-standing legacy alias
      # most existing playbooks/roles still write (lineinfile.cr already
      # supports the same three spellings). Found via konstruktoid-
      # hardening's own "Set default bash.bashrc umask" task, which uses
      # `dest:` - "Missing required parameter: path" even though the
      # task supplied a perfectly valid (if not the newest-spelling)
      # target file parameter.
      path = @params["path"]? || @params["dest"]? || @params["name"]?
      unless path
        return PluginResult.new(
          changed: false,
          failed: true,
          msg: "Missing required parameter: path"
        )
      end
      path = expand_tilde(path)

      pattern = @params["regexp"]?
      unless pattern
        return PluginResult.new(
          changed: false,
          failed: true,
          msg: "Missing required parameter: regexp"
        )
      end

      # Real Ansible's replace fails on a directory (rc=256) before the
      # existence check (rc=257) - replace.py's own main() ordering.
      if Dir.exists?(path)
        return PluginResult.new(
          changed: false,
          failed: true,
          msg: "Path #{path} is a directory !"
        )
      end

      # Real Ansible's replace fails if the file doesn't exist (no `creates`
      # tolerance), and that failure isn't recoverable without the file
      # appearing - so it raises rather than silently no-op'ing.
      unless File.exists?(path)
        return PluginResult.new(
          changed: false,
          failed: true,
          msg: "Path #{path} does not exist"
        )
      end

      encoding = @params["encoding"]?.presence || "utf-8"

      begin
        content = File.open(path, "r", encoding: encoding) { |f| f.gets_to_end }
      rescue ex
        return PluginResult.new(
          changed: false,
          failed: true,
          msg: "Failed to read #{path}: #{ex.message}"
        )
      end

      replace = @params["replace"]? || ""

      # Real Ansible compiles the regexp with re.MULTILINE (replace.py), so
      # ^ and $ anchor at every line boundary, not just the start/end of the
      # whole file - e.g. inmotionhosting.apache's "Listen 443$" against
      # /etc/apache2/ports.conf, whose Listen lines sit indented inside
      # <IfModule> blocks and are not the last line of the file.
      # MULTILINE_ONLY, not MULTILINE: Crystal's MULTILINE constant implies
      # DOTALL (regex.cr maps it to PCRE MULTILINE | DOTALL), which would
      # let "." cross newlines and eat trailing content on replacement.
      regex = begin
        Regex.new(pattern, Regex::CompileOptions::MULTILINE_ONLY)
      rescue ex
        return PluginResult.new(
          changed: false,
          failed: true,
          msg: "Invalid regular expression: #{ex.message}"
        )
      end

      # before/after sectioning - replace.py builds a DOTALL wrapper regex
      # around a (?P<subsection>...) capture and runs the substitution on
      # the captured region only. Python's greedy `.*` under re.search
      # matches everything up to the LAST occurrence of `before`, and the
      # non-greedy `.*?` between both anchors stops at the FIRST `before`
      # after the first `after` - PCRE's quantifier semantics are
      # identical, so the same patterns are used verbatim here (DOTALL,
      # not MULTILINE_ONLY: `.` must cross newlines in these wrappers,
      # exactly as replace.py's re.DOTALL does).
      after_pattern = @params["after"]?.presence
      before_pattern = @params["before"]?.presence

      section = content
      section_start = 0
      section_end = content.bytesize

      if after_pattern || before_pattern
        section_pattern = if after_pattern && before_pattern
                            "#{after_pattern}(?<subsection>.*?)#{before_pattern}"
                          elsif after_pattern
                            "#{after_pattern}(?<subsection>.*)"
                          else
                            "(?<subsection>.*)#{before_pattern}"
                          end

        section_regex = begin
          Regex.new(section_pattern, Regex::CompileOptions::DOTALL)
        rescue ex
          return PluginResult.new(
            changed: false,
            failed: true,
            msg: "Invalid regular expression: #{ex.message}"
          )
        end

        match = section_regex.match(content)
        unless match
          return PluginResult.new(
            changed: false,
            failed: false,
            msg: "Pattern for before/after params did not match the given file: #{section_pattern}"
          )
        end

        section_start = match.begin(1).not_nil!
        section_end = match.end(1).not_nil!
        section = content.byte_slice(section_start, section_end - section_start)
      end

      new_section = section.gsub(regex, replace)
      changed = new_section != section

      if @check_mode
        msg = if changed
                "Would replace matches in #{path}"
              else
                "No matches to replace in #{path}"
              end
        result = PluginResult.new(
          changed: changed,
          failed: false,
          msg: msg,
          path: path
        )
        add_path_info(result, path)
        return result
      end

      backup_file = ""
      if changed
        # Real Ansible's backup_local runs before write_changes, so the
        # backup always holds the PRE-substitution content.
        if true?(@params["backup"]?)
          backup_file = write_backup(path)
        end

        if failure = write_with_optional_validate(path, new_section, section_start, section_end, content, encoding)
          return failure
        end
      end

      # Apply any requested attribute changes (owner/group/mode), matching
      # real Ansible which also sets them even on a no-matches run.
      attr_changed = apply_attributes(path)

      new_content = content.byte_slice(0, section_start) + new_section +
                    content.byte_slice(section_end, content.bytesize - section_end)
      msg = if changed || attr_changed
              "Replaced matches in #{path}"
            else
              "No matches to replace in #{path}"
            end
      result = PluginResult.new(
        changed: changed || attr_changed,
        failed: false,
        msg: msg,
        path: path,
        backup_file: backup_file
      )
      add_path_info(result, path)
      result
    end

    # Applies mode if given; returns whether it changed. owner/group would
    # require resolving a name to uid/gid (getpwnam), which is only
    # meaningful for the local user of a local connection - the role's
    # replace tasks (os_hardening's yum gpgcheck) only request mode.
    private def apply_attributes(path : String) : Bool
      before = File.info?(path, follow_symlinks: false)

      mode = @params["mode"]?
      if mode
        begin
          # copy.cr's own mode convention: any all-digit string parses as
          # octal (leading zero or not); a symbolic mode (u+x) shells to a
          # real `chmod`.
          if mode =~ /\A0?[0-7]{3,4}\z/
            File.chmod(path, mode.to_i(8))
          else
            Process.run("chmod", [mode, path], output: Process::Redirect::Close, error: Process::Redirect::Close)
          end
        rescue File::Error
          # Mode setting failed, continue anyway
        end
      end

      uid = -1
      gid = -1

      if (owner = @params["owner"]?) && (user = System::User.find_by?(name: owner))
        uid = user.id.to_i
      end

      if (group = @params["group"]?) && (grp = System::Group.find_by?(name: group))
        gid = grp.id.to_i
      end

      File.chown(path, uid: uid, gid: gid) if uid != -1 || gid != -1

      after = File.info?(path, follow_symlinks: false)
      return false unless before && after
      before.permissions != after.permissions ||
        before.owner_id != after.owner_id ||
        before.group_id != after.group_id
    rescue File::Error
      # A chown/chmod failure (e.g. not running as root/owner) shouldn't
      # fail the whole task - matches copy.cr's own identical rescue.
      false
    end

    # Backup of the original file before any write - lineinfile.cr's own
    # write_backup convention (same timestamped name shape), so every
    # file-editing module in this codebase reports backup_file the same
    # way.
    private def write_backup(path : String) : String
      timestamp = Time.utc.to_s("%Y-%m-%d@%H:%M:%S")
      backup_file = "#{path}.#{Process.pid}.#{timestamp}~"
      File.copy(path, backup_file)
      backup_file
    end

    # validate: support - mirrors lineinfile.cr/copy.cr's merged approach:
    # stage the new content in a temp file, run the validate: command
    # (with %s substituted by the staged temp path) against it, and only
    # on a zero exit move it into place. On validation failure the temp
    # file is discarded and the real file is left untouched.
    #
    # Returns nil on success, or a failed PluginResult.
    private def write_with_optional_validate(path : String, new_section : String, section_start : Int32, section_end : Int32, original_content : String, encoding : String) : PluginResult?
      validate_cmd = @params["validate"]?
      if validate_cmd && !validate_cmd.includes?("%s")
        return PluginResult.new(changed: false, failed: true, msg: "validate must contain %s: #{validate_cmd}")
      end

      new_content = original_content.byte_slice(0, section_start) + new_section +
                    original_content.byte_slice(section_end, original_content.bytesize - section_end)

      temp_file = File.join(File.dirname(path), ".krikri-playbook-replace-#{Random::Secure.hex(8)}.tmp")
      begin
        File.write(temp_file, new_content, encoding: encoding)
      rescue ex
        return PluginResult.new(changed: false, failed: true, msg: "Failed to write temporary file: #{ex.message}")
      end

      if validate_cmd
        validation = validate_file(temp_file, validate_cmd)
        unless validation[:ok]
          File.delete(temp_file) if File.exists?(temp_file)
          return PluginResult.new(changed: false, failed: true, msg: "failed to validate: rc:#{validation[:rc]} error:#{validation[:output]}")
        end
      end

      # Preserve an existing dest's mode/ownership (a rename would
      # otherwise reset them to the temp file's). Best-effort chown,
      # same as lineinfile.cr.
      if (info = File.info?(path, follow_symlinks: false))
        begin
          File.chmod(temp_file, info.permissions)
          File.chown(temp_file, uid: info.owner_id.to_i, gid: info.group_id.to_i)
        rescue File::Error
          nil
        end
      end

      begin
        File.rename(temp_file, path)
      rescue ex
        File.delete(temp_file) if File.exists?(temp_file)
        return PluginResult.new(changed: false, failed: true, msg: "Failed to move file to destination: #{ex.message}")
      end

      nil
    end

    # Runs the validate: command (with %s substituted by the staged
    # temp path) - identical to lineinfile.cr/copy.cr's own helpers.
    private def validate_file(path : String, validate_cmd : String) : NamedTuple(ok: Bool, rc: Int32, output: String)
      cmd = validate_cmd.gsub("%s", path)
      output = IO::Memory.new

      result = Process.run(
        "/bin/sh",
        ["-c", cmd],
        output: output,
        error: output
      )

      {ok: result.exit_code == 0, rc: result.exit_code, output: output.to_s.strip}
    end
  end
end

# Entry point
input = STDIN.gets_to_end
config = JSON.parse(input)
plugin = Krikri::ReplacePlugin.new(config)
plugin.run
