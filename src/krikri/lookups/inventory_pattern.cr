require "json"

module Krikri
  # The pattern machinery behind Ansible's own inventory_hostnames lookup
  # plugin - the pure part (a `groups` hash + pattern terms -> the matched
  # host names) that BOTH of this project's lookup paths share:
  #
  # - the hand-rolled evaluator's scalar arm
  #   (VariableSubstitutor::ExpressionEvaluator#lookup_inventory_hostnames,
  #   reached by direct `{{ lookup('inventory_hostnames', ...) }}` /
  #   `{{ query(...) }}` text), and
  # - the krikri-jinja engine's registered `lookup`/`query`
  #   (KrikriJinjaLookups - the path every legacy
  #   `with_inventory_hostnames:` loop source reaches, because
  #   TaskExecutor#resolve_loop_lookup evaluates the source as
  #   `query('inventory_hostnames', term, wantlist=True)` on the engine,
  #   not through the hand-rolled evaluator's own lookup dispatch).
  #
  # Faithful to the real plugin's OWN implementation, which is simpler
  # than it looks: it builds a throwaway InventoryManager purely from
  # variables['groups'] - NOT from the full inventory - and runs the
  # standard host-pattern machinery over it. The `groups` magic var is
  # already in every task's vars context
  # (TaskExecutor#build_vars_context), so this needs no inventory
  # plumbing at all. Pattern semantics matched to the Ansible module:
  # comma-separated (colon fallback) terms, `&` intersection / `!`
  # exclusion applied after the regular terms, fnmatch glob over group
  # names first and host names only when no group matched (or the
  # pattern carries glob metacharacters), `~`-prefixed raw regexes,
  # `[N]`/`[A:B]` subscripts (the range is INCLUSIVE of B, Ansible's
  # hosts[start:end + 1]), and a no-match result that is an empty list
  # - the real lookup swallows its own AnsibleError and returns [],
  # never failing the task.
  module InventoryPatterns
    # Normalizes the `groups` magic var into the {group => [hosts]} map
    # the pattern matcher works over: every named group as-is, `all` =
    # the full host list (or the deduped union when the var lacks it),
    # and `ungrouped` = the var's own value when present, else every
    # host in no named group - Ansible's own groups magic var
    # always carries both implicit groups.
    def self.groups_from_vars(groups : Hash(String, JSON::Any)) : Hash(String, Array(String))
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

    # The match of manager.py's _split_host_pattern + order_patterns +
    # get_hosts term application: regular terms union in order, then
    # `&` terms intersect, then `!` terms exclude (and a pattern made
    # ONLY of &/! terms implicitly starts from 'all'). A pattern error
    # (e.g. an out-of-range subscript inside _match_one_pattern's
    # AnsibleError) empties the WHOLE result - real LookupModule:
    # `except AnsibleError: return []` - never failing the task.
    def self.pattern_hosts(terms : Array(String), groups : Hash(String, Array(String))) : Array(String)
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
      # Real _enumerate_matches warns once per unique unmatched pattern
      # (its _pattern_cache suppresses repeats within one manager, and
      # the lookup builds a fresh manager per call, so the dedupe set
      # is scoped to this call).
      warned_patterns = Set(String).new
      regular.each do |pattern|
        match_one(pattern, groups, warned_patterns).each { |host| hosts << host unless hosts.includes?(host) }
      end
      intersections.each do |pattern|
        allowed = match_one(pattern, groups)
        hosts = hosts.select { |host| allowed.includes?(host) }
      end
      exclusions.each do |pattern|
        excluded = match_one(pattern, groups)
        hosts = hosts.reject { |host| excluded.includes?(host) }
      end
      hosts
    rescue
      [] of String
    end

    # Real _split_host_pattern: commas are the primary separator; a
    # colon-separated list is only the fallback (and bracketed
    # subscripts must not be split there - `web[0:2]` is one term).
    # IPv6-literal terms are mis-split by the colon fallback in
    # Ansible too ("retained only for backwards compatibility", its
    # own words), so that limitation is inherited, not introduced.
    private def self.split_host_pattern_terms(pattern : String) : Array(String)
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
    private def self.match_one(pattern : String, groups : Hash(String, Array(String)), warned_patterns : Set(String)? = nil) : Array(String)
      base, subscript = split_subscript(pattern)
      matched, matched_groups = enumerate_matches(base, groups)
      # Real _enumerate_matches: a pattern that matched neither a group
      # name nor a host name gets a "Could not match supplied host
      # pattern" warning instead of silently yielding nothing. An empty
      # but matched group stays silent, 'all' always matches, and an
      # out-of-range subscript on matched hosts takes the error path
      # instead - hence the check on the pre-subscript enumeration.
      if warned_patterns && matched.empty? && !matched_groups && base != "all" && warned_patterns.add?(base)
        STDERR.puts "[WARNING]: Could not match supplied host pattern, ignoring: #{base}"
      end
      apply_host_subscript(matched, subscript)
    end

    private def self.enumerate_matches(pattern : String, groups : Hash(String, Array(String))) : {Array(String), Bool}
      return {groups["all"] || [] of String, true} if pattern == "all"
      return regex_matches(pattern.lchop("~"), groups) if pattern.starts_with?("~")

      regex = fnmatch_regex(pattern)
      matching_groups = groups.keys.select { |name| name != "all" && regex.matches?(name) }
      return {matching_groups.flat_map { |name| groups[name] }, true} if matching_groups.size > 0

      # No group matched, or the pattern carries glob metacharacters -
      # Ansible also checks host names in that case (its own
      # "pattern might match host" branch).
      host_regex = fnmatch_regex(pattern)
      {(groups["all"] || [] of String).select { |host| host_regex.matches?(host) }, false}
    end

    private def self.regex_matches(pattern : String, groups : Hash(String, Array(String))) : {Array(String), Bool}
      regex = Regex.new("^#{pattern}$")
      matching_groups = groups.keys.select { |name| name != "all" && regex.matches?(name) }
      return {matching_groups.flat_map { |name| groups[name] }, true} if matching_groups.size > 0
      {(groups["all"] || [] of String).select { |host| regex.matches?(host) }, false}
    rescue
      {[] of String, false}
    end

    private def self.split_subscript(pattern : String) : {String, {Int32, Int32?}?}
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

    private def self.apply_host_subscript(hosts : Array(String), subscript : {Int32, Int32?}?) : Array(String)
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
    private def self.fnmatch_regex(pattern : String) : Regex
      Regex.new("^#{fnmatch_regex_source(pattern)}$")
    end

    private def self.fnmatch_regex_source(pattern : String) : String
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
  end
end
