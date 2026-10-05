require "json"
require "http/client"
require "uri"

module Krikri
  module VariableSubstitutor
    # Scalar-returning lookups (config/env, inventory_hostnames, url, vars) -
    # extracted verbatim from expression_evaluator.cr (lookup-dispatch split).
    class ExpressionEvaluator
      # Defaults matching ansible-core 2.19's own constants when no
      # ansible.cfg / env override is set. Only the options real roles
      # actually look up (buluma.multi's COLOR_* / DEFAULT_* / RETRY_*)
      # are covered; anything else returns "" rather than inventing a value.
      private def ansible_config_value(name : String) : String
        name_up = name.upcase
        ansible_color_config_value(name_up) || ansible_default_config_value(name_up) ||
          # Honour a matching ANSIBLE_<NAME> env var when present (real
          # Ansible's own resolution order: env > cfg > default).
          ENV["ANSIBLE_#{name_up}"]? || ""
      end

      private def ansible_color_config_value(name_up : String) : String?
        case name_up
        when "COLOR_OK"                    then "green"
        when "COLOR_CHANGED"               then "yellow"
        when "COLOR_SKIP"                  then "cyan"
        when "COLOR_UNREACHABLE"           then "bright red"
        when "COLOR_ERROR", "COLOR_FAILED" then "red"
        when "COLOR_DEBUG"                 then "dark gray"
        when "COLOR_VERBOSE"               then "blue"
        when "COLOR_WARN"                  then "bright purple"
        end
      end

      private def ansible_default_config_value(name_up : String) : String?
        case name_up
        when "DEFAULT_BECOME_USER" then "root"
        when "DEFAULT_ROLES_PATH"  then "~/.ansible/roles:/usr/share/ansible/roles:/etc/ansible/roles"
        when "DEFAULT_HOST_LIST"   then "/etc/ansible/hosts"
        when "RETRY_FILES_SAVE_PATH"
          ""
        when "DEFAULT_TIMEOUT" then "10"
        when "DEFAULT_FORKS"   then "5"
        end
      end

      private def evaluate_lookup_scalar(lookup_type : String?, parts : Array(String), kwargs : Array(String), query_mode : Bool = false) : String?
        case lookup_type
        when "first_found"
          params = parts[1]?.try { |part| first_found_params(part) }
          return "undefined" unless params
          begin
            evaluate_first_found(params)
          rescue ex : FirstFoundLookupError | UndefinedVariableError
            # The generic lookup `errors='ignore'` option: same
            # empty-result tolerance the query()/with_ path already
            # honors (real Ansible swallows the lookup error - a plain
            # lookup renders EMPTY, not "[]").
            return "" if first_found_errors_ignore?(kwargs)
            raise ex
          end
        when "env"
          # lookup('env', 'VAR_NAME') - real Ansible's own env lookup
          # plugin, reads an environment variable from the CONTROLLER
          # (not the target - this always runs on the controller side,
          # same as first_found above). Entirely unimplemented before -
          # fell through to the `unless lookup_type == "first_found"`
          # guard, always "undefined" regardless of the real env var.
          # Found via ansible-community.ansible-vault's own `vault_
          # version: "{{ lookup('env', 'VAULT_VERSION') | default(
          # '2.0.3', true) }}"` - real Ansible's own env lookup returns
          # an empty string for an unset var (not an error), which is
          # what makes the `default(..., true)` fallback actually kick
          # in; "undefined" is a non-empty string, so default() never
          # replaced it, leaving the literal text "undefined" as the
          # real Vault version used to build the download URL.
          var_name = parts[1]?.try { |part| resolve_plus_operand(part.strip) }.try(&.as_s?)
          var_name ? (ENV[var_name]? || "") : "undefined"
        when "config"
          lookup_config(parts, kwargs)
        when "inventory_hostnames"
          lookup_inventory_hostnames(parts, kwargs, query_mode)
        when "url"
          lookup_url(parts, kwargs)
        when "vars"
          lookup_vars(parts, kwargs)
        end
      end

      private def lookup_config(parts : Array(String), kwargs : Array(String)) : String
        # lookup('config', 'OPTION'[, 'OPTION2', ...], wantlist=True) -
        # real Ansible's own config lookup plugin, returns the current
        # value of one or more ansible.cfg / ANSIBLE_* settings from the
        # CONTROLLER. Multi-arg form with wantlist=True returns a real
        # list (buluma.multi's own `loop: "{{ lookup('config', 'COLOR_OK',
        # 'COLOR_CHANGED', 'COLOR_SKIP', wantlist=True) }}"`, round 190 -
        # previously unimplemented, fell through to "undefined", so the
        # loop bound `item` to nothing and the debug failed with
        # `'item' is undefined`). Defaults match ansible-core 2.19's own
        # DEFAULT_*/COLOR_* constants when no ansible.cfg override is set.
        wantlist = kwargs.any? { |part| part.strip.downcase.starts_with?("wantlist=true") }
        names = parts[1..].compact_map { |part|
          quoted_string_literal(part.strip).try(&.as_s?) || evaluate(part.strip).presence
        }
        return "undefined" if names.empty?
        values = names.map { |nval| ansible_config_value(nval) }
        if wantlist || names.size > 1
          values.to_json
        else
          values[0]
        end
      end

      private def lookup_inventory_hostnames(parts : Array(String), kwargs : Array(String), query_mode : Bool = false) : String
        # lookup('inventory_hostnames', pattern[, pattern2, ...],
        # wantlist=True) - real Ansible's own inventory_hostnames lookup
        # plugin. Previously unimplemented (fell through to "undefined"),
        # the standard cross-group orchestration idiom (`delegate_to:
        # "{{ lookup('inventory_hostnames', 'kube-master[0]') }}"`,
        # building a peer list into a fact, running one task against
        # another group's members).
        #
        # Faithful to the real plugin's OWN implementation, which is
        # simpler than it looks: it builds a throwaway InventoryManager
        # purely from variables['groups'] - NOT from the full inventory -
        # and runs the standard host-pattern machinery over it. The
        # `groups` magic var is already in every task's vars context
        # (TaskExecutor#build_vars_context), so this needs no inventory
        # plumbing at all. Pattern semantics behavior matched to
        # the real module: comma-separated (colon
        # fallback) terms, `&` intersection / `!` exclusion applied after
        # the regular terms, fnmatch glob over group names first and host
        # names only when no group matched (or the pattern carries glob
        # metacharacters), `~`-prefixed raw regexes, `[N]`/`[A:B]`
        # subscripts (the range is INCLUSIVE of B, real Ansible's
        # hosts[start:end + 1]), and a no-match result that is an empty
        # list - the real lookup swallows its own AnsibleError and
        # returns [], never failing the task.
        wantlist = kwargs.any? { |part| part.strip.downcase.starts_with?("wantlist=true") }
        terms = parts[1..].compact_map do |part|
          evaluate(part.strip).presence
        end
        return "undefined" if terms.empty?

        groups = @vars["groups"]?.try(&.as_h?)
        return "undefined" unless groups
        named = inventory_groups_from_vars(groups)

        begin
          hosts = inventory_pattern_hosts(terms, named)
        rescue
          # Real LookupModule: `except AnsibleError: return []` - an
          # out-of-range subscript on matched hosts empties the whole
          # result rather than failing the task.
          hosts = [] of String
        end
        # Real lookup(): a list-shaped result is comma-joined ONLY into a
        # scalar when the caller asked for a scalar AND got something -
        # an EMPTY result stays a real empty list ([]), both for lookup()
        # and query() (verified: lookup('inventory_hostnames',
        # 'nosuchgroup') renders [] in real ansible-core 2.19.4's msg,
        # not an empty string). query() is real Ansible's list-forcing
        # sibling: it returns the real list even without wantlist=True
        # (with_items/query loops must iterate hosts, not one joined
        # string) - the same convention lookup_url already follows for
        # its wantlist=True form.
        list_form = wantlist || query_mode || hosts.empty?
        list_form ? hosts.to_json : hosts.join(",")
      end

      # Normalizes the `groups` magic var into the {group => [hosts]} map
      # the pattern matcher works over: every named group as-is, `all` =
      # the full host list (or the deduped union when the var lacks it),
      # and `ungrouped` = the var's own value when present, else every
      # host in no named group - real Ansible's own groups magic var
      # always carries both implicit groups.
      private def inventory_groups_from_vars(groups : Hash(String, JSON::Any)) : Hash(String, Array(String))
        named = Hash(String, Array(String)).new
        groups.each do |name, members|
          next if name == "all" || name == "ungrouped"
          named[name] = members.as_a?.try(&.map(&.as_s)) || [] of String
        end
        all_hosts = groups["all"]?.try(&.as_a?).try(&.map(&.as_s)) ||
                    named.values.flatten.uniq!
        named["ungrouped"] = groups["ungrouped"]?.try(&.as_a?).try(&.map(&.as_s)) ||
                             all_hosts.reject { |host| named.values.any?(&.includes?(host)) }
        named["all"] = all_hosts
        named
      end

      # The match of manager.py's split_host_pattern + order_patterns +
      # get_hosts term application: regular terms union in order, then
      # `&` terms intersect, then `!` terms exclude (and a pattern made
      # ONLY of &/! terms implicitly starts from 'all').
      private def inventory_pattern_hosts(terms : Array(String), groups : Hash(String, Array(String))) : Array(String)
        patterns = terms.flat_map { |term| split_host_pattern_terms(term) }
        regular = [] of String
        intersections = [] of String
        exclusions = [] of String
        patterns.each do |pattern|
          next if pattern.empty?
          if pattern.starts_with?('!')
            exclusions << pattern[1..]
          elsif pattern.starts_with?('&')
            intersections << pattern[1..]
          else
            regular << pattern
          end
        end
        regular << "all" if regular.empty?

        hosts = [] of String
        regular.each { |pattern| inventory_match_one(pattern, groups).each { |host| hosts << host unless hosts.includes?(host) } }
        intersections.each do |pattern|
          allowed = inventory_match_one(pattern, groups)
          hosts = hosts.select { |host| allowed.includes?(host) }
        end
        exclusions.each do |pattern|
          excluded = inventory_match_one(pattern, groups)
          hosts = hosts.reject { |host| excluded.includes?(host) }
        end
        hosts
      end

      # Real split_host_pattern: commas are the primary separator; a
      # colon-separated list is only the fallback (and bracketed
      # subscripts must not be split there - `web[0:2]` is one term).
      # IPv6-literal terms are mis-split by the colon fallback in real
      # Ansible too ("retained only for backwards compatibility", its
      # own words), so that limitation is inherited, not introduced.
      private def split_host_pattern_terms(pattern : String) : Array(String)
        return pattern.split(',').map(&.strip).reject(&.empty?) if pattern.includes?(',')
        terms = [] of String
        current = ""
        in_brackets = false
        pattern.each_char do |char|
          if char == '['
            in_brackets = true
          elsif char == ']'
            in_brackets = false
          end
          if char == ':' && !in_brackets
            terms << current.strip
            current = ""
          else
            current += char
          end
        end
        terms << current.strip
        terms.reject(&.empty?)
      end

      # Real _match_one_pattern/_enumerate_matches/_split_subscript/
      # _apply_subscript: subscript split off first, then fnmatch over
      # group names, then (only when no group matched, or the pattern
      # carries glob metacharacters / is a ~-regex) over host names,
      # then the implicit-localhost fallback, then the subscript applied
      # INCLUSIVELY ([A:B] keeps B; [N] picks one, negatives allowed).
      private def inventory_match_one(pattern : String, groups : Hash(String, Array(String))) : Array(String)
        base, subscript = split_subscript(pattern)
        matched = inventory_enumerate_matches(base, groups)
        apply_host_subscript(matched, subscript)
      end

      private def inventory_enumerate_matches(pattern : String, groups : Hash(String, Array(String))) : Array(String)
        return groups["all"] || [] of String if pattern == "all"
        return inventory_regex_matches(pattern.lchop("~"), groups) if pattern.starts_with?("~")

        regex = fnmatch_regex(pattern)
        matching_groups = groups.keys.select { |name| name != "all" && regex.matches?(name) }
        return matching_groups.flat_map { |name| groups[name] } if matching_groups.size > 0

        # No group matched, or the pattern carries glob metacharacters -
        # real Ansible also checks host names in that case (its own
        # "pattern might match host" branch).
        host_regex = fnmatch_regex(pattern)
        (groups["all"] || [] of String).select { |host| host_regex.matches?(host) }
      end

      private def inventory_regex_matches(pattern : String, groups : Hash(String, Array(String))) : Array(String)
        regex = Regex.new("^#{pattern}$")
        matching_groups = groups.keys.select { |name| name != "all" && regex.matches?(name) }
        return matching_groups.flat_map { |name| groups[name] } if matching_groups.size > 0
        (groups["all"] || [] of String).select { |host| regex.matches?(host) }
      rescue
        [] of String
      end

      private def split_subscript(pattern : String) : {String, {Int32, Int32?}?}
        idx = pattern.rindex('[')
        return {pattern, nil} unless idx && pattern.ends_with?(']') && idx > 0
        inner = pattern[(idx + 1)..-2]
        base = pattern[0...idx]
        if single = inner.match(/^-?[0-9]+$/)
          {base, {single[0].to_i, nil}}
        elsif range = inner.match(/^([0-9]+):([0-9]*)$/)
          start = range[1].to_i
          # Real _split_subscript: a missing end becomes -1, which
          # _apply_subscript then resolves to len(hosts) - 1 (inclusive).
          end_value = range[2].empty? ? -1 : range[2].to_i
          {base, {start, end_value}}
        else
          # Not a subscript at all (e.g. a fnmatch character class like
          # `web[12]`) - the whole pattern stays the match expression.
          {pattern, nil}
        end
      end

      private def apply_host_subscript(hosts : Array(String), subscript : {Int32, Int32?}?) : Array(String)
        return hosts unless subscript
        return [] of String if hosts.empty?
        start, end_value = subscript
        if end_value.nil?
          return [hosts[start]]
        end
        end_index = end_value == -1 ? hosts.size - 1 : end_value
        return [] of String if end_index < start
        hosts[start..end_index]
      rescue IndexError
        # Real _match_one_pattern maps IndexError to AnsibleError, which
        # the real lookup swallows into an empty result.
        [] of String
      end

      # Python's fnmatch.translate for the subset real host patterns use:
      # literal text plus `*`, `?` and `[...]` character classes.
      private def fnmatch_regex(pattern : String) : Regex
        Regex.new("^#{fnmatch_regex_source(pattern)}$")
      end

      private def fnmatch_regex_source(pattern : String) : String
        String.build do |str|
          index = 0
          while index < pattern.size
            char = pattern[index]
            case char
            when '*' then str << ".*"
            when '?' then str << "."
            when '['
              close = pattern.index(']', index + 1)
              if close
                str << pattern[index..close]
                index = close
              else
                str << Regex.escape(char.to_s)
              end
            else
              str << Regex.escape(char.to_s)
            end
            index += 1
          end
        end
      end

      private def lookup_url(parts : Array(String), kwargs : Array(String)) : String
        # lookup('url', url_expr, wantlist=True) - real Ansible's own
        # url lookup plugin, fetching a URL from the CONTROLLER (same
        # controller-side rule as env/first_found above). Entirely
        # unimplemented before - fell through to "undefined", so
        # cloudalchemy.prometheus's own checksum-pinning idiom
        # (`lookup('url', '.../sha256sums.txt', wantlist=True) |
        # list`, then looping over each line to find the right
        # architecture's checksum) never populated a real checksum -
        # `checksum:` on the subsequent get_url: task compared against
        # the literal string "undefined", always failing. The url_expr
        # itself is commonly a `+`-concatenation of literals and
        # variables (`'https://...v' + prometheus_version + '/...'`),
        # so it's rendered via the full #evaluate (not
        # #resolve_plus_operand, which only understands a single
        # operand) rather than a bare variable/literal lookup.
        url = parts[1]?.try { |part| evaluate(part.strip) }
        return "undefined" unless url

        # Real Ansible's `lookup()` Jinja function only returns a real
        # LIST when the call site explicitly passes `wantlist=True` -
        # otherwise it comma-joins the plugin's own (always-list)
        # result into a single plain STRING. `fetch_url_lines` always
        # returned the JSON-array form unconditionally (right for
        # cloudalchemy.prometheus's own `wantlist=True) | list` idiom,
        # which this was originally added for), so a call with no
        # `wantlist=True` at all - robertdebock.kubectl's own
        # `kubectl_url: ".../release/{{ lookup('url',
        # kubectl_version_url) }}/bin/..."`, fetching a single-line
        # version file - got the literal text `["v1.31.0"]` spliced
        # into the URL instead of the plain string `v1.31.0`, a 404.
        wantlist = kwargs.any? { |part| part.strip.downcase.starts_with?("wantlist=true") }
        lines_json = fetch_url_lines(url)
        return lines_json if wantlist

        (JSON.parse(lines_json).as_a?.try(&.map(&.as_s).join(",")) rescue nil) || "undefined"
      end

      private def lookup_vars(parts : Array(String), kwargs : Array(String)) : String
        # lookup('vars', 'variable_name') - real Ansible's own vars
        # lookup plugin: an INDIRECT variable lookup, the name itself
        # coming from an expression (commonly a computed string, e.g.
        # `lookup('vars', 'nginx_' + ansible_distribution)`) rather
        # than being written as a literal `{{ }}` reference. Entirely
        # unimplemented before, fell through to "undefined".
        var_name = parts[1]?.try { |part| evaluate(part.strip) }
        return "undefined" unless var_name
        resolved = @lookup.resolve(var_name)
        if resolved
          @lookup.format_value(resolved)
        elsif default_kwarg = kwargs.find(&.strip.downcase.starts_with?("default="))
          # `lookup('vars', key, default=...)` - the real plugin's own
          # escape hatch for a missing key: an explicit default is
          # rendered (real Ansible templates the option value through
          # the templar) and used INSTEAD of raising, so the common
          # `lookup('vars', 'pkg_' ~ distro, default='http://...')`
          # idiom keeps working. Only a missing key WITH a default
          # takes this branch - an existing key never gets here.
          evaluate(default_kwarg.split("=", 2)[1].strip)
        else
          # Real Ansible's own vars lookup plugin raises
          # AnsibleUndefinedVariable ("No variable found with this
          # name: <key>") for a missing key with no default - it does
          # NOT fall back to a placeholder - so the whole enclosing
          # task fails right at the lookup instead of splicing the
          # literal text "undefined" into a fact and letting the play
          # sail on with a bogus value (found via galaxyproject.
          # galaxy's `set_fact: "{{ item }}": "{{ lookup('vars',
          # '__' ~ item) }}"`, where the bogus value silently
          # poisoned 20+ downstream tasks before the engines
          # diverged anywhere visible). Raising UndefinedVariableError
          # (not a bare Exception) routes through the same
          # degrade-to-failed-task handling as the evaluator's other
          # strict-undefined violations. NOTE: the message text is
          # ansible-core's own vars.py wording from reading its
          # source, NOT verified against a live ansible-playbook run.
          raise UndefinedVariableError.new("No variable named '#{var_name}' was found.")
        end
      end

      # Fetches *url* (a plain GET, no auth/headers - matches what these
      # real playbooks actually need it for: fetching a public checksums
      # file) and returns its body as a JSON array of non-blank lines,
      # matching how cloudalchemy.prometheus's own `wantlist=True) |
      # list` usage then loops over each line looking for one containing
      # a specific filename substring. Real Ansible's own url lookup
      # plugin has richer options (headers, auth, split_lines:) not
      # implemented here - narrowly scoped to what's actually been
      # needed so far, like several other lookup/filter gaps in this
      # file.
      private def fetch_url_lines(url : String, redirects_left : Int32 = 5) : String
        return "undefined" if redirects_left < 0

        # file:// URLs read a controller-local file - real Ansible's own
        # url lookup plugin supports the scheme through its shared
        # fetch_url helper, and it's the offline-testable form of the
        # with_url:/lookup('url', ...) checksum idiom. A missing file
        # fails the task like the HTTP-error branch below, matching the
        # file lookup's own hard-fail behavior.
        if url.downcase.starts_with?("file://")
          path = url["file://".size..]
          begin
            return File.read(path).lines.map(&.strip).reject(&.empty?).to_json
          rescue e : File::Error
            raise "The lookup plugin 'url' failed: Unable to access the file '#{path}': #{e.message}"
          end
        end

        response = HTTP::Client.get(url)

        # GitHub (and most CDNs fronting release assets, exactly what
        # this lookup is used for in practice) answers a plain GET with
        # a 302 to a signed, one-shot storage URL - Crystal's
        # `HTTP::Client.get` doesn't follow redirects on its own, so the
        # very first real call this lookup was tested against returned
        # an empty 302 body instead of the checksums file.
        if response.status.redirection? && (location = response.headers["Location"]?)
          resolved = URI.parse(location).absolute? ? location : URI.parse(url).resolve(location).to_s
          return fetch_url_lines(resolved, redirects_left - 1)
        end

        unless response.success?
          # Real Ansible's own url lookup plugin raises a hard
          # AnsibleError (failing the whole enclosing task, e.g. a
          # set_fact:) on ANY non-2xx response - verified against its
          # exact live error message ("Received HTTP error for <url> :
          # HTTP Error <code>: <reason>"). Found benchmarking buluma.
          # victoriametrics's own checksum-lookup task: a stale
          # `victoriametrics_version` default whose GitHub release
          # checksums file has since been removed (404 - a broken-
          # upstream default, not this engine's doing). Silently
          # degrading to "undefined" here (the old behavior) let
          # execution continue into a `with_items:` loop over a single
          # bogus "undefined" item instead of failing right at the
          # lookup, producing a real ok=/skipped= recap divergence from
          # real Ansible even though both engines ultimately fail this
          # broken-upstream role identically overall. A raised
          # exception here propagates up through #evaluate/#substitute
          # to the task executor's own generic rescue, which converts
          # it into a normal failed PluginResult - the same path
          # `subelements:`'s own `raise` (elsewhere in this file)
          # already relies on for "fail the enclosing task", not a new
          # mechanism.
          raise "The lookup plugin 'url' failed: Received HTTP error for #{url} : HTTP Error #{response.status_code}: #{response.status.description}"
        end

        lines = response.body.lines.map(&.strip).reject(&.empty?)
        lines.to_json
      rescue Socket::Error | IO::Error
        # Genuine connection-level failures (DNS resolution, connection
        # refused, timeout) still degrade softly to "undefined" rather
        # than failing outright - only a real HTTP-level error response
        # (raised explicitly above) matches real Ansible's hard-fail
        # behavior; this project has no live evidence either way for
        # the connection-error case, so it's left at its prior,
        # conservative behavior rather than guessed at.
        "undefined"
      end
    end
  end
end
