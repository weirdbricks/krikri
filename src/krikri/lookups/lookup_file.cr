require "json"

module Krikri
  module VariableSubstitutor
    # File-path-based lookups (file, pipe, template, dict, lines, fileglob,
    # ini/csvfile parsers, shared path resolution) - extracted verbatim from
    # expression_evaluator.cr (lookup-dispatch split).
    class ExpressionEvaluator
      private def evaluate_lookup_file(lookup_type : String?, parts : Array(String), kwargs : Array(String)) : String?
        # SECURITY NOTE (deliberate, compatibility-preserving): file/pipe/
        # env lookups read controller files, EXECUTE controller commands,
        # and read controller env vars with no gating beyond playbook
        # authorship - exactly Ansible's trust boundary (playbooks
        # are trusted input; an untrusted-author playbook is a lost game
        # in Ansible too). Not a defect to gate here; doing so would
        # break roles that legitimately use lookup('pipe', ...).
        case lookup_type
        when "file"
          lookup_file(parts)
        when "pipe"
          lookup_pipe(parts, kwargs)
        when "template"
          lookup_template(parts, kwargs)
        when "password"
          # lookup('password', '/path/to/file [length=N chars=abc...]')
          # - Ansible's own password lookup plugin: generates a
          # random password ONCE and persists it to *path* (on the
          # CONTROLLER) so repeated runs/lookups return the SAME value;
          # any later run finds the file and just reads it back rather
          # than generating a new one. The whole argument is one
          # space-separated string (path first, then key=value options),
          # not comma-separated params like every other lookup type
          # here - matches Ansible's own free-form parsing for this
          # specific lookup.
          raw_arg = parts[1]?.try { |part| evaluate(part.strip) }
          return "undefined" unless raw_arg
          evaluate_password_lookup(raw_arg)
        when "dict"
          lookup_dict(parts)
        end
      end

      private def lookup_file(parts : Array(String)) : String
        # lookup('file', path) - reads a file's content from the
        # CONTROLLER (same controller-side rule as env/url/first_found
        # above), stripped of a single trailing newline (Ansible's own file lookup plugin behavior - it splits on
        # newlines and rejoins with the requested separator, default
        # "\n", which drops exactly one trailing blank line same as a
        # plain `.rstrip()` would for the common no-embedded-blank-
        # lines case this covers).
        path = parts[1]?.try { |part| evaluate(part.strip) }
        return "undefined" unless path
        resolved_path = resolve_lookup_path(path)
        begin
          File.read(resolved_path).chomp
        rescue
          # Ansible's `file` lookup plugin RAISES when the file
          # can't be read ("Unable to access the file '<path>': File
          # not found"), failing the whole task's arg finalization
          # rather than continuing with a placeholder - unlike a
          # genuinely-undefined VARIABLE reference, which is lenient by
          # design elsewhere in this evaluator. Falling back to the
          # "undefined" sentinel here instead let a missing file's
          # literal text "undefined" get written straight into real
          # task output - found via andrewrothstein.ssh-user-keygen's
          # own `lookup('file', ssh_user_pubkey)` on a host with no
          # `~/.ssh/id_rsa.pub`: Ansible fails the task, this
          # engine wrote the string "undefined" into `~/.ssh/
          # authorized_keys` as if it were a real public key. Mirrors
          # the url lookup's own HTTP-failure raise just above (same
          # `rescue ex` in the executor turns this into "Finalization
          # of task args ... failed", matching Ansible's message
          # shape).
          raise "The lookup plugin 'file' failed: Unable to access the file '#{path}': File not found. Use -vvvvv to see paths searched."
        end
      end

      private def lookup_pipe(parts : Array(String), kwargs : Array(String) = [] of String) : String
        # lookup('pipe', command) - runs *command* via the shell ON
        # THE CONTROLLER (not the target - matches Ansible's own
        # pipe lookup plugin, which always executes locally) and
        # returns its stdout, stripped of a trailing newline.
        command = parts[1]?.try { |part| evaluate(part.strip) }
        return "undefined" unless command
        output = IO::Memory.new
        status = Process.run("/bin/sh", ["-c", command], output: output, error: Process::Redirect::Close)
        # Ansible's pipe lookup RAISES on a non-zero exit code
        # ("lookup_plugin.pipe(%s) returned %d", raised regardless of
        # how much stdout the command already flushed - its own
        # pipe.py discards the captured output on the failure branch),
        # failing the task's arg finalization. The old lenient
        # "undefined" sentinel here let a failing `lookup('pipe',
        # 'ssh-keyscan ...')` (ajeleznov.manage-known-hosts, round
        # 90013: the scanned hostnames don't resolve) feed the literal
        # text "undefined" into known_hosts's `key:` as if it were a
        # real key, so the play ran seven tasks past Ansible's
        # hard stop. errors='ignore' - Ansible's generic lookup
        # error option, verified live against 2.19.4 (`lookup('pipe',
        # 'exit 7', errors='ignore')` renders empty rather than
        # failing) - keeps the old empty-result behavior.
        return "" if !status.success? && first_found_errors_ignore?(kwargs)
        raise PipeLookupError.new(
          "The lookup plugin 'pipe' failed: lookup_plugin.pipe(#{command}) returned #{status.exit_code}") unless status.success?
        output.to_s.chomp
      rescue e : PipeLookupError
        raise e
      rescue
        "undefined"
      end

      private def lookup_template(parts : Array(String), kwargs : Array(String)) : String
        # lookup('template', path[, template_vars=dict(...)]) - renders
        # a local (controller-side) `.j2` file through the same Crinja
        # pipeline `template:` tasks use, against this expression's own
        # vars, and returns the rendered text with one trailing newline
        # stripped (matches Ansible's own template lookup plugin,
        # which is explicitly documented to strip a single trailing
        # newline the way Jinja2's own template rendering leaves one).
        path = parts[1]?.try { |part| evaluate(part.strip) }
        return "undefined" unless path
        resolved_path = resolve_template_lookup_path(path)

        # template_vars=dict(...) - Ansible's own template lookup
        # plugin merges this kwarg's dict into the vars available to
        # the rendered template, ON TOP of (never replacing) the
        # calling context's own vars - the whole point of the kwarg is
        # to hand the template a few extra values (bimdata.ferm's own
        # get_vars.j2, rendered 4 times with a different app_name:/
        # var_type: pair each time via this exact kwarg) without
        # requiring a Ansible variable of that name to exist.
        # Entirely ignored before - the template rendered with
        # `app_name`/`var_type` undefined, so its own `lookup('varnames',
        # '^' ~ app_name ~ ...)` pattern matched nothing regardless of
        # which of the 4 calls it was, silently producing an empty
        # result for all of them instead of each one's own distinct set.
        template_vars_part = kwargs.find(&.strip.starts_with?("template_vars="))
        render_vars = @vars
        if template_vars_part
          dict_expr = template_vars_part.strip.sub(/^template_vars=/, "")
          extra = render_via_jinja_value(dict_expr).try(&.as_h?)
          if extra && !extra.empty?
            render_vars = @vars.dup
            extra.each { |key, value| render_vars[key] = value }
          end
        end

        begin
          template_content = File.read(resolved_path)
          # A `#jinja2: key:value, ...` directive on the template's very
          # first line (Ansible's own per-template Jinja2 config
          # override) is metadata for the renderer, not template
          # content - Ansible strips it before rendering.
          # TemplateActionPlugin already does this for the `template:`
          # module; this lookup plugin never did, so the directive
          # leaked into the returned text as a literal "#jinja2: ..."
          # line - fatal for bimdata.ferm's own `| from_json` pipeline
          # right after this lookup (its own get_vars.j2 opens with
          # `#jinja2: lstrip_blocks: True`), which saw that line
          # prepended to the real JSON and raised "invalid JSON input".
          first_line_end = template_content.index('\n')
          first_line = first_line_end ? template_content[0...first_line_end] : template_content
          if first_line.strip.starts_with?("#jinja2:")
            template_content = first_line_end ? template_content[(first_line_end + 1)..] : ""
          end

          renderer = render_vars.same?(@vars) ? jinja_renderer : JinjaRenderer.new(render_vars, @decode)
          renderer.render(template_content).chomp
        rescue
          "undefined"
        end
      end

      private def lookup_dict(parts : Array(String)) : String
        # lookup('dict', {'a': 1, 'b': 2}) - Ansible's own dict
        # lookup plugin: one dict term in, a list of {key:, value:}
        # dicts out (one per top-level key) - identical shape to the
        # dict2items filter. Always returns real JSON array text
        # (not Ansible's own default comma-joined-scalar
        # behavior) - these list-producing lookups are almost always
        # consumed as a loop: source or piped through | list/|
        # flatten, both of which need a real array, not joined text.
        source = parts[1]?.try { |part| evaluate(part.strip) }
        return "undefined" unless source
        dict = (JSON.parse(source) rescue nil).try(&.as_h?)
        return "undefined" unless dict
        dict.map { |k, v| {"key" => JSON::Any.new(k), "value" => v} }.to_json
      end

      private def lookup_lines(parts : Array(String)) : String
        # lookup('lines', command) - Ansible's own lines lookup:
        # runs *command* on the CONTROLLER (same as pipe above) but
        # returns its output SPLIT into a list of lines, not one
        # joined string.
        command = parts[1]?.try { |part| evaluate(part.strip) }
        return "undefined" unless command
        begin
          output = IO::Memory.new
          status = Process.run("/bin/sh", ["-c", command], output: output, error: Process::Redirect::Close)
          return "undefined" unless status.success?
          output.to_s.split('\n').reject(&.empty?).to_json
        rescue
          "undefined"
        end
      end

      # lookup('ansible.builtin.fileglob', pattern, wantlist=True) - the
      # FUNCTION-call form of the same lookup already handled as a
      # FILTER in FilterEngine (`map('fileglob')`) - Ansible
      # returns the list of existing files matching the glob (empty
      # list, not an error, when none match). Entirely unimplemented
      # here before - fell through every case to the "undefined"
      # fallback, and `"undefined" | length > 0` is true (a 9-char
      # string), so a per-loop-item `when: lookup('ansible.builtin.
      # fileglob', role_path ~ '/vars/' ~ item, wantlist=True) | length >
      # 0` guard meant to skip a nonexistent vars file (PowerDNS.pdns's
      # own "OS-specific variables, generic to specific" idiom) always
      # evaluated true instead, running `include_vars:` on a file that
      # doesn't exist and failing the whole task where Ansible just
      # skips it. Pulled out of #evaluate_lookup_list's own case dispatch
      # to keep that method's cyclomatic complexity under the repo's
      # threshold - purely a split, no behavior change.
      private def evaluate_lookup_fileglob(parts : Array(String)) : String
        pattern = parts[1]?.try { |part| evaluate(part.strip) }
        return "[]" unless pattern
        return lookup_fileglob_glob(pattern) if pattern.starts_with?('/')

        # A RELATIVE pattern does not glob against the process CWD -
        # Ansible's fileglob lookup dwims it against the role/play search
        # stack (ansible.plugins.lookup.fileglob's find_file_in_search_
        # path, probed live against 2.19.4: from a role task, 'tasks/*.
        # yml' finds <role>/tasks/*.yml, 'vars/*.yml' finds <role>/vars/*.
        # yml, a bare 'c.yml' finds <role>/c.yml, and an unmatched name
        # falls through to the play dir). pluggero.common_pkgs and
        # pluggero.user_setup both drive `include_tasks:` through
        # `lookup('ansible.builtin.fileglob', 'tasks/*.yml').split(',')
        # | reject(...) | sort` - globbed against the CWD the list came
        # back empty, so the whole loop collapsed to one skipped task
        # where Ansible expands it into the role's per-play task
        # files. Candidates are probed files-subdir-first per root
        # (real fileglob's own 'files' search-path preference), first
        # root yielding matches wins.
        roots = default_first_found_roots
        roots.each do |root|
          [File.join(root, "files", pattern), File.join(root, pattern)].each do |candidate|
            found = lookup_fileglob_glob(candidate)
            return found unless found == "[]"
          end
        end
        "[]"
      end

      private def lookup_fileglob_glob(pattern : String) : String
        Dir.glob(pattern).select { |path| File.file?(path) }.sort!.to_json
      end

      private def evaluate_lookup_file_parsers(lookup_type : String?, parts : Array(String), kwargs : Array(String)) : String?
        case lookup_type
        when "csvfile"
          # lookup('csvfile', 'key file=data.csv delimiter=, col=1') -
          # Ansible's own csvfile lookup: finds the row whose first
          # column matches *key*, returns the value at column `col=`
          # (default 1) from that row. No quoted-field support (a
          # narrower CSV parser than Python's own csv module) - real-
          # world use of this lookup is almost always a simple lookup
          # table with no embedded delimiters.
          raw_arg = parts[1]?.try { |part| evaluate(part.strip) }
          return "undefined" unless raw_arg
          evaluate_csvfile_lookup(raw_arg, kwargs)
        when "ini"
          # lookup('ini', 'value section=section1 file=file.ini') -
          # Ansible's own ini lookup: reads `value` under `section=`
          # (default DEFAULT) from a controller-side INI file.
          raw_arg = parts[1]?.try { |part| evaluate(part.strip) }
          return "undefined" unless raw_arg
          evaluate_ini_lookup(raw_arg, kwargs)
        when "unvault"
          # lookup('unvault', 'path/to/vaultfile') - Ansible's own
          # unvault lookup: decrypts a vault-encrypted FILE (on the
          # controller) using the RUN's own configured vault secret
          # (Vault.password, set once from --vault-password-file/
          # --ask-vault-pass) - distinct from the `unvault` FILTER
          # above, which takes an explicit secret as a filter argument
          # instead.
          path = parts[1]?.try { |part| evaluate(part.strip) }
          password = Vault.password
          return "undefined" unless path && password
          begin
            Vault.decrypt(File.read(path), password)
          rescue
            "undefined"
          end
        else
          # Reached only by lookup types with no handler above AND no
          # role-local/playbook-adjacent `lookup_plugins/<name>.py`
          # (evaluate_custom_python_lookup got the custom ones first).
          # Previously this branch also swallowed the custom Python
          # plugins themselves, silently degrading every role shipping
          # one (manala.cron's own manala_cron_files_env.py) to
          # "undefined".
          # (No handler above matches: fall through with nil.)
        end
      end

      # lookup('file'|'template'|'password', path) all name a CONTROLLER-side
      # path that - inside a role - Ansible resolves through
      # find_file_in_search_path's own two-probe search order: for each
      # search-path directory it probes `<dir>/files/<term>` first, then
      # `<dir>/<term>` directly. The `files/` prefix is a SEARCH HINT, not
      # something forcibly prepended to every relative term - a caller's own
      # relative path that already contains enough subdirectory components
      # (e.g. ansible-lockdown.windows_11_cis's vars/main.yml doing
      # `lookup('file', './templates/banner.txt')` against a file that lives
      # at the role root's templates/, round 900733) resolves under the role
      # root itself in ansible-playbook. Probing files/-prefixed first
      # keeps the conventional bare-filename case (`lookup('file', 'foo.txt')`
      # -> `<role>/files/foo.txt`) identical to its previous behavior; the
      # role-root fallback only kicks in where the files/-prefixed candidate
      # doesn't exist, i.e. where the old code 404'd. An absolute path, or a
      # relative one outside any role context, passes through unchanged.
      private def resolve_lookup_path(path : String) : String
        return path if path.starts_with?('/')
        role_path = @vars["role_path"]?.try(&.as_s?)
        return path unless role_path
        files_prefixed = File.join(role_path, "files", path)
        File.exists?(files_prefixed) ? files_prefixed : File.join(role_path, path)
      end

      # The template lookup's own search, mirroring real
      # find_file_in_search_path(variables, 'templates', term): the
      # role's templates/ dir FIRST, then files/, then the role root.
      # resolve_lookup_path above (files/-only) is correct for the file
      # lookup but left lookup('template', 'redis.conf.j2') unable to
      # see the role's own template - its missing-file rescue then
      # yielded the literal "undefined" that blockinfile wrote into
      # /etc/redis/redis.conf (hifis.redis, round 1300014).
      private def resolve_template_lookup_path(path : String) : String
        return path if path.starts_with?('/')
        role_path = @vars["role_path"]?.try(&.as_s?)
        return path unless role_path
        candidates = [
          File.join(role_path, "templates", path),
          File.join(role_path, "files", path),
          File.join(role_path, path),
        ]
        candidates.find { |candidate| File.exists?(candidate) } || File.join(role_path, path)
      end
    end
  end
end
