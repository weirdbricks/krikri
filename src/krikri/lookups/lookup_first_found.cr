require "json"

module Krikri
  module VariableSubstitutor
    # The `first_found` lookup: param parsing, search-path resolution and
    # evaluation - extracted verbatim from expression_evaluator.cr
    # (lookup-dispatch split).
    class ExpressionEvaluator
      # first_found's dict/list params value must reach evaluate_first_found
      # RAW (nested {{ }} intact): resolve_plus_operand's generic
      # re-templating renders nested templates LENIENTLY, which would turn
      # an unresolvable candidate like '{{ ansible_facts.os_family }}.yml'
      # into the literal "undefined.yml" before the strict per-entry
      # rendering in evaluate_first_found ever sees it. A scalar/string
      # params (itself a template) keeps the generic path.
      private def first_found_params(part : String) : JSON::Any
        expr = part.strip
        raw_resolved = @lookup.resolve(expr)
        if raw_resolved && (raw_resolved.raw.is_a?(Array) || raw_resolved.raw.is_a?(Hash))
          return raw_resolved
        end
        # An INLINE dict literal (`lookup('first_found', {'files': var_files,
        # 'paths': ['vars']})`, AerisCloud.vault's own idiom) is neither a
        # plain variable reference (resolve above misses) nor anything
        # resolve_plus_operand understands (its literal branch only knows
        # `[...]` arrays) - it used to resolve to a nil JSON::Any, which
        # evaluate_first_found then collapsed to the literal text
        # "undefined" ("include_vars: file not found: undefined") no matter
        # what candidate files actually existed. Parse it ourselves,
        # resolving each VALUE through the same machinery a `params`
        # variable's own dict would get - which keeps nested `{{ }}`
        # candidate templates RAW for evaluate_first_found's strict
        # per-entry rendering (see its own comment) instead of letting
        # them render leniently to "undefined.yml" here.
        if expr.starts_with?('{') && expr.ends_with?('}') &&
           (dict = first_found_dict_literal(expr))
          return dict
        end
        resolve_plus_operand(expr)
      end

      # Parses a first_found params DICT LITERAL (`{'files': ...,
      # 'paths': ...}`) from expression text, resolving every value
      # recursively. A value can be a nested dict/list literal, a quoted
      # string (kept RAW - a candidate like '{{ ansible_distribution
      # }}.yml' must survive unrendered for the strict per-entry rendering
      # in evaluate_first_found), or any plain reference/expression, which
      # resolves through #first_found_params itself (so a task-local
      # `var_files` list variable comes in as the real, still-templated
      # array). nil when the text isn't a parseable dict literal - the
      # caller then keeps its old fallback path.
      private def first_found_dict_literal(expr : String) : JSON::Any?
        inner = expr[1..-2].strip
        return nil if inner.empty?

        hash = Hash(String, JSON::Any).new
        split_top_level_commas(inner).each do |entry|
          split = split_first_top_level_colon(entry.strip)
          return nil unless split
          key, value = split

          key = quoted_string_literal(key).try(&.as_s?) || key
          hash[key] = first_found_params(value)
        end
        JSON::Any.new(hash)
      rescue
        nil
      end

      # Splits a dict literal's `key: value` entry on the FIRST top-level
      # colon - one outside quotes/brackets, so a value containing a colon
      # (a templated string, a slice) or a bracketed key never mis-splits.
      private def split_first_top_level_colon(entry : String) : {String, String}?
        depth = 0
        quote : Char? = nil
        entry.each_char_with_index do |char, i|
          if q = quote
            quote = nil if char == q
            next
          end
          case char
          when '\'', '"'     then quote = char
          when '(', '[', '{' then depth += 1
          when ')', ']', '}' then depth -= 1
          when ':'
            return {entry[0...i].strip, entry[(i + 1)..].strip} if depth == 0
          end
        end
        nil
      end

      # Ansible's first_found: the first `files:` entry that exists
      # under any `paths:` entry (both lists, in order - outer loop over
      # files, inner over paths, matching Ansible's own search
      # order), each entry independently rendered since it commonly still
      # carries its own `{{ }}` markers (linux-system-roles/timesync's
      # `"{{ ansible_facts['distribution'] }}_{{ ansible_facts
      # ['distribution_version'] }}.yml"`) - unlike a bare expression,
      # these came from a task's own `vars:` dict and were never passed
      # through VarSubstitutor#substitute's mustache-span extraction, only
      # this evaluator's bare-expression path, so re-rendering here is the
      # first point either ever sees `{{ }}` syntax.
      #
      # Two real, related bugs found benchmarking geerlingguy.docker/
      # mysql/postgresql/php, which all share this exact idiom
      # (`lookup('first_found', params)` with a task `vars: params:
      # {files: [...], paths: [...]}`), fixed together since both are
      # "a relative paths: entry means role-relative, not cwd-relative":
      #   1. `paths:` omitted entirely used to default unconditionally to
      #      "." (plain cwd) - Ansible's own default for a role-scoped
      #      first_found is the role's files/templates/vars dirs.
      #   2. `paths: ['vars']` (this idiom's actual common spelling - the
      #      docker/mysql/postgresql roles all give an explicit relative
      #      "vars") was joined straight against cwd too - "vars/Ubuntu.yml"
      #      against the *process's* cwd, essentially never the role dir a
      #      `ansible-playbook` run resolves it against.
      # Both now go through resolve_first_found_root, which prepends
      # `role_path` (already sitting in @vars as a magic var - see
      # TaskExecutor#build_vars_context) to any relative entry, absolute
      # entries and non-role usage passing through unchanged. Resolves
      # entirely against the controller's own filesystem - Ansible's
      # first_found always does (it's how role vars files that live on the
      # controller, not the managed host, get found).
      private def evaluate_first_found(params : JSON::Any) : String
        params_hash = params.as_h?
        # Real first_found accepts two more term shapes besides the
        # {files:, paths:, skip:} DICT form: a plain LIST of candidate
        # filenames (recursively flattened by _process_terms) and a
        # single STRING filename (wrapped as a one-element files list).
        # A variable name resolving to either previously hit
        # `as_h? || return "undefined"` and first_found "found nothing"
        # no matter what actually existed - found via nephelaiio.devtools
        # 's own `loop: "{{ q('first_found', include_files,
        # errors='ignore') }}"` with `vars: include_files: [...]`.
        # Both synthesize the dict the dict-form handling below walks:
        # a list/string term carries no paths:/skip: of its own, so the
        # no-paths: default search stack applies.
        unless params_hash
          case params.raw
          when Array, String
            params_hash = {"files" => params} of String => JSON::Any
          end
        end
        return "undefined" unless params_hash

        renderer = VarSubstitutor.new(vars: @vars, host_name: "localhost")
        files = lookup_array(render_first_found_param(params_hash["files"]?, renderer))
        paths_raw = params_hash["paths"]?
        paths = paths_raw ? lookup_array(render_first_found_param(paths_raw, renderer)) : nil
        # Each candidate entry renders STRICTLY (undefined variable in an
        # entry fails the calling task, it does not silently render to the
        # "undefined" sentinel and lose to a later `default.yml` fallback):
        # Ansible templates the lookup's args strictly before first_found
        # ever sees them (verified live against 2.19.4 - `include_vars: "{{
        # lookup('first_found', params) }}"` with `files: ['{{ ansible_facts
        # .os_family }}.yml', 'default.yml']` and no gathered facts fails the
        # include_vars task itself with "object of type 'dict' has no
        # attribute 'os_family'", it does not fall through to default.yml).
        # `skip: true` (real first_found's own skip param) is the only thing
        # that turns any lookup error into "no match" - same rule as the
        # with_first_found: KEYWORD form's loop_first_found_skip handling.
        skip_errors = params_hash["skip"]?.try(&.as_bool?) == true
        begin
          # An explicit paths: sub-key resolves through the usual
          # dual-base expansion (role root + role/tasks - see
          # resolve_first_found_roots); the NO-paths: case uses the
          # probed real search stack instead (default_first_found_roots).
          rendered_paths = if paths_raw
                             paths.not_nil!.flat_map { |path_entry| resolve_first_found_roots(renderer.substitute(path_entry.as_s? || "", strict: true)) }
                           else
                             default_first_found_roots
                           end

          files.each do |file_entry|
            rendered_file = renderer.substitute(file_entry.as_s? || "", strict: true)
            rendered_paths.each do |path|
              candidate = File.join(path, rendered_file)
              return candidate if File.exists?(candidate)
            end
          end
        rescue ex : UndefinedVariableError
          raise ex unless skip_errors
        end

        return "[]" if skip_errors
        raise FirstFoundLookupError.new(
          "The lookup plugin 'first_found' failed: No file was found when using first_found.")
      end

      # A first_found params dict's own `files:`/`paths:` values can be
      # TEMPLATED SCALARS (`files: "{{ __first_found | map('regex_replace',
      # '$', '.yml') | list }}"`, idiv_biodiversity.systemd_timesyncd's own
      # idiom) rather than literal YAML lists. The dict deliberately reaches
      # #first_found_params RAW (nested {{ }} intact - see its own comment),
      # so such a value arrives here as the unrendered STRING, and the old
      # bare `as_a?` in #lookup_array silently dropped it as an EMPTY
      # candidate list - first_found "found nothing" no matter what files
      # actually existed, and the include_vars: path got the "undefined"
      # sentinel as its filename ("include_vars: file not found: undefined")
      # where Ansible (verified live against 2.19.4) templates the whole
      # lookup term before the plugin sees it and finds the file. Render a
      # string value STRICTLY (an undefined variable inside it fails the
      # calling task, same as any other candidate) and parse the rendered
      # list back out; a scalar that survives rendering as a plain string
      # wraps as a one-element list, matching real first_found's treatment
      # of a lone filename. Non-strings (real YAML lists) pass through.
      private def render_first_found_param(value : JSON::Any?, renderer : VarSubstitutor) : JSON::Any?
        str = value.try(&.as_s?) || return value
        rendered = Krikri.parse_json_or_python_literal(renderer.substitute(str, strict: true))
        rendered.as_a? ? rendered : JSON::Any.new([rendered])
      end

      # The lookup FORM's (not the with_first_found: keyword form's) own
      # no-`paths:` default search stack, in order. Probed live against
      # ansible-core 2.19.4 (this project's benchmark baseline) with a
      # minimal role - a single `lookup('first_found', findme)` debug
      # task, one candidate name, exactly one existing file per probe:
      #
      #   role ROOT file only          -> FOUND (role root)
      #   role tasks/ file only        -> FOUND (role root/tasks)
      #   role root + tasks/ both      -> role ROOT wins
      #   role vars/ file only         -> NOT FOUND
      #   role files/ file only        -> NOT FOUND
      #   role templates/ file only    -> NOT FOUND
      #   play-dir file only           -> FOUND (play basedir, last resort)
      #
      # i.e. files/, templates/, and vars/ are NOT part of the no-paths:
      # search at all - that per-subdir behavior belongs to the
      # with_first_found: KEYWORD form, which picks its subdir from the
      # task's own action name (the Ansible module's
      # `subdir` selection) and searches via the same
      # DataLoader#path_dwim_relative_stack the keyword form's
      # TaskExecutor#resolve_first_found_path already mirrors. The old
      # ["files", "tasks", "templates", "vars", "."] root list made the
      # lookup form find a same-named vars/ file Ansible never
      # would: Frzk.chrony's own `include_tasks: "{{ lookup('
      # first_found', findme) }}"` (no paths:, files list containing
      # "Debian.yml") picked up the role's vars/Debian.yml - a VARS
      # mapping, not a task list - and died "Included tasks file must be
      # a YAML list" where Ansible included tasks/Linux.yml.
      private def default_first_found_roots : Array(String)
        roots = [] of String
        if role_path = @vars["role_path"]?.try(&.as_s?)
          roots << role_path
          roots << File.join(role_path, "tasks")
        end
        if pb_dir = @vars["playbook_dir"]?.try(&.as_s?)
          pb_dir = File.expand_path(pb_dir)
          roots << pb_dir unless roots.includes?(pb_dir)
        end
        roots << "." if roots.empty?
        roots
      end

      # A relative first_found `paths:` entry can resolve against EITHER
      # of two different real-Ansible bases depending on the idiom a
      # role happens to use, and there's no way to tell which from the
      # path text alone - both are tried, in this order, first match
      # wins:
      #  1. The current role's own ROOT directory (`role_path`, a magic
      #     var - see TaskExecutor#build_vars_context) - correct for
      #     `paths: ['vars']`/`paths: ['files']` (geerlingguy.docker/
      #     mysql/postgresql/php's own style).
      #  2. The directory of the task file that's DOING the lookup -
      #     approximated here as `role_path/tasks` (the overwhelmingly
      #     common location for a role's own tasks/main.yml; a deeper
      #     included tasks file would need the actual including file's
      #     directory, not available to this evaluator - not chased
      #     further without a real repro needing it) - correct for
      #     `paths: ['../vars']` (buluma.confluence's own style,
      #     Ansible resolves this relative to tasks/, one level BELOW
      #     role_path, not relative to role_path itself). Found live
      #     benchmarking buluma.confluence (round 165): `paths: ['../
      #     vars']` against `role_path` alone resolved to role_path's
      #     own PARENT's "vars" dir (one level too far up) - never
      #     found the real per-OS vars file ansible-playbook found
      #     via base 2, so include_vars: always got "undefined".
      # An absolute entry, or any entry when there's no enclosing role,
      # passes through unchanged (base 1 only, base 2 skipped - normalizing
      # `role_path` itself as ".." there would be meaningless without one).
      private def resolve_first_found_roots(path : String) : Array(String)
        return [path] if path.starts_with?("/")
        role_path = @vars["role_path"]?.try(&.as_s?)
        return [path] unless role_path

        [File.join(role_path, path), Path.new(role_path, "tasks", path).normalize.to_s]
      end
    end
  end
end
