require "crinja"
require "./crinja_hash_ext"

# Custom Jinja2 filters that real Ansible's Jinja2 provides but Crinja
# doesn't ship, registered into the global Crinja default library so they're
# available to every environment this process builds (the template module's
# own env and the shared CrinjaRenderer/{% %} env both start with
# register_defaults, so a filter added to Filter::Library.defaults here is
# visible in both).
#
# This file is required by template_action_plugin.cr (and therefore pulled
# into every binary that renders templates). Keep filters here scoped to
# what real playbooks actually use, verified against real ansible-playbook
# rather than assumed from Jinja2 docs. Positional arguments come through
# `arguments.varargs` (indexed by position), keyword args through
# `arguments.kwargs`.

module CrystalPlay
  module JinjaFilters
    # `comment` - real Ansible's own filter (ansible.plugins.filter.core),
    # NOT a Jinja2 template comment - it produces a *shell/config-file*
    # comment block meant to appear in the *rendered output* (dev-sec
    # os_hardening's own `{{ ansible_managed | comment }}` header, used at
    # the top of 14 different templates including several PAM config
    # files, is meant to warn a human reader not to hand-edit the file).
    # Previously wrapped the value in literal `{# ... #}` Jinja-comment
    # syntax instead - meaningless (and never stripped) in a *rendered*
    # file, so every one of those 14 templates got the literal text
    # "{# Ansible managed #}" as their first line. For PAM config files
    # specifically, that single corrupted line broke the whole PAM stack
    # ("configuration error - unknown item '{#'") for any command that
    # consults it, cascading into using every account-management
    # operation the role performs failing.
    #
    # Matches real Ansible's default ("plain") style exactly: a bare "#"
    # line, each line of the value prefixed "# ", another bare "#" line.
    # `decoration=` overrides that prefix (real Ansible's own comment.py:
    # the border lines become `decoration.rstrip`, each content line gets
    # the full decoration prefix, a blank line gets the rstripped form so
    # no trailing space is left dangling) - needed for any file whose own
    # comment syntax isn't "#" at all, e.g. geerlingguy.php's own
    # `www.conf.j2` (an INI-style php-fpm pool file, `decoration='; '`):
    # left as a bare "#"-style header before this, php-fpm's own INI
    # parser doesn't treat "#" as a comment character and failed outright
    # ("value is NULL for a ZEND_INI_PARSER_ENTRY") on startup - the
    # config looked fine to a human eye but never actually took effect.
    # The style=/prefix=/postfix= keyword variants (c/cpp/xml styles)
    # still aren't implemented - no template seen so far uses them.
    Crinja.filter(:comment) do
      decoration = arguments.kwargs["decoration"]?.try(&.to_s) || "# "
      border = decoration.rstrip
      lines = target.to_s.split('\n')
      commented = ([border] + lines.map { |line| line.empty? ? border : "#{decoration}#{line}" } + [border]).join('\n')
      Crinja::Value.new(commented)
    end

    # `mandatory` - real Ansible's own filter: passes the value through
    # unchanged if it's defined, raises otherwise (an optional first
    # argument is the custom error message) - used to fail a template
    # render loudly rather than silently write an empty/wrong value when
    # a var the role genuinely requires wasn't set. mysql_hardening's
    # own my.cnf.j2 writes `password='{{ mysql_root_password |
    # mandatory }}'`.
    Crinja.filter(:mandatory) do
      if target.undefined?
        msg = arguments.varargs[0]?.try(&.to_s) || "Mandatory variable not defined."
        raise Crinja::UndefinedError.new(msg)
      end
      target
    end

    # `bool` - coerce a value to a boolean the way Jinja2's bool filter does:
    # "true"/"yes"/"1"/"on" (case-insensitive) are true, everything else
    # (including nil and "false") is false. Used throughout os_hardening
    # templates for `{{ os_* | bool }}`.
    Crinja.filter(:bool) do
      Crinja::Value.new(
        case target.to_s.downcase
        when "true", "yes", "1", "on"
          true
        else
          false
        end
      )
    end

    # `ternary(true_value, false_value)` - Jinja2's conditional value
    # selection: returns the first argument when the target is truthy, the
    # second when falsy. os_hardening writes per-boolean configs this way:
    # `{{ os_auditd_write_logs | bool | ternary('yes', 'no') }}`.
    #
    # Uses #real_truthy?, NOT Crinja::Value#truthy?: Crinja's own
    # implementation (lib/crinja/src/runtime/value.cr) only treats
    # `false`/`0`/`nil`/undefined as falsy - critically missing an empty
    # string, which real Python/Jinja2 (what Ansible actually runs on)
    # treats as falsy too. ssh_hardening's own `ssh_deny_users: ""`
    # default (and several others: allow_users, deny_groups, ...) relies
    # on exactly this - `{% if ssh_deny_users %}` must skip when it's
    # still the empty-string default. Can't fix Crinja::Value#truthy?
    # itself (lib/ is gitignored - a vendored-shard patch would silently
    # vanish on the next `shards install`), so every call site in *this*
    # file that needs real truthiness uses this helper instead.
    Crinja.filter(:ternary) do
      true_arg = arguments.varargs[0]?
      false_arg = arguments.varargs[1]?
      picked = if JinjaFilters.real_truthy?(target)
                 true_arg || Crinja::Value.new("")
               else
                 false_arg || Crinja::Value.new("")
               end
      Crinja::Value.new(picked)
    end

    # `pytruthy` - real Python/Jinja2 truthiness, exposed as its own
    # filter so `{% if EXPR %}`/`{% elif EXPR %}` tags can be rewritten
    # to `{% if (EXPR) | pytruthy %}` (see TemplateActionPlugin::
    # TAG_IF_ELIF) - Crinja's own native `{% if %}` evaluation calls
    # Crinja::Value#truthy? directly and can't be intercepted any other
    # way from outside the vendored shard.
    Crinja.filter(:pytruthy) do
      Crinja::Value.new(JinjaFilters.real_truthy?(target))
    end

    # Real Python/Jinja2 truthiness: falsy values are `false`, `0`
    # (any numeric type), `nil`/`None`, undefined, and - the specific
    # gap Crinja::Value#truthy? has - an empty string, empty sequence,
    # or empty mapping. Everything else is truthy.
    def self.real_truthy?(value : Crinja::Value) : Bool
      return false if value.undefined? || value.raw.nil?
      case raw = value.raw
      when Bool
        raw
      when String
        !raw.empty?
      when Int32, Int64
        raw != 0
      when Float64
        raw != 0.0
      when Array(Crinja::Value)
        !raw.empty?
      when Crinja::Dictionary
        !raw.empty?
      else
        true
      end
    end

    # `difference(iterable)` - set difference: the elements of the target
    # sequence not present in the argument sequence. os_hardening's
    # modprobe task uses it to subtract mounted fs types from a candidate
    # list: `os_unused_filesystems | difference(ansible_facts.mounts |
    # map(attribute='fstype') | list)`.
    # `split(sep='', index=None)` - Python's own str.split() method (not
    # a real Jinja2 filter at all - real Jinja2 exposes native Python
    # object methods directly, e.g. `{{ "a.b".split(".") }}`, something
    # Crinja has no equivalent mechanism for). Registered as a filter
    # and wired up via TemplateActionPlugin::SPLIT_METHOD, which
    # rewrites the `.split(...)` method-call syntax into `| split(...)`
    # before Crinja ever sees it - dev-sec apache_hardening's own
    # templates use this to parse `apache -v`'s version string
    # (`apache_version.split('.')[1]`, and a `set_fact:` building
    # apache_version itself in the first place: `_apache_version.stdout.
    # split()[2].split("/")[1]`, chained twice).
    #
    # `index`, the second (optional) argument, exists purely as a
    # workaround: SPLIT_METHOD folds a trailing `.split(...)[N]`'s own
    # `[N]` into this filter's own second argument, rather than leaving
    # it as post-filter indexing on the rewritten `{{ ... }}` expression
    # - confirmed by direct testing (not assumed) that Crinja can parse
    # neither `(EXPR)[N]` nor `(EXPR).N`, i.e. it cannot index *any*
    # parenthesized/filtered expression at all, only a bare variable
    # reference. Folding the index into the filter call sidesteps the
    # need to index the filter's own return value entirely.
    #
    # Empty sep: (Python's own no-arg default) splits on any run of
    # whitespace and drops empty results - not the same as splitting on
    # the literal string " ", which would keep an empty element between
    # two consecutive spaces. A given non-empty argument splits on that
    # literal substring, keeping empty elements (matching Python's own
    # str.split(sep) exactly - "a..b".split(".") is ["a", "", "b"]).
    Crinja.filter(:split) do
      sep = arguments.varargs[0]?.try(&.to_s)
      parts = if sep && !sep.empty?
                target.to_s.split(sep)
              else
                target.to_s.split
              end

      if index_arg = arguments.varargs[1]?
        idx = index_arg.to_s.to_i
        Crinja::Value.new(parts[idx]? || "")
      else
        Crinja::Value.new(parts.map { |part| Crinja::Value.new(part) })
      end
    end

    # `regex_replace(pattern, replacement='')` - Ansible's own filter
    # (not part of standard Jinja2, not provided by Crinja at all),
    # wrapping Python's `re.sub`. konstruktoid-hardening's
    # sysctl.ipv6.conf.j2 uses it to turn a VLAN interface name's dot
    # into the `/` sysctl's key-path syntax needs (`eth0.100` ->
    # `eth0/100`); `\1`/`\2` group backreferences in *replacement*
    # (Python's `re.sub` syntax) are translated to Crystal's `$1`/`$2`
    # before use, since Crystal's own regex replacement syntax differs.
    Crinja.filter(:regex_replace) do
      pattern = arguments.varargs[0]?.try(&.to_s) || ""
      replacement = arguments.varargs[1]?.try(&.to_s) || ""
      replacement = replacement.gsub(/\\(\d)/) { "$#{$1}" }
      Crinja::Value.new(target.to_s.gsub(Regex.new(pattern), replacement))
    end

    Crinja.filter(:difference) do
      arg = arguments.varargs[0]?
      target_vals = target.sequence? ? target.to_a : [] of Crinja::Value
      arg_set = Array(Crinja::Value).new
      a = arg
      arg_set = a.to_a if a && a.sequence?
      Crinja::Value.new(target_vals.reject { |item| arg_set.includes?(item) })
    end

    # `version(comparison_version, operator='==')` - Ansible's own test
    # (ansible.builtin.version), not part of standard Jinja2 and not
    # provided by Crinja at all: `{% if sshd_version is version('5.8',
    # '>=') %}`, used throughout ssh_hardening's opensshd.conf.j2 to
    # gate config lines by the target's actual OpenSSH version. Crinja
    # raised "no test named 'version'" on any `{% if %}`/`{% elif %}`
    # using it, failing the *entire* template render (all-or-nothing -
    # Crinja doesn't partially render), not just that one line.
    #
    # Compares dotted-numeric version strings component-by-component
    # (splitting on non-digit runs, same tolerance real `sshd -V`
    # output needs: "8.9p1" compares as [8, 9, 1]), matching Python's
    # LooseVersion behavior real Ansible's own `version` test delegates
    # to closely enough for every operator real playbooks use.
    Crinja.test(:version) do
      compare_to = arguments.varargs[0]?.try(&.to_s) || ""
      operator = arguments.varargs[1]?.try(&.to_s) || "=="
      cmp = JinjaFilters.compare_versions(target.to_s, compare_to)
      case operator
      when "==", "="
        cmp == 0
      when "!="
        cmp != 0
      when "<", "lt"
        cmp < 0
      when "<=", "le"
        cmp <= 0
      when ">", "gt"
        cmp > 0
      when ">=", "ge"
        cmp >= 0
      else
        false
      end
    end

    # `regex(pattern, ignorecase=False, multiline=False)` - Ansible's own
    # test (ansible.builtin.regex), not part of standard Jinja2 and not
    # provided by Crinja at all: konstruktoid-hardening's own
    # sshd_config.j2 gates its post-quantum KEX comment on `sshd_kex_
    # algorithms is not regex("sntrup761x25519-*")`. Crinja raised "no
    # test with name 'regex' registered" on any `{% if %}`/`{% elif %}`
    # using it (`is not regex(...)` parses as `not (X is regex(...))`,
    # so the missing test fails the whole render either way), same
    # all-or-nothing failure mode as the missing `version` test above.
    # Real Ansible defaults to a search anywhere in the string (not a
    # full match) - implemented that way here too.
    Crinja.test(:regex) do
      pattern = arguments.varargs[0]?.try(&.to_s) || ""
      opts = Regex::Options::None
      opts |= Regex::Options::IGNORE_CASE if arguments.kwargs["ignorecase"]?.try(&.truthy?)
      opts |= Regex::Options::MULTILINE if arguments.kwargs["multiline"]?.try(&.truthy?)
      !!(target.to_s =~ Regex.new(pattern, opts))
    end

    # Splits a version string into its numeric components (`"8.9p1"` ->
    # `[8, 9, 1]`, ignoring the non-digit "p" separator), then compares
    # two such component lists lexicographically, treating a missing
    # trailing component as 0 (`"5.8" <=> "5.8.0"` is equal).
    def self.compare_versions(a : String, b : String) : Int32
      a_parts = a.scan(/\d+/).map(&.[0].to_i)
      b_parts = b.scan(/\d+/).map(&.[0].to_i)
      [a_parts.size, b_parts.size].max.times do |i|
        a_val = a_parts[i]? || 0
        b_val = b_parts[i]? || 0
        cmp = a_val <=> b_val
        return cmp unless cmp == 0
      end
      0
    end
  end
end
