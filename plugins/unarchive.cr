#!/usr/bin/env crystal

require "json"
require "http/client"
require "uri"
require "../src/krikri/base_plugin"
require "../src/krikri/plugin_helpers/http_download"
require "../src/krikri/plugin_helpers/multiext_split"

module Krikri
  # Unarchive plugin - extracts an archive into a directory. Compatible
  # with Ansible's ansible.builtin.unarchive module (verified via
  # `ansible-doc unarchive` - unlike `community.general.archive`, this one
  # does ship with ansible-core, so it's registered under
  # ansible.builtin.* like most other plugins here).
  #
  # Supported parameters:
  # - src: path to the archive (required) - a local (already-on-target)
  #   path in the common case, matching how krikri-playbook's copy:
  #   plugin already handles local-vs-remote; a plain `remote_src` param
  #   is accepted for compatibility but otherwise has no effect. If src:
  #   contains "://" (a URL), it's fetched first regardless of
  #   remote_src:'s own value - Ansible's own documented behavior
  # - dest: existing directory to extract into (required - krikri-playbook
  #   fails if it doesn't already exist, same as Ansible: this module
  #   never creates dest itself)
  # - creates: skip extraction if this path already exists (checked
  #   before doing anything else, same idempotency shortcut command:/
  #   shell: already support)
  # - exclude / include: comma-separated member paths/globs, passed
  #   straight through to tar's --exclude / zip's -x and file-list
  #   arguments - real tar/zip's own matching semantics apply (a pattern
  #   with no "/" matches by path component, one with "/" matches the
  #   literal relative path - verified against ansible-playbook,
  #   which itself just forwards these to the same underlying tools)
  # - keep_newer: don't overwrite an existing file that's newer than the
  #   archive's copy (default false)
  # - list_files: include the archive's member list in the result
  #   (default false)
  # - mode / owner / group: applied RECURSIVELY to every extracted path
  #   under dest (`chown -R`/`chgrp -R`/`chmod -R` reaching everything
  #   dest CONTAINS) - matches ansible-playbook's actual behavior
  #   (verified against unarchive.py's own post-extraction
  #   `set_fs_attributes_if_different` walk over files_in_archive plus
  #   the top-level archive folders, ansible#35426), even though its
  #   OWN return value shape (`mode`/`owner`/`group`/`uid`/`gid`) only
  #   ever describes dest itself, not each member. dest ITSELF is
  #   never touched: Ansible requires it to already exist and
  #   leaves its attributes alone.
  #
  # Archive contents are attacker-controlled whenever src: is (a
  # remote_src archive, a downloaded URL, a release artifact from a
  # compromised build), so every path derived from a member name is
  # containment-checked against dest (see contained_member_path) and
  # never dereferenced through a symlink member:
  # - chown/chgrp run with -h (Ansible's set_owner_if_different /
  #   set_group_if_different always use os.lchown, never following a
  #   link), so an archive can't redirect an owner:/group: change onto
  #   an arbitrary file outside dest via a symlink member;
  # - chmod never runs against a symlink member (Ansible's
  #   set_mode_if_different chmods through the link and then RESTORES
  #   the underlying mode; net effect on the target is unchanged, so
  #   never touching it at all reaches the same end state without the
  #   transient write);
  # - members whose normalized path lands outside dest (or on dest
  #   itself with stripping active) are dropped from BOTH the
  #   attribute pass and the zip idempotency comparison - GNU tar
  #   refuses `..` members at extraction anyway and Info-ZIP unzip
  #   strips them (with a warning, and exit code 1 that Ansible
  #   fails the task on - which is why extract_zip doesn't use -q:
  #   `-q` suppresses that very warning and unzip then exits 0,
  #   letting a hostile zip "succeed" into the attribute pass), but
  #   the member LISTING still carries the raw names.
  #
  # Archive type is auto-detected by attempting to read it (`tar tf`, then
  # `unzip -l`), not by file extension - matches Ansible's own
  # handler-probing approach (`can_handle_archive`), and means GNU tar's
  # own compression auto-detection handles gz/bz2/xz/plain tar uniformly
  # without needing a --format: parameter the way community.general's
  # `archive` plugin does.
  #
  # Idempotency for tar-based archives uses `tar --compare` against dest,
  # the same mechanism Ansible's TgzArchive#is_unarchived uses. For
  # zip, a simpler per-member checksum comparison is used instead of
  # replicating Ansible's much more involved zipinfo/permission-based
  # check - an approximation, documented as such.
  #
  # - extra_opts: raw flags passed straight through to `tar` (e.g.
  #   `--strip-components=1`) - NOT forwarded to `unzip` for zip archives
  #   (Ansible's own extra_opts only ever documents tar-oriented
  #   flags in practice; zip's own flag syntax is different enough that
  #   passing the same list through would usually just error).
  #
  # remote_src (default false, Ansible's own default too) - a
  # controller-side src: path is transparently SCP'd to a remote scratch
  # path before this plugin ever runs (see TaskExecutor#stage_unarchive_
  # remote_src, the same mechanism copy: uses); this plugin itself always
  # just reads src: from wherever it's actually executing, same as
  # Ansible's module does once the action-plugin layer has already
  # staged the file.
  #
  # Accepted without effect (all read via the same unknown-key-tolerant
  # @params Hash every plugin already uses, so a real playbook passing
  # any of these no longer needs param-rejection tolerance from this
  # engine):
  # - `copy` - unarchive's OLDER, mutually-exclusive-with-remote_src:
  #   param spelling (confirmed via `ansible-doc unarchive`): `copy:
  #   true` (the default) means the same as `remote_src: false` (src:
  #   is a controller path, copied to the target first); `copy: false`
  #   means the same as `remote_src: true` (src: is already on the
  #   target). Read straight through by executor_task_exec.cr's
  #   `stage_unarchive_remote_src` for that controller-vs-target
  #   staging decision (round 812047, CVi.thanos - `copy: no` treated
  #   as remote_src: false there failed a task Ansible succeeds);
  #   this plugin itself never reads it, since staging already resolved
  #   src: to wherever it actually needs to be read from by the time
  #   this process runs.
  # - `io_buffer_size` - sizes a manual byte-copy loop Ansible's own
  #   module uses for zip extraction; this plugin shells out to
  #   `tar`/`unzip` entirely, so there's no Crystal-side read loop for
  #   this to size
  # - `validate_certs` - only relevant to Ansible's shared
  #   controller-side URL-fetch code path; the shared HTTPDownload helper
  #   used here always validates certs (no insecure-fetch option exists here)
  # - `decrypt` (vault auto-decryption - `src` isn't read through
  #   `Vault.maybe_decrypt` here), SELinux options, `unsafe_writes`,
  #   `attributes`.
  #
  # include:/exclude: are mutually exclusive (Ansible's own
  # argument-spec validation) - giving both fails immediately.
  class UnarchivePlugin < BasePlugin
    # ansible.builtin.unarchive's `type: bool` options, in the real
    # argument-spec declaration order (ansible-doc -j
    # ansible.builtin.unarchive). Validated at module setup by
    # BasePlugin#validate_bool_params! - see its block comment for the
    # real-Ansible semantics and message wording.
    protected def bool_params : Array(String)
      %w[copy decrypt keep_newer list_files remote_src unsafe_writes validate_certs]
    end

    MAX_REDIRECTS = 10

    def execute : PluginResult
      src_param = @params["src"]?
      dest_param = @params["dest"]?
      unless src_param && dest_param
        return PluginResult.new(changed: false, failed: true, msg: "missing required argument: src and dest are both required")
      end
      dest = expand_tilde(dest_param)

      if @params["include"]? && @params["exclude"]?
        return PluginResult.new(changed: false, failed: true, msg: "parameters are mutually exclusive: include|exclude")
      end

      if result = creates_skip_result
        return result
      end
      # Real bug found benchmarking geerlingguy.node_exporter's own
      # "Download and unarchive node_exporter into temporary location."
      # task: `src: "{{ node_exporter_download_url }}"` (a real HTTPS
      # URL) with `remote_src: true`. Ansible's own unarchive
      # module explicitly documents this combination - "If remote_src
      # is yes and src contains ://, the remote machine will download
      # the file from the url first" - previously entirely
      # unimplemented here (the class doc above's own claim that
      # remote_src "has no effect" was simply wrong for this case):
      # `src` went straight to `remote_file_exists?`, which checks for
      # a local FILE PATH on the target, always false for a URL,
      # failing every such task outright with "Source ... failed to
      # transfer" even though the URL itself was perfectly reachable.
      resolved = resolve_src(src_param)
      return resolved if resolved.is_a?(PluginResult)
      src, tmp_download_path = resolved

      if validation = validate_src_and_dest(src, dest)
        action_level, error = validation
        if action_level
          # real: AnsibleActionFail in the controller-side action plugin - a bare
          # "Task failed: <msg>" block with no "Module failed." segment
          return PluginResult.new(changed: false, failed: true, msg: error, _ansible_action_level: true,
            # Ansible's unarchive action-failure order (unarchive.cr's plugin
            # binary does not link base_action_plugin.cr, so the shared
            # Krikri::FAILED_KEY_ORDER_EXCEPTION_FIRST list is spelled out).
            key_order: ["failed", "exception", "msg", "changed"])
        end
        # The source failure is the module's own failure - a plain module-level
        # result, which the executor's retry loop treats like any other
        # module failure (Ansible retries it too).
        return PluginResult.new(changed: false, failed: true, msg: error)
      end

      # AnsibleModule validates bool-typed params at module setup -
      # but live-verified against ansible-core 2.19.11, unarchive's own
      # dest-existence check ("dest '...' must be an existing dir") and
      # the controller's src lookup both still fire BEFORE it, and an
      # existing creates: path does NOT save an invalid `remote_src:
      # blah` from failing. This engine therefore validates after
      # resolve_src/validate_src_and_dest (mirroring the src/dest gates)
      # but before the creates: short-circuit below - which now sits
      # after validation exactly like Ansible's module main() does.
      validate_bool_params!

      begin
        res = run(src, dest)
        if warning = relative_dest_warning(dest)
          attach_warning(res, warning)
        end
        res
      ensure
        cleanup_after_unarchive(tmp_download_path, src)
      end
    end

    # Ansible's unarchive module main() itself warns on every result the
    # MODULE produces (success, changed, or a failure like the
    # no-handler-found one) when dest is relative - but the module only
    # runs after the action-plugin gates, so a gated failure (src lookup
    # miss, dest not an existing dir) never carries the warning, and the
    # creates:-skip and bool-validation failures don't either (they
    # short-circuit before main()'s warning site).
    private def relative_dest_warning(dest : String) : String?
      return nil if dest.starts_with?("/")
      "Relative destination path '#{dest}' was resolved to absolute path '#{File.expand_path(dest)}'."
    end

    private def attach_warning(res : PluginResult, warning : String) : PluginResult
      res.extra["warnings"] = JSON.parse([warning].to_json)
      res
    end

    private def creates_skip_result : PluginResult?
      creates = @params["creates"]? || return nil
      expanded_creates = expand_tilde(creates)
      return nil unless remote_file_exists?(expanded_creates) || remote_dir_exists?(expanded_creates)

      # skipped: true - finish_single_task turns this into
      # ansible's "skipping: [host]" display + skipped= accounting.
      # Without it the skip displayed as `ok:` with the message as
      # body and counted ok=1, off-by-one vs Ansible's recap on
      # every creates:-guarded unarchive (cloudalchemy.node_exporter /
      # mysqld_exporter, round 195 re-verification: crystal ok=14/17
      # skipped=2/15 where Ansible ok=13/16 skipped=3/16 - same
      # skip, different counter).
      PluginResult.new(changed: false, failed: false, msg: "Skipped: #{creates} already exists", skipped: true)
    end

    # Returns {src, tmp_download_path} on success, or a failed
    # PluginResult when a URL src: failed to download.
    private def resolve_src(src : String) : PluginResult | {String, String?}
      return {src, nil} unless src.starts_with?("http://") || src.starts_with?("https://")

      # Ansible's unarchive downloads URL srcs into its own module
      # tmpdir and echoes that staged path back as `src` - including
      # inside 'Failed to find handler for "<src>"' - so stage in the
      # same shape (see copy.cr's staged_src_echo for the tmpdir
      # shape; remote_tmp defaults to ~/.ansible/tmp of the user this
      # plugin process runs as). The file itself is still pre-created
      # O_EXCL + 0600 rather than written through a bare open: a
      # symlink planted at the download path would otherwise be
      # followed, so a planted path fails loudly instead of being
      # written through.
      tmpdir = expand_tilde("~/.ansible/tmp/ansible-tmp-#{sprintf("%.7f", Time.local.to_unix_f)}-#{Process.pid}-#{Random.rand(100_000_000_000_000..999_999_999_999_999)}")
      Dir.mkdir_p(tmpdir, mode: 0o700)

      # fetch_file (ansible/module_utils/urls.py) names the staged
      # tempfile after the URL basename's last two suffix components
      # (_split_multiext, count=2), NOT os.path.splitext - the splitext
      # form would keep ".tar" in the prefix and read
      # ...tar<rand8>.gz, and since this staged path comes back as
      # `src` in unarchive's output (see the block comment above),
      # getting it wrong is visible to the byte-comparison rounds.
      basename = File.basename(URI.parse(src).path || src)
      stem, ext = UnarchivePlugin.split_multiext(basename)

      tmp_download_path = create_staged_download(tmpdir, stem, ext)
      unless tmp_download_path
        Dir.delete(tmpdir) rescue nil
        return PluginResult.new(changed: false, failed: true, msg: "Source '#{src}' failed to transfer: unable to create a temporary file")
      end

      begin
        PluginHelpers::HTTPDownload.download(src, tmp_download_path, download_options)
      rescue ex
        File.delete(tmp_download_path) rescue nil
        Dir.delete(tmpdir) rescue nil
        return PluginResult.new(changed: false, failed: true, msg: "Failure downloading #{src}, #{download_failure_detail(ex)}")
      end
      {tmp_download_path, tmp_download_path}
    end

    private def download_options : PluginHelpers::HTTPDownload::Options
      PluginHelpers::HTTPDownload::Options.new(
        max_redirects: MAX_REDIRECTS,
        connect_timeout: 15.seconds,
        read_timeout: 30.seconds,
        headers: HTTP::Headers{"User-Agent" => "ansible-httpget"},
      )
    end

    # fetch_file (unarchive.py) interpolates fetch_url's info['msg']
    # verbatim into "Failure downloading <url>, <msg>" - a UrlError,
    # ConnectionFailure or HttpError carries exactly that text. A
    # ContentCopy failure happens after fetch_url already returned, so
    # there's no info['msg'] to use; the exception's own message is the
    # closest honest detail available.
    private def download_failure_detail(ex : Exception) : String
      if ex.is_a?(PluginHelpers::HTTPDownload::FetchError)
        case ex.kind
        when .url_error?, .connection_failure?, .http_error?
          return ex.info_msg
        end
      end
      ex.message || ex.class.name
    end

    # fetch_file's _split_multiext(name, min=3, max=4, count=2), kept as
    # a public class method so the algorithm is reachable from a unit
    # test; the implementation lives in PluginHelpers::MultiextSplit
    # (own file - a spec can't require this one without hitting its
    # STDIN entry point).
    def self.split_multiext(name : String) : {String, String}
      PluginHelpers::MultiextSplit.split(name)
    end

    # Python tempfile.mkstemp naming (stem prefix, ext suffix, 8 random
    # lowercase-alnum chars) pre-created O_EXCL/0600 inside tmpdir -
    # mkstemp retries on an existing name, so the loop does too. Raw
    # LibC.open because Crystal's File.open mode strings have no
    # exclusive-creation form (the stdlib's own mktemp opens the same
    # way).
    private def create_staged_download(tmpdir : String, stem : String, ext : String) : String?
      10.times do
        suffix = String.build(8) do |builder|
          8.times { builder << "abcdefghijklmnopqrstuvwxyz0123456789"[Random.rand(36)] }
        end
        candidate = File.join(tmpdir, "#{stem}#{suffix}#{ext}")
        fd = LibC.open(candidate, LibC::O_WRONLY | LibC::O_CREAT | LibC::O_EXCL, 0o600)
        next if fd == -1 # typically EEXIST - retry on a fresh name
        LibC.close(fd)
        return candidate
      end
      nil
    end

    # Ansible's unarchive action plugin checks dest BEFORE anything touches
    # src (unarchive.py: _execute_remote_stat(dest) runs before the file
    # transfer and before the module's own source check ever gets a chance),
    # so a missing dest with a missing src reports the DEST error, not the
    # source error (issue #131). The Bool marks which check fired: the dest
    # failure is the action plugin's own AnsibleActionFail, while the source
    # failure is the module's own ordinary failure - which Ansible's executor
    # DOES retry (live-verified vs 2.19.11).
    private def validate_src_and_dest(src : String, dest : String) : {Bool, String}?
      return {true, "dest '#{dest}' must be an existing dir"} unless remote_dir_exists?(dest)
      return {false, "Source '#{src}' failed to transfer"} unless remote_file_exists?(src)
      nil
    end

    private def cleanup_after_unarchive(tmp_download_path : String?, src : String) : Nil
      if tmp_download_path
        File.delete(tmp_download_path) if File.exists?(tmp_download_path)
        # resolve_src staged the URL download inside the ansible-tmp
        # module dir it created; drop that dir too once the file is
        # gone (rmdir only succeeds when empty, so best-effort is safe).
        tmpdir = File.dirname(tmp_download_path)
        if File.basename(tmpdir).starts_with?("ansible-tmp-")
          begin
            Dir.delete(tmpdir)
          rescue
            nil
          end
        end
      end
      # __cleanup_after_unarchive - set by TaskExecutor#stage_unarchive_
      # remote_src when src: named a controller-side path (unarchive's
      # own Ansible default, remote_src: false) that had to be
      # SCP'd to a remote scratch path first, same reasoning as copy:'s
      # own __cleanup_after_copy. Best-effort.
      if @params["__cleanup_after_unarchive"]? == "true"
        File.delete(src) rescue nil
      end
    end

    private def detect_handler(src : String) : Symbol?
      return :tar if remote_exec("tar tf #{shell_single_quote(src)} > /dev/null 2>&1")[:exit_code] == 0
      return :zip if remote_exec("unzip -l #{shell_single_quote(src)} > /dev/null 2>&1")[:exit_code] == 0
      nil
    end

    # pick_handler (unarchive.py) tries the handlers in the fixed order
    # [ZipArchive, ZipZArchive, TgzArchive, TarArchive, TarBzip, TarXz,
    # TarZstd] and collects one reason per failed handler, de-duplicated
    # (live-verified against 2.19.11's unarchive.py ~782-800/951-974/
    # 1022-1033). Two reason shapes:
    # - a handler whose binaries are missing entirely reports
    #   "Unable to find required '<a>' or '<b>' binary in the path."
    #   with ONLY the actually-missing names joined by "' or '" - the
    #   tar-family handlers' fixed spelling carries no trailing period;
    # - a handler whose binaries exist but whose listing probe fails
    #   reports 'Command "<binary path>" could not handle archive:
    #   <stderr>' (unzip -l for the zip handlers; for the tar family
    #   each handler's own `tar --list <flag>` probe, prefixed with
    #   'Unable to list files in the archive: '). Identical reasons
    #   dedup, as in real.
    private def handler_failure_reasons(src : String) : Array(String)
      found = {} of String => String?
      %w[unzip zipinfo gtar tar].each do |name|
        out = remote_exec("command -v #{shell_single_quote(name)} 2> /dev/null")
        path = out[:stdout].strip
        found[name] = out[:exit_code] == 0 && !path.empty? ? path : nil
      end

      reasons = [] of String

      unzip = found["unzip"]?
      # ZipArchive needs unzip AND zipinfo; ZipZArchive needs unzip
      # twice (its own message spells the duplicate out), so when unzip
      # exists both handlers probe the same `unzip -l` and their
      # could-not-handle reasons are identical - ZipZ's copy dedups.
      zip_missing = %w[unzip zipinfo].select { |name| found[name].nil? }
      if unzip && (zip_reason = could_not_handle_reason("unzip -l", unzip, src))
        reasons << zip_reason
      end

      # The tar family: gtar preferred, plain tar as the fallback binary
      # (Ansible's TgzArchive/TarArchive cmd/zipinfo pair). gtar does not
      # exist on most distros, so a missing-binary report only fires when
      # BOTH are gone.
      tar_path = found["gtar"]? || found["tar"]?
      if tar_path
        # Each tar-family handler lists with its own flag (TgzArchive -z,
        # TarArchive none, TarBzip -j, TarXz -J, TarZstd the zstd
        # program), so each reports its own tool's stderr behind
        # 'Unable to list files in the archive: '. The raw stderr keeps
        # its trailing newline (real does not strip it).
        ["-z", "", "-j", "-J", "--use-compress-program=zstd"].each do |flag|
          out = remote_exec("#{shell_single_quote(tar_path)} --list #{flag} -f #{shell_single_quote(src)}")
          next if out[:exit_code] == 0
          reasons << %(Command "#{tar_path}" could not handle archive: Unable to list files in the archive: #{out[:stderr]})
        end
      else
        reasons << "Unable to find required 'gtar' or 'tar' binary in the path"
      end

      # Real collects these reasons into a Python set, so the order of the
      # missing-binary lines shuffles run to run (issue #112: three runs
      # on 2.19.11 gave three different orders); any fixed order is as
      # good as another.
      unless unzip
        reasons << "Unable to find required 'unzip' or 'unzip' binary in the path."
      end

      unless zip_missing.empty?
        reasons << "Unable to find required '#{zip_missing.join("' or '")}' binary in the path."
      end

      reasons.uniq
    end

    # A controller-side src: is copied by Ansible's unarchive action into
    # the module tmpdir under the fixed name `source` (issue #112) and the
    # module reports that staged path, not the original. The executor marks such srcs with
    # __original_src_basename.
    private def staged_src_echo(src : String) : String
      @params["__original_src_basename"]? || return src
      expand_tilde("~/.ansible/tmp/ansible-tmp-#{sprintf("%.7f", Time.local.to_unix_f)}-#{Process.pid}-#{Random.rand(100_000_000_000_000..999_999_999_999_999)}/source")
    end

    private def could_not_handle_reason(command : String, binary_path : String, src : String) : String?
      out = remote_exec("#{command} #{shell_single_quote(src)}")
      return nil if out[:exit_code] == 0
      %(Command "#{binary_path}" could not handle archive: #{out[:stderr]})
    end

    # A list-typed param arrives in one of two shapes depending on how
    # the task wrote it: a LITERAL YAML list (`extra_opts:
    # ['--strip-components=1']`) is comma-joined by playbook_parser.cr's
    # own #stringify_value at parse time (the convention every plugin's
    # list params already expected) - but a `{{ }}`-TEMPLATED expression
    # that resolves to an array at runtime (`extra_opts: "{{
    # _common_binary_unarchive_opts | default(omit, true) }}"`,
    # prometheus.prometheus._common's own real-world shape) instead goes
    # through VariableLookup#format_value, which renders an Array as
    # `value.to_json` - a JSON-array STRING (`["--strip-components=1"]`),
    # a completely different, unrelated text convention. Splitting THAT
    # on "," produced one garbage element still wrapped in `["..."]`,
    # which `tar_flags` then appended verbatim to the `tar --compare`/
    # `--extract` command lines - a syntactically broken command whose
    # stderr didn't match any of tar_changed?'s known warning patterns,
    # so extraction was silently treated as already up to date and never
    # ran at all. Real bug found live-verifying prometheus.prometheus.
    # node_exporter: the archive downloaded and passed its checksum
    # check, but nothing was ever actually unpacked.
    private def parse_list_param(raw : String?) : Array(String)
      return [] of String unless raw
      if raw.starts_with?('[')
        (Array(String).from_json(raw) rescue nil).try { |parsed| return parsed }
        # ONLY valid JSON - never a Python-repr repair pass. A value that
        # merely LOOKS like a container (a literal `exclude: "['x']"`
        # string, or a `{% if %}...{% else %}['x']{% endif %}` block's
        # rendered output) is a plain STRING in ansible-core -
        # native typing requires the template's whole AST to be one
        # output node wrapping one expression, so block-tag output is
        # never re-parsed (live-verified vs ansible-playbook 2.19.11,
        # see apt.cr's parse_package_names). A whole-value `{{ list_var }}`
        # container arg arrives as the double-quoted JSON the wire
        # serialized it to (see substitute_task_params's
        # whole-single-span comment), which the plain JSON parse above
        # already handles; anything else falls through to the comma
        # split, matching Ansible's own comma-split of a plain
        # string list param.
      end
      raw.split(",").map(&.strip).reject(&.empty?)
    end

    private def run(src : String, dest : String) : PluginResult
      exclude = parse_list_param(@params["exclude"]?)
      include_files = parse_list_param(@params["include"]?)
      keep_newer = true?(@params["keep_newer"]?, default: false)
      list_files = true?(@params["list_files"]?, default: false)
      # extra_opts - passed straight through to `tar`, Ansible's own
      # documented behavior (raw flags like `--strip-components=1`, the
      # standard way to unpack a GitHub-release-style tarball whose
      # single top-level directory shouldn't be preserved). Previously
      # entirely unimplemented (silently dropped) - a role using it
      # unpacked WITH the top-level directory still present, so every
      # path the role expected directly under dest/ (robertdebock.
      # phpmyadmin's own dest/index.php) was actually one level deeper
      # and missing.
      extra_opts = parse_list_param(@params["extra_opts"]?)

      handler = detect_handler(src)
      unless handler
        # Real unarchive's pick_handler composes its failure as
        # 'Failed to find handler for "<src>". Make sure the required
        # command to extract the file is installed.\n<reasons>' - the
        # head is deterministic; the reason list after it is NOT ordered
        # (2.14 collects the per-handler probe reasons into a Python
        # set, so even real-vs-real ordering shuffles run to run), so
        # the reasons are appended in handler order with duplicates
        # dropped - the only stable replica. Found via the podman-diff
        # unarchive_edge_cases E6 harness case, where this engine said
        # "Unsupported archive format for <src>" instead.
        head = %(Failed to find handler for "#{staged_src_echo(src)}". Make sure the required command to extract the file is installed.)
        reasons = handler_failure_reasons(src)
        msg = reasons.empty? ? head : "#{head}\n#{reasons.join("\n")}"
        return PluginResult.new(changed: false, failed: true, msg: msg)
      end

      changed = handler == :tar ? tar_changed?(src, dest, exclude, include_files, keep_newer, extra_opts) : zip_changed?(src, dest, exclude, include_files, keep_newer)

      extract_results = nil
      if changed
        extraction = handler == :tar ? extract_tar(src, dest, exclude, include_files, keep_newer, extra_opts) : extract_zip(src, dest, exclude, include_files, keep_newer)
        unless extraction[:exit_code] == 0
          return PluginResult.new(changed: false, failed: true, msg: "failed to extract #{src}")
        end
        extract_results = JSON.parse({
          cmd: extraction[:cmd],
          rc:  extraction[:exit_code],
          out: extraction[:stdout],
          err: extraction[:stderr],
        }.to_json)
      end

      if attr_error = apply_dest_attributes(dest, handler, src)
        return attr_error
      end
      stat_fields = dest_stat_fields(dest)

      files = list_files ? members(handler, src) : nil

      # Ansible's registered unarchive result runs handler, dest, src, then
      # extract_results (only on the changed path - res_args gets it
      # inserted before changed), changed, files (only with list_files),
      # then add_path_info's uid/gid/owner/group/mode/state/size -
      # live-verified vs 2.19.11 via `{{ r | to_json }}` for both the
      # extract and the already-extracted rerun. krikri always carries
      # `files` (empty without list_files), which lands in files' real
      # position.
      #
      # extract_results carries the extraction command's
      # {cmd, rc, out, err} on the changed path only (unarchive.py's
      # `res_args['extract_results'] = handler.unarchive()`) - the
      # unchanged path keeps it absent, matching real. Leaving it out
      # used to make `changed_when: result.extract_results.rc != 0`
      # fatal with "object of type 'dict' has no attribute
      # 'extract_results'" (marverix.chromium's tasks/download.yml).
      plugin_result = PluginResult.new(
        changed: changed,
        failed: false,
        msg: "",
        src: src,
        dest: dest,
        handler: handler == :tar ? "TgzArchive" : "ZipArchive",
        state: "directory",
        size: stat_fields[:size],
        uid: stat_fields[:uid],
        gid: stat_fields[:gid],
        owner: stat_fields[:owner],
        group: stat_fields[:group],
        mode: stat_fields[:mode],
        files: files || [] of String,
        key_order: %w[handler dest src extract_results changed files uid gid owner group mode state size]
      )
      plugin_result.extra["extract_results"] = extract_results if extract_results
      plugin_result
    end

    private def members(handler : Symbol, src : String) : Array(String)
      cmd = handler == :tar ? "tar tf #{shell_single_quote(src)}" : "unzip -Z1 #{shell_single_quote(src)}"
      remote_exec(cmd)[:stdout].split("\n").map(&.strip).reject(&.empty?)
    end

    private def tar_flags(exclude : Array(String), include_files : Array(String), keep_newer : Bool, extra_opts : Array(String) = [] of String) : String
      String.build do |str|
        str << " --keep-newer-files" if keep_newer
        extra_opts.each { |opt| str << " " << shell_single_quote(opt) }
        exclude.each { |pattern| str << " --exclude=#{shell_single_quote(pattern)}" }
        str << " " << include_files.map { |path| shell_single_quote(path) }.join(" ") unless include_files.empty?
      end
    end

    # A meaningful-difference line from `tar --compare`'s own output -
    # matches Ansible's TgzArchive#is_unarchived exactly (down to
    # the regex set), NOT a raw exit-code check. GNU tar's own exit code
    # from --compare is nonzero for CATEGORIES of output krikri-playbook
    # must NOT treat as "changed": most notably the bogus "Cannot stat:
    # No such file or directory" warning `--strip-components` itself
    # always emits for the now-empty top-level path it stripped away -
    # real bug found benchmarking robertdebock.phpmyadmin's own
    # extra_opts: ['--strip-components=1'] unpack, previously always
    # non-idempotent (every rerun re-extracted and reported changed:
    # true) purely because of that one benign warning line, verified via
    # ansible-playbook staying changed: false on the identical
    # rerun.
    UID_DIFF_PATTERN                = /: Uid differs$/
    GID_DIFF_PATTERN                = /: Gid differs$/
    MODE_DIFF_PATTERN               = /: Mode differs$/
    ALWAYS_MEANINGFUL_DIFF_PATTERNS = [
      /: Mod time differs$/, /: Invalid owner/, /: Invalid group/, /: Symlink differs$/,
    ]
    EMPTY_FILE_WARNING   = /: : Warning: Cannot stat: No such file or directory$/
    MISSING_FILE_WARNING = /: Warning: Cannot stat: No such file or directory$/

    private def tar_changed?(src : String, dest : String, exclude : Array(String), include_files : Array(String), keep_newer : Bool, extra_opts : Array(String) = [] of String) : Bool
      cmd = "tar --compare -C #{shell_single_quote(dest)} -f #{shell_single_quote(src)}#{tar_flags(exclude, include_files, keep_newer, extra_opts)}"
      result = remote_exec(cmd)
      lines = (result[:stdout].split("\n") + result[:stderr].split("\n"))

      # Ansible's own TgzArchive#is_unarchived (unarchive.py) only
      # treats a Uid/Gid/Mode-differs line as a real change when the
      # matching owner:/group:/mode: param was NOT itself given on the
      # task - when it WAS given, `set_fs_attributes_if_different()` is
      # trusted to already have applied it, and re-flagging the same diff
      # every run (since the archive's OWN embedded mode/ownership never
      # matches an explicit override) would make the task permanently
      # non-idempotent. Real bug found benchmarking prometheus.prometheus.
      # alertmanager round 134: its own `mode: 0755` unarchive task
      # re-extracted (changed: true) on every single rerun purely because
      # LICENSE/NOTICE/alertmanager.yml's archived mode (0644) differed
      # from the 0755 krikri-playbook (correctly) chmod'd them to.
      #
      # A Uid/Gid-differs line is furthermore only meaningful at ALL when
      # `is_unarchived` itself is running as root (`if run_uid == 0 and
      # not self.file_args['owner'] and OWNER_DIFF_RE...` in unarchive.py -
      # note the `run_uid == 0` half, not just the owner/group check).
      # Extracting as a non-root user can never set arbitrary file
      # ownership anyway (every extracted file ends up owned by the
      # extracting user regardless of what the archive itself records),
      # so a Uid/Gid mismatch against the archive's OWN embedded owner is
      # neither a real change nor fixable - Ansible ignores it
      # entirely in that case. Found via `juju4.polarproxy` (RHEL-family
      # round 60152), whose `unarchive: {mode: '0755', remote_src: true}`
      # (no owner:/group: given) runs under `become_user:` (a non-root
      # system user): this engine reported `changed: true` on every warm
      # rerun purely from "Uid differs"/"Gid differs" lines against the
      # archive's embedded (irrelevant, unreachable-as-non-root) owner,
      # while ansible-playbook, running as that same non-root user,
      # never even looks at them. Verified live: extracting the real
      # PolarProxy tarball as a non-root become_user and running `tar
      # --compare` reproduces exactly these two line kinds alongside
      # `Mode differs`, on every single file.
      owner_set = !@params["owner"]?.nil?
      group_set = !@params["group"]?.nil?
      mode_set = !@params["mode"]?.nil?
      running_as_root = LibC.getuid == 0

      exempt_from_diff = {
        UID_DIFF_PATTERN  => !running_as_root || owner_set,
        GID_DIFF_PATTERN  => !running_as_root || group_set,
        MODE_DIFF_PATTERN => mode_set,
      }

      lines.any? { |line| meaningful_diff_line?(line, exempt_from_diff) }
    end

    private def meaningful_diff_line?(line : String, exempt_from_diff : Hash(Regex, Bool)) : Bool
      return false if EMPTY_FILE_WARNING.matches?(line)
      return true if ALWAYS_MEANINGFUL_DIFF_PATTERNS.any?(&.matches?(line)) || MISSING_FILE_WARNING.matches?(line)

      exempt_from_diff.any? { |pattern, exempt| !exempt && pattern.matches?(line) }
    end

    private def extract_tar(src : String, dest : String, exclude : Array(String), include_files : Array(String), keep_newer : Bool, extra_opts : Array(String) = [] of String) : NamedTuple(cmd: String, exit_code: Int32, stdout: String, stderr: String)
      # Real's TgzArchive#unarchive (unarchive.py) passes a task-given
      # owner:/group: straight to tar itself (`--owner=`/`--group=` on the
      # --extract command), so ownership is applied AT EXTRACTION - to
      # every path tar creates, including intermediate directories the
      # archive's own listing never mentions as entries (a tarball built
      # without explicit directory members, e.g. apache-zookeeper-*.tar.gz:
      # only its FILES are listed, yet real's extraction still
      # owner-adjusts the directories tar synthesizes around them). The
      # post-extraction pass (apply_dest_attributes) only ever walks
      # LISTED members plus the top-level folders, so without these
      # flags an unlisted intermediate dir kept the archive's own
      # embedded uid/gid (round 5420000, bilalcaliskan.zookeeper: the
      # extracted top dir stayed root-owned - uid 1000 embedded in the
      # tarball - and the role's later `file: state=directory owner:`
      # task reported changed where real reported ok). GNU tar ignores
      # --owner/--group it cannot apply (a non-root run silently
      # extracts as the invoking user, rc=0), so this is safe to pass
      # whenever the task names them - the post pass still surfaces a
      # real chown failure as a task failure, exactly like real's
      # set_fs_attributes_if_different does.
      owner_flag = (owner = @params["owner"]?) ? " --owner=#{shell_single_quote(owner)}" : ""
      group_flag = (group = @params["group"]?) ? " --group=#{shell_single_quote(group)}" : ""
      cmd = "tar --extract -C #{shell_single_quote(dest)} -f #{shell_single_quote(src)}#{owner_flag}#{group_flag}#{tar_flags(exclude, include_files, keep_newer, extra_opts)}"
      result = remote_exec(cmd)
      {cmd: cmd, exit_code: result[:exit_code], stdout: result[:stdout], stderr: result[:stderr]}
    end

    private def zip_flags(exclude : Array(String), include_files : Array(String)) : String
      String.build do |str|
        str << " " << include_files.map { |path| shell_single_quote(path) }.join(" ") unless include_files.empty?
        str << " -x " << exclude.map { |pattern| shell_single_quote(pattern) }.join(" ") unless exclude.empty?
      end
    end

    # Approximation of Ansible's much more involved zipinfo/
    # permission-based idempotency check: compares each member file's
    # content checksum (from inside the zip) against what's already at
    # dest/member, plus (Ansible 2.19 ZipArchive#is_unarchived) each
    # member's zipinfo -T timestamp against the dest file's own mtime,
    # ignoring members that are directories.
    private def zip_changed?(src : String, dest : String, exclude : Array(String), include_files : Array(String), keep_newer : Bool = false) : Bool
      wanted = members(:zip, src).reject(&.ends_with?("/"))
      wanted = wanted.select { |member| include_files.empty? || include_files.includes?(member) }
      wanted = wanted.reject { |member| exclude.includes?(member) }
      zip_timestamps = zip_member_timestamps(src)

      wanted.any? do |member|
        # A member escaping dest never exists on disk at any path we're
        # allowed to look at: tar refuses it at extraction and unzip
        # strips it to somewhere inside dest, so there is no meaningful
        # on-disk counterpart - and the literal joined path would point
        # OUTSIDE dest, making the idempotency comparison read/hash an
        # arbitrary attacker-chosen file. Skip it (reporting "unchanged"
        # for that member; Ansible's own zipinfo comparison lstats
        # the literal joined path instead, i.e. it reads the escaping
        # file - a divergence documented in favor of containment).
        dest_path = contained_member_path(dest, member)
        if dest_path.nil?
          next false
        end

        # A symlink zip member (common for a shared LICENSE/README
        # linked into multiple sub-crate dirs, e.g. square/sudo_pair's
        # own release archive) stores its TARGET STRING as the member's
        # own content - `unzip -p` on it correctly returns that short
        # string. `md5sum < dest_path` on the extracted symlink follows
        # it (shell redirection always dereferences), comparing the
        # short target string against the potentially much larger
        # DEREFERENCED target file's content - permanently mismatched
        # even though extraction itself was byte-correct, making any
        # such archive permanently non-idempotent (re-extracted on
        # every single run). Found benchmarking robertdebock.sudo_pair.
        # `readlink` (not dereferenced) is the correct comparison.
        symlink_result = remote_exec("test -L #{shell_single_quote(dest_path)} && readlink #{shell_single_quote(dest_path)}")
        if symlink_result[:exit_code] == 0
          archive_checksum = remote_exec("unzip -p #{shell_single_quote(src)} #{shell_single_quote(member)} 2>/dev/null")[:stdout].strip
          next archive_checksum != symlink_result[:stdout].strip
        end

        next true unless remote_file_exists?(dest_path)

        # Ansible's ZipArchive#is_unarchived compares the zipinfo -T
        # timestamp against the existing file's mtime and reports changed
        # (itemize `.f..t....??`) when they differ, re-extracting even
        # though the CONTENT matches - krikri previously compared content
        # only, so a second run over an already-extracted dest reported
        # ok where real ansible reported changed. unzip's own written
        # mtime and zipinfo -T's printed one can also legitimately
        # differ (see #ansible_zip_epoch for the hour-wide DST case);
        # ansible deliberately treats that as a change - its own
        # comment: "this timestamp calculation has a rounding error
        # somewhere... unzip and this timestamp can be one second off.
        # When that happens, we report a change and re-unzip the file."
        # stat's %Y (whole seconds) is equivalent to ansible's float
        # compare against lstat mtime: unzip always writes whole-second
        # mtimes.
        if (zip_ts = zip_timestamps[member]?) &&
           (dest_mtime = remote_exec("stat -c %Y #{shell_single_quote(dest_path)} 2>/dev/null")[:stdout].strip.to_i64?)
          if keep_newer
            # Ansible's keep_newer: an OLDER dest file is replaced
            # (changed), a NEWER one is excluded from every further
            # comparison - including the content check below - instead
            # of being flagged.
            if zip_ts > dest_mtime
              next true
            elsif zip_ts < dest_mtime
              next false
            end
          elsif zip_ts != dest_mtime
            next true
          end
        end

        archive_checksum = remote_exec("unzip -p #{shell_single_quote(src)} #{shell_single_quote(member)} 2>/dev/null | md5sum")[:stdout].strip
        dest_checksum = remote_exec("md5sum < #{shell_single_quote(dest_path)} 2>/dev/null")[:stdout].strip
        archive_checksum.split(" ").first? != dest_checksum.split(" ").first?
      end
    end

    # Ansible parses `zipinfo -T -s` with shape-strict checks: exactly 8
    # whitespace-split fields (Python's split(None, 7), so a member name
    # containing spaces survives intact in field 7), a permission string
    # 7/8/10 chars long whose characters all come from "rwxstah-" - the
    # checks that reject zipinfo's own "Archive:"/"files," header and
    # footer lines - and a 15-char timestamp field.
    private def zip_member_timestamps(src : String) : Hash(String, Int64)
      timestamps = {} of String => Int64
      remote_exec("zipinfo -T -s #{shell_single_quote(src)} 2>/dev/null")[:stdout].each_line do |line|
        pcs = line.split(/\s+/, 8)
        next unless pcs.size == 8
        perms = pcs[0]
        next unless perms.size.in?(7, 8, 10)
        next unless "dl-?".includes?(perms[0]) && perms[1..].chars.all? { |perm_char| "rwxstah-".includes?(perm_char) }
        next unless pcs[6].size == 15
        timestamps[pcs[7]] = ansible_zip_epoch(pcs[6])
      end
      timestamps
    end

    # Ansible's ZipArchive#_valid_time_stamp: regex-parse
    # "YYYYMMDD.HHMMSS", clamp years before 1980 (the DOS timestamp
    # format's own floor) to 1980-01-01 and years past 2107 to
    # 2107-12-31 23:59:59, then time.mktime - whose struct_time ansible
    # builds with tm_isdst=0, NOT -1. That isdst=0 is the whole quirk:
    # a zip's timestamp is a wall-clock time with no DST marking, but
    # ansible forces the STANDARD-time interpretation, so for any member
    # stored while DST was in effect the computed epoch lands one hour
    # away from the epoch unzip actually wrote to the extracted file
    # (unzip restores the UT extra field's exact epoch) - the
    # guaranteed-mtime-mismatch that makes real ansible re-extract such
    # zips on every run on a DST-zone host, and exactly what this mirror
    # has to reproduce rather than "fix". (The 2038 clamp only fires on
    # 32-bit time_t systems - ansible's _y2038_impacted - and krikri
    # targets 64-bit Linux, where it never does.)
    private def ansible_zip_epoch(timestamp : String) : Int64
      match = timestamp.match(/^(\d{4})(\d{2})(\d{2})\.(\d{2})(\d{2})(\d{2})$/)
      unless match
        return ansible_mktime(1980, 1, 1, 0, 0, 0)
      end

      year = match[1].to_i
      month = match[2].to_i
      day = match[3].to_i
      hour = match[4].to_i
      minute = match[5].to_i
      second = match[6].to_i

      # Python's time.mktime rejects out-of-range fields (month 13, hour
      # 24, ...) with ValueError, which ansible's try/except folds back
      # to the 1980 epoch; glibc's mktime would instead normalize them,
      # so the range has to be checked before the C call.
      if !(1..12).includes?(month) || !(1..31).includes?(day) ||
         hour > 23 || minute > 59 || second > 61
        return ansible_mktime(1980, 1, 1, 0, 0, 0)
      end

      if year < 1980
        ansible_mktime(1980, 1, 1, 0, 0, 0)
      elsif year > 2107
        ansible_mktime(2107, 12, 31, 23, 59, 59)
      else
        ansible_mktime(year, month, day, hour, minute, second)
      end
    end

    # time.mktime's equivalent: local-TZ conversion with tm_isdst forced
    # to 0 (see #ansible_zip_epoch for why that isdst=0 is deliberate).
    # Runs in the plugin process's own local TZ - identical to the module
    # process's TZ for ansible_connection=local (the only case where the
    # archive and the compared files live on this machine anyway).
    private def ansible_mktime(year : Int32, month : Int32, day : Int32, hour : Int32, minute : Int32, second : Int32) : Int64
      tm = LibC::Tm.new
      tm.tm_year = year - 1900
      tm.tm_mon = month - 1
      tm.tm_mday = day
      tm.tm_hour = hour
      tm.tm_min = minute
      tm.tm_sec = second
      tm.tm_isdst = 0
      LibC.mktime(pointerof(tm))
    end

    private def extract_zip(src : String, dest : String, exclude : Array(String), include_files : Array(String), keep_newer : Bool) : NamedTuple(cmd: String, exit_code: Int32, stdout: String, stderr: String)
      overwrite_flag = keep_newer ? "-n" : "-o"
      # No -q: Ansible invokes plain `unzip -o src -d dest`, and
      # Info-ZIP unzip exits 1 (warning) when it has to sanitize a
      # member - e.g. "skipped \"../\" path component(s)". -q suppresses
      # the warning AND the nonzero exit, so a zip-slip-shaped archive
      # extracted "successfully" here while Ansible failed the task
      # outright - and krikri's post-extraction attribute pass then ran
      # over the raw (unsanitized) member names. Matching Ansible's
      # exact invocation means matching its exact failure.
      cmd = "unzip #{overwrite_flag} -d #{shell_single_quote(dest)} #{shell_single_quote(src)}#{zip_flags(exclude, include_files)}"
      result = remote_exec(cmd)
      {cmd: cmd, exit_code: result[:exit_code], stdout: result[:stdout], stderr: result[:stderr]}
    end

    # Returns a failed PluginResult if any of owner:/group:/mode: fails
    # to apply, nil otherwise. Proactive-audit fix (same "real command
    # failure silently discarded" shape as apt_repository.cr's own
    # update_cache bug and sysctl.cr's own apply_kernel_value bug found
    # this round): applied to every extracted path, not just to dest
    # itself - Ansible's unarchive module does a final pass over
    # every extracted path when owner:/group:/mode: is given. Verified
    # live: robertdebock.nextcloud's `Install nextcloud` task (`owner:
    # www-data, group: www-data`) left the ENTIRE extracted tree
    # www-data:www-data on ansible-playbook (dest itself, every
    # subdirectory, every file down to AUTHORS) - krikri-playbook's own
    # previous `chown #{owner} #{dest}` (no `-R`) left everything but
    # dest itself still root:root, which then broke the role's own
    # downstream `occ` commands ("Cannot write into 'apps' directory")
    # since the role's own permissions pass only explicitly re-chowns
    # config.php/config/data, relying on unarchive's owner: for
    # everything else (apps/, 3rdparty/, etc).
    #
    # Ansible's own unarchive module applies owner:/group:/mode: to
    # every EXTRACTED path (dest/<member> for each archive member,
    # ansible#35426) on every run - including an already-extracted
    # rerun - and NEVER to dest itself, which it requires to already
    # exist and leaves at whatever attributes it had. This used to be
    # approximated with a blanket `find dest -mindepth 1 -exec ...` -
    # which reaches every extracted member correctly, but ALSO reaches
    # any pre-existing, unrelated file that already happened to live
    # under dest, which Ansible never touches. Found live via
    # buluma.daemonize (a 400-role regression sweep): its own
    # `get_url: {dest: /root/daemonize-X.tar.gz, mode: "0644"}` followed
    # by `unarchive: {dest: /root, mode: "0755"}` shares /root as BOTH
    # tasks' target directory - the blanket find chmod'd the just-
    # downloaded tarball (an unrelated sibling, not a member of the
    # archive being extracted) from 0644 to 0755, so get_url's own
    # idempotency check saw a corrupted mode on the next run and
    # reported changed: true where Ansible (which never touches
    # anything outside the archive's own member list) stayed unchanged.
    #
    # Fixed by applying attributes to each archive member's own
    # `dest/<member>` path explicitly (the same list `members` already
    # produces for `list_files:`, real tar/zip listings enumerate every
    # directory entry as well as every file, so no separate intermediate-
    # directory pass is needed) instead of walking dest itself. `find`
    # accepts multiple starting paths, so passing every member path as
    # its own start argument (plus `-maxdepth 0`, since each is already
    # a leaf as far as this find invocation is concerned - `members`
    # already recurses through the archive's own listing) keeps the
    # same `-exec ... +` batching the old blanket version relied on to
    # survive archives with many members, applied to an explicit
    # allowlist instead of an implicit "everything here" scan. The
    # member-path list itself is also chunked (MEMBER_CHUNK_SIZE) across
    # multiple `find` invocations - unlike the old single `dest` start
    # argument, a huge member count could otherwise itself blow past a
    # single command line's own length limit.
    MEMBER_CHUNK_SIZE = 200

    # The `--strip-components=N` extra_opt, if any (either the
    # `--strip-components=N` joined form or `--strip-components`/`N` as
    # separate elements - tar accepts both). Zips never see extra_opts
    # (they aren't forwarded to `unzip`), so the count only ever applies
    # to the tar handler's own on-disk layout.
    private def strip_components_count : Int32
      opts = parse_list_param(@params["extra_opts"]?)
      opts.each_with_index do |opt, index|
        if match = opt.match(/\A--strip-components=(\d+)\z/)
          return match[1].to_i
        elsif opt == "--strip-components" && (next_opt = opts[index + 1]?)
          return next_opt.to_i? || 0
        end
      end
      0
    end

    # extra_opts entries that AREN'T a tar flag (don't start with "-") are
    # positional MEMBER NAMES to tar itself - `tar --extract -f archive.tar
    # hugo` extracts only the "hugo" member (and, for a directory member,
    # everything nested under it), the exact mechanism darkwizard242.hugo's
    # own `extra_opts: [hugo]` uses to pull just one binary out of a
    # tarball that also ships README.md/LICENSE at the top level. tar_flags
    # already passes these through to the real extraction command
    # unchanged; apply_dest_attributes' own member list must respect the
    # same filter or it walks archive members that were never actually
    # extracted, failing every find with "No such file or directory"
    # (round 811222/811266: --strip-components=1's own fix at 0.9.1049
    # covered the OTHER extra_opts shape, path-prefix stripping, but not
    # this one - a real, separate use of the same param). Empty when
    # every extra_opts entry is a flag (the overwhelmingly common case),
    # meaning "no member filter, everything tar actually extracted counts".
    # The SPLIT flag-with-value form is not a member name either:
    # 0x0I.elasticsearch's own
    # `extra_opts: [--strip-components, '1']` put the VALUE "1" (a
    # non-flag element) into this filter, which no member matches
    # ("1" or "1/" appears in no archive), so the whole attribute pass
    # saw an empty member list and silently skipped chown/chgrp/chmod -
    # the extracted tree kept the archive's own uid/gid (round 1300009:
    # a later `file: state: directory` task had to fix the config dir's
    # ownership, reporting changed: true where Ansible reported ok).
    private def extra_opts_member_filter : Array(String)
      opts = parse_list_param(@params["extra_opts"]?)
      member_names = [] of String
      value_next = false
      opts.each do |opt|
        if value_next
          value_next = false
        elsif opt.starts_with?("-")
          value_next = opt == "--strip-components"
        else
          member_names << opt
        end
      end
      member_names
    end

    # Whether an archive member survives the include:/exclude: filter.
    # tar's member args glob-match the member itself AND pull in the
    # whole tree under a matched directory (GNU tar lists/extracts a
    # named directory with its contents), so a prefix match counts;
    # zip's filtering is pure fnmatch per member (unarchive.py's
    # files_in_archive walk), so the prefix rule only applies to the
    # tar handler. Unbracketed fnmatch specials (* ?) are translated,
    # everything else is literal.
    private def member_matches_any_pattern?(patterns : Array(String), member : String, tree = true) : Bool
      patterns.any? do |pattern|
        return true if member == pattern
        return true if tree && member.starts_with?("#{pattern}/")
        escaped = pattern.gsub(/[\\^$.|+(){}]/) { |special| "\\#{special}" }
          .gsub("*", ".*")
          .gsub("?", ".")
          .gsub("[", "\\[").gsub("]", "\\]")
        begin
          Regex.new("^#{escaped}$").matches?(member)
        rescue
          false
        end
      end
    end

    # tar's own --exclude is UNANCHORED: a pattern matches the member
    # itself, anything nested under a matching directory, and any
    # component-boundary suffix of the member (`exclude: [LICENSE]`
    # excludes `sing-box-1.14.3-linux-amd64-musl/LICENSE` without naming
    # the wrapper dir). Mirrored here for the tar handler's attribute
    # walk because the walk's member list comes from a plain `tar tf`,
    # not from tar's own --exclude-filtered listing - see
    # attribute_member_names for the round 5460257 failure this closes.
    private def member_matches_unanchored_exclude?(pattern : String, member : String) : Bool
      components = member.split("/")
      components.each_index do |index|
        suffix = components[index..].reject(&.empty?).join("/")
        next if suffix.empty?
        return true if member_matches_any_pattern?([pattern], suffix)
      end
      false
    end

    # Maps an archive-listing member path to its on-disk path under dest
    # after --strip-components=N stripping (mirroring GNU tar's own
    # semantics: N leading path components removed, a member left with
    # nothing is not extracted at all). Nil when the member vanishes.
    private def stripped_member(member : String, strip : Int32) : String?
      return member if strip.zero?
      components = member.split("/")
      stripped = components[strip..]?
      return nil if stripped.nil? || stripped.all?(&.empty?)
      stripped.reject(&.empty?).join("/")
    end

    # The on-disk path an archive member maps to under dest, or nil when
    # the member must NOT be touched on disk at all. Archive member names
    # are attacker-controlled (remote_src archives, downloaded URLs,
    # release artifacts), so:
    # - a leading '/' is stripped exactly the way GNU tar (--no-absolute-
    #   names), Info-ZIP unzip and Ansible's own TgzArchive#
    #   files_in_archive (`if filename.startswith('/'): filename =
    #   filename[1:]`) all treat absolute member names;
    # - a member whose normalized path is not dest or under dest is
    #   dropped outright - real tar refuses such members at extraction
    #   ("Member name contains '..'") and unzip strips them, but the
    #   member LISTING still carries the raw name, and feeding that raw
    #   name to find/chown/chmod used to let an archive direct attribute
    #   changes (as root, under become:) at arbitrary paths outside
    #   dest. The check is lexical (Path#normalize resolves '..' without
    #   touching the filesystem), matching how the extraction tools
    #   themselves sanitize; a dest reached THROUGH a symlinked parent
    #   is out of scope the same way it is for the extraction tools.
    # dest itself is a legitimate result (the self-referential "./"
    # member of a `tar czf x.tar.gz .` archive normalizes onto dest and
    # Ansible applies requested attributes to it - see the "./"
    # comment in apply_dest_attributes).
    private def contained_member_path(dest : String, member : String) : String?
      cleaned = member.lstrip('/')
      return nil if cleaned.empty?
      dest_norm = Path[dest].normalize.to_s
      path = Path[dest, cleaned].normalize.to_s
      return nil unless path == dest_norm || dest_norm == "/" || path.starts_with?("#{dest_norm}/")
      path
    end

    # The filtered, --strip-components-transformed member names real's
    # attribute pass walks (unarchive.py's files_in_archive: the archive
    # listing after extra_opts' --show-transformed-names transforms, the
    # include:/exclude: filters and real's own excludes prep). Split out
    # so both the per-member on-disk paths and the top-folder pass below
    # walk the exact same filtered set. A member that collapses onto dest
    # itself under stripping (the wrapper dir of a GitHub-release tarball,
    # or the leading "./" of a `-C src .` archive) comes back as "" - the
    # per-member pass maps that onto dest itself: tar extracts NOTHING
    # there, but the attribute list must still include dest - Ansible
    # lists the archive with `--show-transformed-names` + extra_opts, and
    # a fully-stripped member comes out as "" (file member) or "/"
    # (directory member), both of which its leading-'/' strip turns
    # into "" and `os.path.join(dest, "")` puts dest itself on the
    # attribute list (live-verified against ansible-core 2.19.11:
    # mode: "0750" over --strip-components=1 ends with dest itself
    # at 0750, exactly like every extracted member). Only the
    # EXtraction skips it - tar refuses a member left with no name.
    private def attribute_member_names(handler : Symbol, src : String) : Array(String)
      strip = handler == :tar ? strip_components_count : 0
      member_filter = handler == :tar ? extra_opts_member_filter : [] of String
      include_files = parse_list_param(@params["include"]?)
      exclude_files = parse_list_param(@params["exclude"]?).map(&.rstrip('/'))
      members(handler, src).compact_map do |member|
        if !member_filter.empty? && member_filter.none? { |named| member == named || member.starts_with?("#{named}/") }
          next nil
        end
        # include:/exclude: filter the EXTRACTION (tar member args / unzip
        # patterns) and real's attribute pass walks handler.
        # files_in_archive, which carries the SAME filter: tar --list
        # with member args lists only the matching members (plus the
        # contents of a matched directory), zip's files_in_archive
        # fnmatch-filters per member (unarchive.py). Without the filter
        # here the attribute pass walks members that were never
        # extracted, failing every find with "No such file or directory"
        # (round 2100210: alecunsolo.chezmoi's `unarchive: {include:
        # [chezmoi], owner: root, mode: "0755"}` into /usr/local/bin -
        # the tarball's untouched LICENSE/README.md/completions members
        # are not on disk). exclude: entries lose a trailing '/' like
        # real's own excludes prep.
        next nil if !include_files.empty? && !member_matches_any_pattern?(include_files, member, handler == :tar)
        # exclude: on the tar handler must mirror tar's own --exclude
        # semantics, which are UNANCHORED: a pattern matches the member
        # itself, anything nested under a matching directory, and any
        # component-boundary suffix of the member - `exclude: [LICENSE]`
        # excludes `sing-box-1.14.3-linux-amd64-musl/LICENSE` without
        # naming the wrapper dir. tar applies that to both --extract and
        # real's own files_in_archive listing (which reuses the same
        # --exclude flags), so an excluded member never reaches real's
        # attribute walk even when --strip-components would map it onto
        # an on-disk path. This member list comes from a plain `tar tf`
        # instead, so the exclusion is re-implemented here with the same
        # unanchored matching - the previous anchored name-only match let
        # stripped, excluded members survive onto the walk list and fail
        # every find with "No such file or directory" (round 5460257:
        # foi.sing_box's `exclude: [LICENSE]` + `--strip-components=1` +
        # mode: 0755 into /usr/local/bin; the wrapper-dir-relative
        # LICENSE was never extracted but became
        # find /usr/local/bin/LICENSE anyway). The zip handler keeps the
        # anchored per-name match: unzip's -x patterns match full member
        # paths, and real's ZipArchive fnmatches them the same way.
        if handler == :tar
          next nil if exclude_files.any? { |pattern| member_matches_unanchored_exclude?(pattern, member) }
        else
          next nil if exclude_files.any? { |pattern| member_matches_any_pattern?([pattern], member) }
        end
        stripped_member(member, strip) || ""
      end
    end

    # Shell-quoted on-disk paths for every archive member, after
    # --strip-components stripping - split out of #apply_dest_attributes
    # purely to keep that method's own branching (owner:/group:/mode:
    # each independently optional) readable rather than tangled with
    # this stripping logic's own branches.
    private def stripped_member_paths(dest : String, handler : Symbol, src : String) : Array(String)
      attribute_member_names(handler, src).compact_map do |name|
        next shell_single_quote(dest) if name.empty?
        # Containment FIRST: a member like `../../etc` (or an absolute
        # one) normalizes outside dest and must never reach find/chown/
        # chmod as a start argument - see contained_member_path.
        path = contained_member_path(dest, name)
        next nil if path.nil?
        shell_single_quote(path)
      end
    end

    # The extracted TOP-LEVEL folders real's attribute pass applies
    # owner:/group:/mode: to over and above the member list itself
    # (unarchive.py's `top_folders` walk, ansible#35426): for every
    # transformed member containing a '/', the member's first path
    # component under dest. This is what makes an archive whose listing
    # carries only FILES (no explicit directory entries at all - e.g.
    # apache-zookeeper-*.tar.gz) still get its extracted top directory
    # owned/chmod'd like real: the directory itself is no member, but
    # every member under it names it as component zero, and a later
    # `file: state=directory owner:` over the top dir must find it
    # already right (round 5420000, bilalcaliskan.zookeeper - the top
    # dir stayed root-owned here while real's top-folder pass had
    # chown'd it, so real's file: task reported ok and krikri's
    # changed). Real joins these onto dest verbatim; the containment
    # check is kept anyway because a member that escapes dest (dropped
    # from the per-member pass for exactly that reason) must not
    # resurrect its first component as a find start argument here
    # either.
    private def top_folder_paths(dest : String, handler : Symbol, src : String) : Array(String)
      attribute_member_names(handler, src).compact_map do |name|
        next nil unless name.includes?("/")
        first_component = name.split("/").first? || ""
        next nil if first_component.empty?
        contained_member_path(dest, first_component)
      end.uniq!
    end

    private def apply_dest_attributes(dest : String, handler : Symbol, src : String) : PluginResult?
      return nil unless @params["owner"]? || @params["group"]? || @params["mode"]?

      # A tar built via `tar czf archive.tar.gz -C src .` (archiving the
      # CURRENT directory) lists a leading self-referential "./" member
      # for the archived directory itself - `Path[dest, "./"]` normalizes
      # right back to dest. This is deliberately NOT filtered out:
      # Ansible (live-verified against ansible-core 2.19.11) DOES apply
      # a requested mode:/owner: to dest itself in this shape - dest at
      # 700, an archive whose own "./" entry records 775, and a task
      # requesting mode: "0644" all converge to dest ending up 644 (the
      # TASK's own requested mode - neither the pre-existing 700 nor the
      # archive's embedded 775). Ansible treats "./" as an ordinary
      # member like any other; it just happens to resolve to dest's own
      # path. Only a member that ISN'T dest (the overwhelmingly common
      # shape - an archive listing individual named files/dirs rather
      # than ".") skips dest, because dest was simply never one of its
      # members to begin with - see the mongodb_exporter case below,
      # whose archive has no "./" entry at all.
      # The listing paths are ARCHIVE paths; with extra_opts:
      # --strip-components=N (robertdebock.phpmyadmin's own unpack) the
      # on-disk layout is dest/<stripped path>, so the member list must
      # go through the same stripping before becoming find start
      # arguments - verbatim archive paths point at directories that
      # don't exist on disk, failing every find with "No such file or
      # directory" (found live: the 0.9.1044 member-scoping fix kept
      # using raw archive paths and made phpmyadmin's unarchive task
      # fail outright where the pre-fix blanket walk had merely been
      # over-broad).
      member_paths = stripped_member_paths(dest, handler, src)
      # Real's own pass order: every LISTED member first, then the
      # top-level folders (unarchive.py's top_folders loop) - merged into
      # one chunked find walk here; the operations are idempotent, so a
      # top folder that is also an explicitly listed dir member is
      # simply visited twice, exactly like real does.
      paths = member_paths + top_folder_paths(dest, handler, src).map { |path| shell_single_quote(path) }
      paths = paths.uniq
      return nil if paths.empty?

      paths.each_slice(MEMBER_CHUNK_SIZE) do |chunk|
        # -P (GNU find's own default, made explicit here so a future
        # edit can't silently switch to -L): a symlink member start
        # argument must be examined AS a symlink, never followed -
        # -maxdepth 0 means find never descends past the start points
        # anyway, but -P also pins down the start-point lstat itself.
        member_args = "-P #{chunk.join(" ")} -maxdepth 0"
        if owner = @params["owner"]?
          # -h: chown defaults to dereferencing symlinks, which would
          # let an archive's symlink member redirect the ownership
          # change onto any file it points at (outside dest) -
          # Ansible's set_owner_if_different always uses os.lchown,
          # never the dereferencing form.
          result = remote_exec("find #{member_args} -exec chown -h #{shell_single_quote(owner)} {} +")
          if result[:exit_code] != 0
            return PluginResult.new(changed: true, failed: true, msg: "Failed to set owner under #{dest}: #{result[:stderr]}")
          end
        end
        if group = @params["group"]?
          # -h: same symlink-dereference hazard as chown above (Ansible's set_group_if_different uses os.lchown too).
          result = remote_exec("find #{member_args} -exec chgrp -h #{shell_single_quote(group)} {} +")
          if result[:exit_code] != 0
            return PluginResult.new(changed: true, failed: true, msg: "Failed to set group under #{dest}: #{result[:stderr]}")
          end
        end
        if mode = @params["mode"]?
          # ! -type l: chmod has no no-dereference form on Linux, so a
          # symlink member must be SKIPPED entirely - chmodding through
          # it would change the mode of whatever file the archive points
          # the link at, anywhere on the filesystem. Ansible's
          # set_mode_if_different on a symlink chmods through the link
          # and then restores the underlying mode (net effect: the
          # target's mode is unchanged); never touching it reaches the
          # same end state without the transient write.
          result = remote_exec("find #{member_args} ! -type l -exec chmod #{shell_single_quote(mode)} {} +")
          if result[:exit_code] != 0
            return PluginResult.new(changed: true, failed: true, msg: "Failed to set mode under #{dest}: #{result[:stderr]}")
          end
        end
      end
      nil
    end

    private def dest_stat_fields(dest : String) : NamedTuple(size: Int64, uid: Int64, gid: Int64, owner: String, group: String, mode: String)
      result = remote_exec("stat -c '%s|%u|%g|%U|%G|%a' #{shell_single_quote(dest)} 2>/dev/null")
      fields = result[:stdout].strip.split("|")

      if result[:exit_code] == 0 && fields.size == 6
        {
          size:  fields[0].to_i64,
          uid:   fields[1].to_i64,
          gid:   fields[2].to_i64,
          owner: fields[3],
          group: fields[4],
          mode:  "0#{fields[5]}",
        }
      else
        {size: 0_i64, uid: 0_i64, gid: 0_i64, owner: "", group: "", mode: ""}
      end
    end
  end
end

# Plugin entry point
input = STDIN.gets_to_end
config = JSON.parse(input)

plugin = Krikri::UnarchivePlugin.new(config)
plugin.run
