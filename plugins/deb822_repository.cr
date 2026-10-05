#!/usr/bin/env crystal

require "json"
require "http/client"
require "uri"
require "../src/krikri/base_plugin"
require "../src/krikri/plugin_helpers/http_download"
require "../src/krikri/plugin_helpers/deb822_repository_content"
require "../src/krikri/plugin_helpers/python_lib_gate"

module Krikri
  # Deb822_repository plugin - adds/removes a DEB822-format (`.sources`)
  # APT repository file. Compatible with (a subset of) Ansible's
  # ansible.builtin.deb822_repository module (ansible-core 2.15+, the
  # modern replacement for a plain apt_repository: source line, now what
  # current NodeSource/Docker-style install docs tell users to write).
  #
  # Real gap found benchmarking geerlingguy.nodejs's own "Add NodeSource
  # repositories for Node.js." task, which uses exactly this module -
  # previously entirely unimplemented (already flagged in
  # KNOWN_MISSING.md from geerlingguy.docker hitting the same gap: its
  # own "Add or remove Docker repository." task skipped identically).
  # With the repo never actually added, apt-get never sees the
  # NodeSource suite at all, so "Ensure Node.js and npm are installed."
  # fails outright (`nodejs=20.x*` isn't available from any configured
  # source) - not a silent divergence, a hard failure with no
  # obvious tie back to the skipped task.
  #
  # Supported parameters (the core shape both geerlingguy.docker and
  # geerlingguy.nodejs actually write, plus every other real DEB822 key
  # Ansible's own module supports: architectures, trusted, enabled,
  # allow_insecure, allow_downgrade_to_insecure, allow_weak, pdiffs,
  # by_hash, languages, targets, check_date, check_valid_until,
  # date_max_future, exclude/include (ansible-core 2.21+), and
  # inrelease_path - closed across a proactive scope-cut audit pass and
  # a later param-coverage pass, verified against the Ansible module's own
  # source for exact field-name/value-format conversion. Note
  # inrelease_path IS written to the file by Ansible (as
  # "Inrelease-Path:" - the module never pops it from params, unlike
  # mode/state), so this plugin writes it too rather than consuming it.
  # List-typed params (uris/suites/components/types/architectures/
  # languages/targets/exclude/include) accept both a real YAML list
  # (arriving as a JSON-array-shaped string after task-param
  # substitution) and a comma-separated scalar, matching Ansible's
  # own check_type_list backward compat):
  # - name (required): base filename under /etc/apt/sources.list.d/,
  #   written as <name>.sources
  # - types: deb (default) | deb-src | "deb deb-src" - elements validated
  #   against [deb, deb-src] like Ansible's own choices check
  # - uris: the repo URL(s), space-separated if more than one (optional
  #   - Ansible accepts a name-only task and writes just the
  #   X-Repolib-Name header + the Types default)
  # - suites: distro suite/codename(s) (optional)
  # - components: repo component(s), e.g. "main"
  # - signed_by: a path to an *already-local* keyring/armored-key file,
  #   OR a URL - fetched (binary-safe, redirect-aware, matching
  #   get_url.cr's own response.body_io streaming rather than a UTF-8-
  #   decoding String read), stored as `.asc` (ASCII-armored) or `.gpg`
  #   (binary) under `/etc/apt/keyrings/<name>{.asc,.gpg}` (Ansible's
  #   own naming convention - no `gpg --dearmor` involved, the fork stores
  #   armored keys verbatim) - the *local* path is what actually lands in
  #   the rendered Signed-By: field after the key has been fetched and
  #   stored. OR inline ASCII-armored GPG key text, detected by its
  #   "-----BEGIN PGP" leading bytes and rendered as a Deb822 folded
  #   multi-line value (indented continuation lines, matching
  #   Ansible's own format_multiline). OR a key fingerprint (40 hex chars),
  #   space-normalized and emitted literally on one line.
  # - state: present (default) | absent
  # - mode: applied to the resulting file (default "0644", matching
  #   Ansible's own module default)
  #
  # Idempotency: compares the fully-rendered file content against
  # whatever's already on disk at the target path - matching
  # Ansible's own module, which rewrites (not merges) the whole file
  # and reports changed based on a content diff.
  #
  # Dependency gate: the Ansible module is Python and imports
  # `debian.deb822` unconditionally right after its own module-arg
  # validation - a target without python3-debian FAILS the task with
  # missing_required_lib("python3-debian") wording (live-verified
  # against ansible-core 2.19.11 on trixie and 2.19's observed behavior;
  # neither auto-installs the dependency, unlike devel's
  # install_python_debian/respawn path). This plugin previously
  # skipped that gate entirely and happily wrote the file, reporting
  # changed=1 where Ansible reports a failed (often ignore_errors'd)
  # task - found via krikri-playbook-generator's fixed generic
  # dependency set, which does NOT preinstall python3-debian in its
  # real-ansible container.
  class Deb822RepositoryPlugin < BasePlugin
    # ansible.builtin.deb822_repository's `type: bool` options, in the real argument-spec
    # declaration order (ansible-doc -j ansible.builtin.deb822_repository). Validated at
    # module setup by BasePlugin#validate_bool_params! - see its block
    # comment for the real-Ansible semantics and message wording.
    protected def bool_params : Array(String)
      %w[allow_downgrade_to_insecure allow_insecure allow_weak by_hash check_date
        check_valid_until enabled pdiffs trusted]
    end

    # Every bool option here defaults to None in Ansible's argspec, so an
    # explicit null skips type validation there (see
    # BasePlugin#bool_params_none_default).
    protected def bool_params_none_default : Array(String)
      %w[allow_downgrade_to_insecure allow_insecure allow_weak by_hash check_date
        check_valid_until enabled pdiffs trusted]
    end

    SOURCES_LIST_D = "/etc/apt/sources.list.d"
    KEYRINGS_DIR   = "/etc/apt/keyrings"

    # Real deb822_repository's success dict insertion order (both exits).
    DEB822_ORDER = %w[repo changed dest key_filename]

    @slug : String = ""

    def execute : PluginResult
      validate_bool_params!
      # Ansible rejects ANY parameter outside its own argument_spec
      # at module-arg validation, before any action runs (ansible-core
      # 2.15 has no body_string/body - a body-only task fails with
      # "Unsupported parameters", it does not write the file). Found via
      # the podman-diff deb822_repository_edge_cases V5 harness case.
      # check_mode/diff_mode/_verbosity/_environment are engine-internal
      # keys injected by the executor (see build_plugin_config), not
      # part of Ansible's argument_spec, so none are rejected.
      deb822_supported = {"allow_downgrade_to_insecure", "allow_insecure", "allow_weak", "architectures", "by_hash", "check_date", "check_valid_until", "components", "date_max_future", "enabled", "exclude", "include", "inrelease_path", "languages", "mode", "name", "pdiffs", "signed_by", "state", "suites", "targets", "trusted", "types", "uris"}
      deb822_internal = {"_ansible_check_mode", "_ansible_diff", "_module_name", "_verbosity", "_environment"}
      unsupported = @params.keys.reject { |k| deb822_supported.includes?(k) || deb822_internal.includes?(k) }
      unless unsupported.empty?
        return PluginResult.new(
          changed: false,
          failed: true,
          msg: "Unsupported parameters for (ansible.builtin.deb822_repository) module: #{unsupported.sort.join(", ")}. " \
               "Supported parameters include: #{deb822_supported.to_a.sort.join(", ")}."
        )
      end

      name = @params["name"]?
      return PluginResult.new(changed: false, failed: true, msg: "missing required argument: name") unless name

      # Ansible's own argument_spec validates `types` elements
      # against choices=[deb, deb-src] and FAILS the task (changed=False)
      # on anything else - it does not silently write the invalid value.
      # uris/suites are NOT required by Ansible: a name-only task
      # succeeds and writes just X-Repolib-Name + the Types: deb default.
      # This is argspec-level validation (fires for state=absent too,
      # like every choices check inside AnsibleModule's init).
      if types = @params["types"]?
        bad = parse_list_param(types).reject { |type| %w[deb deb-src].includes?(type) }
        return PluginResult.new(changed: false, failed: true, msg: "value of types must be one or more of: deb, deb-src. Got no match for: #{bad.join(", ")}") unless bad.empty?
      end

      # The Ansible module's `from debian.deb822 import Deb822` runs right
      # after its own argspec validation and before ANY state handling,
      # so a python3-debian-less target fails identically for
      # state=present and state=absent (and in check mode).
      if gate = python3_debian_gate
        return gate
      end

      state = @params["state"]? || "present"
      @slug = slug_for(name)
      target = File.join(SOURCES_LIST_D, "#{@slug}.sources")
      check_mode = true?(@params["_ansible_check_mode"]?)

      if state == "absent"
        return remove(target, check_mode)
      end

      add(target, check_mode)
    end

    # The Ansible module's unconditional `from debian.deb822 import Deb822`
    # (ansible-core 2.15+ through 2.19.x; devel's install_python_debian
    # auto-install path does not exist in any released core): a target
    # without python3-debian fails with missing_required_lib wording
    # before the module does anything. Probed through the same
    # interpreter resolution the boto3 gate in AwsModuleArgs uses -
    # `python3` first, then `python`, reporting sys.executable.
    private def python3_debian_gate : PluginResult?
      python = python_interpreter
      return nil unless python

      probe = Process.run(python, {"-c", "from debian.deb822 import Deb822"}, error: Process::Redirect::Close)
      return nil if probe.success?

      PluginResult.new(
        changed: false,
        failed: true,
        msg: Krikri.missing_required_lib_message("python3-debian", python),
      )
    end

    private def python_interpreter : String?
      ["python3", "python"].each do |name|
        next unless Process.find_executable(name)
        io = IO::Memory.new
        status = Process.run(name, {"-c", "import sys; print(sys.executable)"}, output: io, error: Process::Redirect::Close)
        path = io.to_s.strip
        return path if status.success? && !path.empty?
      end
      nil
    end

    # Ansible's own filename slug: reuses a legacy-normalized
    # <name>.sources (lowercased, [_\s]+ → '-', non-[a-z0-9-] stripped)
    # when one already exists on disk, else name with spaces → '-'.
    # Ansible never writes a filename containing a space.
    private def slug_for(name : String) : String
      legacy = name.downcase.gsub(/[_\s]+/, "-").gsub(/[^a-z0-9-]/, "")
      return legacy if File.exists?(File.join(SOURCES_LIST_D, "#{legacy}.sources"))
      name.gsub(' ', "-")
    end

    BOOL_FIELDS = {
      "trusted" => "Trusted", "enabled" => "Enabled", "allow_insecure" => "Allow-Insecure",
      "allow_downgrade_to_insecure" => "Allow-Downgrade-To-Insecure", "allow_weak" => "Allow-Weak",
      "pdiffs" => "Pdiffs", "by_hash" => "By-Hash", "check_date" => "Check-Date",
      "check_valid_until" => "Check-Valid-Until",
    }
    LIST_FIELDS = {
      "types" => "Types", "uris" => "URIs", "suites" => "Suites", "components" => "Components",
      "architectures" => "Architectures", "languages" => "Languages", "targets" => "Targets",
      "exclude" => "Exclude", "include" => "Include",
    }

    # Ansible.builtin.deb822_repository writes fields in ALPHABETICAL
    # ORDER BY THE UNDERLYING PARAM NAME, not by field name and not in
    # any fixed/declared order (`for key, value in sorted(params.items())`)
    # - verified directly against a ansible-playbook -vvv run's own
    # `repo:` return value, not assumed from source alone. This matters
    # for idempotency: a file Ansible itself wrote and a file this
    # plugin writes must line up byte-for-byte, or a warm rerun against
    # an already-real-Ansible-managed file would spuriously report
    # changed every time on line-order alone even though nothing
    # meaningful differs. Bool fields (all `type: bool` in the real
    # module's own argument_spec) are written as literal "yes"/"no" -
    # real APT's own deb822 sources parser (and this codebase's own
    # `true?`) both already understand "yes"/"no"/"true"/"false"
    # interchangeably, so round-tripping an already-boolean-ish param
    # value through `true?` first (rather than assuming it always
    # arrives as literal "true"/"false") stays correct either way.
    private def render_content(check_mode : Bool = false) : String
      n = @params["name"]? || raise "deb822_repository: name is required"
      fields = {} of String => String

      add_bool_fields(fields)
      add_list_fields(fields)
      add_scalar_fields(fields, n, check_mode)

      PluginHelpers::Deb822RepositoryContent.render(fields)
    end

    # Bool fields (all `type: bool` in the Ansible module's own
    # argument_spec) are written as literal "yes"/"no" - real APT's own
    # deb822 sources parser (and this codebase's own `true?`) both
    # already understand "yes"/"no"/"true"/"false" interchangeably, so
    # round-tripping an already-boolean-ish param value through `true?`
    # first (rather than assuming it always arrives as literal
    # "true"/"false") stays correct either way.
    private def add_bool_fields(fields : Hash(String, String)) : Nil
      BOOL_FIELDS.each do |param, field|
        fields[param] = "#{field}: #{true?(@params[param]?) ? "yes" : "no"}" if @params[param]?
      end
    end

    private def add_list_fields(fields : Hash(String, String)) : Nil
      LIST_FIELDS.each do |param, field|
        default = param == "types" ? "deb" : nil
        value = @params[param]? || default
        fields[param] = "#{field}: #{parse_list_param(value).join(' ')}" if value
      end
    end

    # List-typed params are documented LIST types in the Ansible module's
    # own argument_spec, so a real YAML list arrives here as a
    # JSON-array-shaped string after task-param substitution - parse it
    # with the same convention as unarchive.cr/rpm_key.cr's
    # parse_list_param (JSON array first, then comma-split for a plain
    # scalar, matching Ansible's own check_type_list backward-compat
    # behavior). ONLY valid JSON - never a Python-repr repair pass: a
    # value that merely LOOKS like a container is a plain STRING in
    # ansible-core (live-verified vs ansible-playbook 2.19.11, see
    # apt.cr's parse_package_names); a whole-value `{{ list_var }}`
    # container arg arrives as the double-quoted JSON the wire
    # serialized it to (see substitute_task_params's whole-single-span
    # comment). A naive comma-split or
    # comma→space substitution mangled a real list's brackets/quotes
    # into the rendered field.
    private def parse_list_param(raw : String?) : Array(String)
      return [] of String unless raw
      if raw.starts_with?('[')
        (Array(String).from_json(raw) rescue nil).try { |parsed| return parsed }
      end
      raw.split(",").map(&.strip).reject(&.empty?)
    end

    # The remaining single-value fields: date_max_future, the X-Repolib-
    # Name header and the resolved Signed-By value
    private def add_scalar_fields(fields : Hash(String, String), n : String, check_mode : Bool) : Nil
      if date_max_future = @params["date_max_future"]?
        fields["date_max_future"] = "Date-Max-Future: #{date_max_future}"
      end
      if (irp = @params["inrelease_path"]?) && !irp.empty?
        fields["inrelease_path"] = "Inrelease-Path: #{irp}"
      end
      fields["name"] = "X-Repolib-Name: #{n}"
      if (sb = resolve_signed_by(check_mode)) && !sb.empty?
        fields["signed_by"] = sb.starts_with?('\n') ? "Signed-By:#{sb}" : "Signed-By: #{sb}"
      end
    end

    private def resolve_signed_by(check_mode : Bool = false) : String?
      raw = @params["signed_by"]?
      return nil unless raw

      # 1. Local path — return unchanged (matches Ansible's own
      #    os.path.isfile(v) branch).
      return raw if File.exists?(raw)

      # 2. URL — fetch (redirect-aware), store as .asc (armored) or .gpg
      #    (binary) under /etc/apt/keyrings/<slug>{.asc,.gpg}, return the
      #    local path for Signed-By:
      if (scheme = URI.parse(raw).scheme) && %w[http https].includes?(scheme.downcase)
        return resolve_url_signed_by(@slug, raw, check_mode)
      end

      # 3. Inline ASCII-armored GPG key text — render as Deb822 folded
      #    multi-line value (indented with 4 spaces on each continuation
      #    line, matching Ansible's own format_multiline output).
      if raw.lstrip.starts_with?("-----BEGIN PGP")
        return format_inline_key(raw)
      end

      # 4. Key fingerprint(s) — space-normalize (commas → spaces, collapse
      #    whitespace runs) and emit on one line.
      raw.gsub(',', ' ').split.join(' ')
    end

    private def resolve_url_signed_by(slug : String, url : String, check_mode : Bool) : String
      keyring_path_asc = File.join(KEYRINGS_DIR, "#{slug}.asc")
      keyring_path_gpg = File.join(KEYRINGS_DIR, "#{slug}.gpg")

      # In check mode, skip the network download entirely — just return
      # the expected keyring path based on any existing file (default to
      # .asc since we can't know whether the remote key is armored without
      # fetching it). The content diff against a non-existent keyring will
      # correctly show "changed=true".
      if check_mode
        return keyring_path_asc unless File.exists?(keyring_path_gpg)
        return keyring_path_gpg
      end

      Dir.mkdir_p(KEYRINGS_DIR)
      File.chmod(KEYRINGS_DIR, 0o755) if File.exists?(KEYRINGS_DIR)

      # Download to a temp file to detect armored vs binary content
      tmp_path = "#{KEYRINGS_DIR}/.#{slug}.#{Process.pid}.tmp"
      download_binary(url, tmp_path)

      # Detect ASCII-armored content by checking the first bytes
      armored = File.open(tmp_path, "r") { |fval| (fval.gets(60) || "").starts_with?("-----BEGIN PGP") }

      ext = armored ? ".asc" : ".gpg"
      keyring_path = File.join(KEYRINGS_DIR, "#{slug}#{ext}")

      # Check if the keyring content actually changed (idempotency) —
      # avoids rewriting the keyring on every run when the key hasn't
      # changed upstream.
      changed = !File.exists?(keyring_path) || File.read(keyring_path) != File.read(tmp_path)
      if changed
        File.rename(tmp_path, keyring_path)
        File.chmod(keyring_path, 0o644)
      else
        File.delete(tmp_path) if File.exists?(tmp_path)
      end

      keyring_path
    end

    private def format_inline_key(raw : String) : String
      # Ansible's own format_multiline: strips whitespace, replaces
      # empty lines with '.', indents each line with 4 spaces, then
      # prepends a leading newline so the whole block becomes a Deb822
      # folded continuation value after "Signed-By:".
      folded = raw.strip.lines.map do |line|
        stripped = line.strip
        "    #{(stripped.empty? ? "." : stripped)}"
      end
      "\n" + folded.join("\n")
    end

    # Binary-safe download with redirect following — response.body_io
    # streamed straight to disk. Delegates to the shared HTTPDownload
    # helper (also used by get_url.cr) so the two plugins share one
    # redirect-tracking implementation and can't drift apart. Many real
    # key URLs (keys.openpgp.org, packages.*) redirect at least once, and
    # without redirect following every such key download silently fails.
    private def download_binary(url : String, dest : String) : Nil
      PluginHelpers::HTTPDownload.download(url, dest)
    end

    private def add(target : String, check_mode : Bool) : PluginResult
      new_content = render_content(check_mode)
      existing = File.exists?(target) ? File.read(target) : nil
      changed = existing != new_content

      # ansible-core 2.19.11 deb822_repository exits (both success
      # exits, present AND absent, live-verified in check mode via
      # register + to_json) with exactly:
      #   exit_json(repo=repo, changed=changed, dest=sources_filename,
      #             key_filename=signed_by_filename)
      # - no msg, and `repo` FIRST (it is the file content). key_filename
      # is the downloaded keyring path only when signed_by was a URL
      # (a local path or inline key leaves it None); the absent exit
      # leaves it at the last probed ext, i.e. always
      # /etc/apt/keyrings/<slug>.gpg.
      if check_mode
        return PluginResult.new(changed: changed, failed: false, repo: new_content, dest: target,
          key_filename: url_keyring_filename, key_order: DEB822_ORDER)
      end

      unless changed
        return PluginResult.new(changed: false, failed: false, repo: new_content, dest: target,
          key_filename: url_keyring_filename, key_order: DEB822_ORDER)
      end

      Dir.mkdir_p(SOURCES_LIST_D)
      File.write(target, new_content)
      apply_owner_group_mode(target, nil, nil, @params["mode"]? || "0644")

      PluginResult.new(changed: true, failed: false, repo: new_content, dest: target,
        key_filename: url_keyring_filename, key_order: DEB822_ORDER)
    end

    # key_filename for the present-path exit: a real path only when
    # signed_by was a URL (the module then hands back the keyring it
    # downloaded); any other signed_by form leaves it None.
    private def url_keyring_filename : String?
      return nil unless url_signed_by?
      keyring_filename
    end

    private def url_signed_by? : Bool
      raw = @params["signed_by"]?
      return false unless raw
      scheme = URI.parse(raw).scheme
      !scheme.nil? && %w[http https].includes?(scheme.downcase)
    end

    # The keyring path the URL download produced (prefer the binary .gpg
    # the way resolve_url_signed_by's own check-mode guess does).
    private def keyring_filename : String
      gpg = File.join(KEYRINGS_DIR, "#{@slug}.gpg")
      asc = File.join(KEYRINGS_DIR, "#{@slug}.asc")
      File.exists?(gpg) ? gpg : asc
    end

    private def remove(target : String, check_mode : Bool) : PluginResult
      changed = false

      if File.exists?(target)
        File.delete(target) unless check_mode
        changed = true
      end

      # Ansible's state=absent ALSO removes the downloaded
      # signed_by keyrings (<slug>.asc / <slug>.gpg under
      # /etc/apt/keyrings/) - independently of whether the .sources file
      # itself exists - and reports changed if either side was removed.
      {"asc", "gpg"}.each do |ext|
        keyring = File.join(KEYRINGS_DIR, "#{@slug}.#{ext}")
        next unless File.exists?(keyring)
        File.delete(keyring) unless check_mode
        changed = true
      end

      # Real absent exit (verified from module source, matching the
      # live-verified shape): repo=None, dest still reported, and
      # key_filename left at the last probed ext (.gpg) even when
      # nothing existed - the "already absent" no-op carries the SAME
      # shape, no msg.
      PluginResult.new(changed: changed, failed: false, repo: nil, dest: target,
        key_filename: File.join(KEYRINGS_DIR, "#{@slug}.gpg"), key_order: DEB822_ORDER)
    end
  end
end

# Plugin entry point
input = STDIN.gets_to_end
config = JSON.parse(input)

plugin = Krikri::Deb822RepositoryPlugin.new(config)
plugin.run
