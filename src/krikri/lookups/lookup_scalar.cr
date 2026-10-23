require "json"
require "http/client"
require "uri"
require "./inventory_pattern"

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
          # Honour a matching ANSIBLE_<NAME> env var when present (Ansible's own resolution order: env > cfg > default).
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
            # honors (Ansible swallows the lookup error - a plain
            # lookup renders EMPTY, not "[]").
            return "" if first_found_errors_ignore?(kwargs)
            raise ex
          end
        when "env"
          # lookup('env', 'VAR_NAME') - Ansible's own env lookup
          # plugin, reads an environment variable from the CONTROLLER
          # (not the target - this always runs on the controller side,
          # same as first_found above). Entirely unimplemented before -
          # fell through to the `unless lookup_type == "first_found"`
          # guard, always "undefined" regardless of the real env var.
          # Found via ansible-community.ansible-vault's own `vault_
          # version: "{{ lookup('env', 'VAULT_VERSION') | default(
          # '2.0.3', true) }}"` - Ansible's own env lookup returns
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
        # Ansible's own config lookup plugin, returns the current
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
        # wantlist=True) - Ansible's own inventory_hostnames lookup
        # plugin. Previously unimplemented (fell through to "undefined"),
        # the standard cross-group orchestration idiom (`delegate_to:
        # "{{ lookup('inventory_hostnames', 'kube-master[0]') }}"`,
        # building a peer list into a fact, running one task against
        # another group's members).
        # Faithful to the real plugin's own implementation, which builds
        # a throwaway InventoryManager purely from variables['groups'] -
        # NOT from the full inventory - and runs the standard
        # host-pattern machinery over it; the machinery lives in
        # InventoryPatterns, shared with the krikri-jinja engine's
        # own lookup/query (the route legacy `with_inventory_hostnames:`
        # loop sources take - see that arm for why).
        wantlist = kwargs.any? { |part| part.strip.downcase.starts_with?("wantlist=true") }
        terms = parts[1..].compact_map do |part|
          evaluate(part.strip).presence
        end
        return "undefined" if terms.empty?

        groups = @vars["groups"]?.try(&.as_h?)
        return "undefined" unless groups
        named = InventoryPatterns.groups_from_vars(groups)
        hosts = InventoryPatterns.pattern_hosts(terms, named)
        # Real lookup(): a list-shaped result is comma-joined ONLY into a
        # scalar when the caller asked for a scalar AND got something -
        # an EMPTY result stays a real empty list ([]), both for lookup()
        # and query() (verified: lookup('inventory_hostnames',
        # 'nosuchgroup') renders [] in ansible-core 2.19.4's msg,
        # not an empty string). query() is Ansible's list-forcing
        # sibling: it returns the real list even without wantlist=True
        # (with_items/query loops must iterate hosts, not one joined
        # string) - the same convention lookup_url already follows for
        # its wantlist=True form.
        list_form = wantlist || query_mode || hosts.empty?
        list_form ? hosts.to_json : hosts.join(",")
      end

      private def lookup_url(parts : Array(String), kwargs : Array(String)) : String
        # lookup('url', url_expr, wantlist=True) - Ansible's own
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

        # Ansible's `lookup()` Jinja function only returns a real
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
        # lookup('vars', 'variable_name') - Ansible's own vars
        # lookup plugin: an INDIRECT variable lookup, the name itself
        # coming from an expression (commonly a computed string, e.g.
        # `lookup('vars', 'nginx_' + ansible_distribution)`) rather
        # than being written as a literal `{{ }}` reference. Entirely
        # unimplemented before, fell through to "undefined".
        var_name = parts[1]?.try { |part| evaluate(part.strip) }
        return "undefined" unless var_name
        resolved = @lookup.resolve(var_name)
        if resolved
          # Ansible's vars lookup runs the found value through the templar
          # before returning it, so a lazily-templated role var
          # (`vars/main.yml: "_quiet: '{{ ext_quiet | default(...) }}'"`)
          # renders AT the lookup instead of surfacing as raw `{{ }}` text -
          # the direct `{{ _quiet }}` reference path already re-rendered,
          # only the by-name fetch skipped it (round 5250000,
          # sscheib.openwrt_extroot's assert loop validating
          # `lookup('ansible.builtin.vars', '_ext_quiet_assert')`).
          @lookup.format_value(@lookup.rerender_var_value(resolved))
        elsif default_kwarg = kwargs.find(&.strip.downcase.starts_with?("default="))
          # `lookup('vars', key, default=...)` - the real plugin's own
          # escape hatch for a missing key: an explicit default is
          # rendered (Ansible templates the option value through
          # the templar) and used INSTEAD of raising, so the common
          # `lookup('vars', 'pkg_' ~ distro, default='http://...')`
          # idiom keeps working. Only a missing key WITH a default
          # takes this branch - an existing key never gets here.
          evaluate(default_kwarg.split("=", 2)[1].strip)
        else
          # Ansible's own vars lookup plugin raises
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
      # a specific filename substring. Ansible's own url lookup
      # plugin has richer options (headers, auth, split_lines:) not
      # implemented here - narrowly scoped to what's actually been
      # needed so far, like several other lookup/filter gaps in this
      # file.
      private def fetch_url_lines(url : String, redirects_left : Int32 = 5) : String
        return "undefined" if redirects_left < 0

        # file:// URLs read a controller-local file - Ansible's own
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
          # Ansible's own url lookup plugin raises a hard
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
          # Ansible even though both engines ultimately fail this
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
        # (raised explicitly above) matches Ansible's hard-fail
        # behavior; this project has no live evidence either way for
        # the connection-error case, so it's left at its prior,
        # conservative behavior rather than guessed at.
        "undefined"
      end
    end
  end
end
