#!/usr/bin/env crystal

# tempfile module (ansible.builtin.tempfile) - creates a temporary file or
# directory on the target and returns its path. Always reports changed:
# true (there is no idempotency concept - a fresh, uniquely-named path is
# created on every run, matching real Ansible's own tempfile.mkstemp/
# mkdtemp-backed module).
#
# Parameters:
#   state (optional): "file" (default) or "directory"
#   path (optional): parent dir to create the tempfile/dir under (defaults
#     to the target's own tmp dir, same as Python's tempfile module default)
#   prefix (optional): filename prefix (default "ansible.")
#   suffix (optional): filename suffix (default "")

require "json"
require "../src/krikri/base_plugin"

module Krikri
  class TempfilePlugin < BasePlugin
    def execute : PluginResult
      # Real tempfile passes no supports_check_mode=True to its
      # AnsibleModule, so real Ansible's action plugin never runs the
      # module under check mode at all - the task skips with "check mode
      # not supported for this module" (podman-diff tempfile_edge_cases
      # T6). This plugin used to run the real mktemp remotely AND report
      # changed:true: a genuine side effect under check mode plus a
      # wrong skip/ok accounting.
      if true?(@params["_ansible_check_mode"]?)
        invoked = @params["_module_name"]? || "ansible.builtin.tempfile"
        return PluginResult.new(changed: false, failed: false, msg: "remote module (#{invoked}) does not support check mode", skipped: true)
      end

      state = normalized_state
      unless {"file", "directory"}.includes?(state)
        return PluginResult.new(changed: false, failed: true, msg: "value of state must be one of: file, directory, got: #{state}")
      end

      dir = target_dir
      if dir && (errno = dir_errno(dir))
        return PluginResult.new(changed: false, failed: true, msg: failure_msg(dir, errno, state))
      end

      result = remote_exec(mktemp_command(state, dir))
      unless result[:exit_code] == 0
        return PluginResult.new(changed: false, failed: true, msg: "Failed to create temporary #{state}: #{result[:stderr].strip}")
      end

      path = result[:stdout].strip
      # Real tempfile's success result runs changed, path, then the
      # add_path_info stat block, then failed (live-verified vs 2.19.11
      # via a registered result, state file and directory alike; msg: ""
      # never serializes). add_path_info re-derives state from the stat,
      # so the explicit state: only covers the not-yet-statable edge.
      res = PluginResult.new(changed: true, failed: false, msg: "", path: path, state: state, key_order: SUCCESS_KEY_ORDER)
      add_path_info(res, path)
      res
    end

    private SUCCESS_KEY_ORDER = %w[changed path uid gid owner group mode state size failed]

    private def normalized_state : String
      state = @params["state"]?
      state = "file" if state.nil? || state.empty?
      state
    end

    # AnsibleModule's own type='path' conversion is just
    # os.path.expanduser(os.path.expandvars(value)) - it neither makes the
    # path absolute nor normalizes it, so `77`, `./x` and `77/` all survive
    # as written. That verbatim string is what mkdtemp hands to
    # os.mkdir() and therefore what its failure message quotes.
    private def raw_dir : String?
      @params["path"]?.try { |pth| expand_tilde(pth) }
    end

    # Where the tempfile is actually created: a relative path resolves
    # against the module's own working directory and `.`, `..` and
    # duplicate/trailing slashes collapse, matching Python's
    # os.path.abspath (which real's mkstemp applies to `dir`, and which
    # both mkstemp and mkdtemp apply to the path they return - so the
    # absolute form is also what the mktemp template must use to get an
    # absolute path back). Only mkdtemp's failure message still shows
    # the verbatim form - see #failure_msg.
    private def target_dir : String?
      raw_dir.try { |pth| unfrackpath(pth) }
    end

    private def unfrackpath(path : String) : String
      normpath(path.starts_with?('/') ? path : "#{base_dir}/#{path}")
    end

    # The working directory a real Ansible module resolves a relative
    # path against. Under a local connection that is the playbook's own
    # directory (ansible's local connection plugin runs every module with
    # cwd = the playbook's basedir) - NOT the shell the playbook happened
    # to be launched from, which is what a bare Dir.current would use.
    # Over SSH the module runs with the remote user's home as its cwd,
    # which is exactly where the uploaded plugin binary is itself
    # running, so Dir.current is already right there.
    private def base_dir : String
      if local_connection? && (dir = @vars["playbook_dir"]?.try(&.as_s?))
        dir
      else
        Dir.current
      end
    end

    private def normpath(path : String) : String
      parts = [] of String
      path.split('/').each do |part|
        next if part.empty? || part == "."
        if part == ".."
          parts.pop unless parts.empty?
        else
          parts << part
        end
      end
      # POSIX normpath's one special case: exactly two leading slashes are
      # an implementation-defined root and survive normalization; three or
      # more collapse to one.
      prefix = path.starts_with?("//") && !path.starts_with?("///") ? "//" : "/"
      prefix + parts.join('/')
    end

    # The errno Python's os.open() - behind tempfile.mkstemp/mkdtemp -
    # would report for this directory, or nil when the directory is
    # usable. Not the shared remote_dir_exists?/remote_file_exists?
    # helpers: Crystal's own Dir.exists? raises (rather than returning
    # false) when the path is hidden behind an unreadable ancestor, which
    # escaped as a generic "Plugin execution failed", and only the
    # local/SSH split can answer for the right filesystem. A shell
    # `test -d`/`test -f` pair over SSH cannot tell a missing directory
    # from one behind an unreadable ancestor, and falls back to the far
    # commoner ENOENT.
    private def dir_errno(dir : String) : Errno?
      if local_connection?
        begin
          return nil if Dir.exists?(dir)
          return Errno::ENOTDIR if File.exists?(dir)
          return Errno::ENOENT
        rescue ex : File::Error
          os_error = ex.os_error
          return os_error.is_a?(Errno) ? os_error.as(Errno) : Errno::ENOENT
        end
      end

      return nil if remote_exec("test -d #{shell_single_quote(dir)}")[:exit_code] == 0
      return Errno::ENOTDIR if remote_exec("test -f #{shell_single_quote(dir)}")[:exit_code] == 0
      Errno::ENOENT
    end

    # Real's failure text is str(OSError) from the failed open/mkdir, i.e.
    # "[Errno 2] No such file or directory: '<path>/<prefix><8 random
    # chars><suffix>'" - and the two states legitimately quote DIFFERENT
    # directory forms. Python's tempfile does
    #   mkstemp (state: file):      dir = _os.path.abspath(dir)  <- first
    #   mkdtemp (state: directory): file = _os.path.join(dir, name)
    # so only mkstemp resolves and normalizes `path` up front; mkdtemp
    # joins the user's own string and its OSError names that string as
    # written. The 8 characters are mkstemp's own random name (lowercase
    # letters, digits and underscore, exactly Python's
    # tempfile._RandomNameSequence), which is why this reproduces the
    # shape and not the same bytes real would have picked.
    private def failure_msg(dir : String, errno : Errno, state : String) : String
      name = "#{name_prefix}#{random_name}#{name_suffix}"
      quoted = state == "directory" ? os_path_join(raw_dir || dir, name) : "#{dir}/#{name}"
      "[Errno #{errno.value}] #{errno.message}: '#{quoted}'"
    end

    # os.path.join's two-argument form: a directory already ending in a
    # separator absorbs the extra one, and an empty directory is ignored
    # entirely (`os.path.join('', name)` is just `name`).
    private def os_path_join(dir : String, name : String) : String
      return name if dir.empty?
      dir.ends_with?('/') ? "#{dir}#{name}" : "#{dir}/#{name}"
    end

    private def name_prefix : String
      prefix = @params["prefix"]?
      prefix = "ansible." if prefix.nil? || prefix.empty?
      prefix
    end

    private def name_suffix : String
      @params["suffix"]? || ""
    end

    private def random_name : String
      alphabet = "abcdefghijklmnopqrstuvwxyz0123456789_"
      String.build do |io|
        8.times { io << alphabet[Random::Secure.rand(alphabet.size).to_i] }
      end
    end

    private def mktemp_command(state : String, dir : String?) : String
      template = "#{name_prefix}XXXXXX#{name_suffix}"
      full_template = dir ? "#{dir.chomp('/')}/#{template}" : template
      mktemp_flag = state == "directory" ? "-d " : ""

      dir ? "mktemp #{mktemp_flag}#{shell_quote(full_template)}" : "mktemp #{mktemp_flag}--tmpdir #{shell_quote(template)}"
    end

    private def shell_quote(str : String) : String
      "'" + str.gsub("'", "'\\''") + "'"
    end
  end
end

input = STDIN.gets_to_end
config = JSON.parse(input)
plugin = Krikri::TempfilePlugin.new(config)
plugin.run
