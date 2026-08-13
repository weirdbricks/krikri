require "crinja"
require "yaml"
require "openssl/digest"

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

    # Recursively converts a Crinja::Value into a YAML::Any, for
    # #to_nice_yaml. Deliberately NOT built via Value#to_json (a JSON
    # round-trip is a valid YAML flow subset, and would have been
    # simpler) - Value#to_json(builder) raises "Starting document before
    # ending previous one" when called via the no-arg Object#to_json
    # convenience wrapper Crinja doesn't override, so this walks
    # Value#raw directly instead.
    def self.crinja_value_to_yaml_any(value : Crinja::Value) : YAML::Any
      case raw = value.raw
      when Nil
        YAML::Any.new(nil)
      when Bool, String
        YAML::Any.new(raw)
      when Int32, Int64
        YAML::Any.new(raw.to_i64)
      when Float64
        YAML::Any.new(raw)
      when Time
        YAML::Any.new(raw.to_s)
      when Array(Crinja::Value)
        YAML::Any.new(raw.map { |v| crinja_value_to_yaml_any(v) })
      when Crinja::Dictionary
        YAML::Any.new(raw.to_a.to_h { |(k, v)| {YAML::Any.new(k.to_s), crinja_value_to_yaml_any(v)} })
      else
        YAML::Any.new(raw.to_s)
      end
    end

    # Recursively rebuilds *any* with every mapping's keys sorted
    # lexically (real Ansible's own `to_nice_yaml`'s `sort_keys=True`
    # default) - Crystal's `YAML::Any` wraps an ordered `Hash`, which
    # `to_yaml` emits in that same (insertion) order, so sorting has to
    # happen by rebuilding the structure, not by asking YAML::Builder
    # for it.
    def self.sort_yaml_keys(any : YAML::Any) : YAML::Any
      if hash = any.as_h?
        sorted = hash.to_a.sort_by { |(k, _)| k.to_s }
        YAML::Any.new(sorted.to_h { |(k, v)| {k, sort_yaml_keys(v)} })
      elsif arr = any.as_a?
        YAML::Any.new(arr.map { |v| sort_yaml_keys(v) })
      else
        any
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

    # `hash(algorithm='sha1')` - real Ansible's own filter
    # (ansible.plugins.filter.core), wrapping Python's `hashlib.new()`.
    # Defaults to sha1 when no argument is given, matching real Ansible.
    # Found via geerlingguy.supervisor's own supervisord.conf.j2:
    # `password = {SHA}{{ supervisor_password|hash('sha1') }}` (a
    # standard `{SHA}`-prefixed base64-ish supervisord auth format built
    # on top of the raw hex digest this filter itself returns).
    Crinja.filter(:hash) do
      algorithm = (arguments.varargs[0]?.try(&.to_s) || "sha1").downcase
      openssl_name = case algorithm
                     when "md5"    then "MD5"
                     when "sha1"   then "SHA1"
                     when "sha224" then "SHA224"
                     when "sha256" then "SHA256"
                     when "sha384" then "SHA384"
                     when "sha512" then "SHA512"
                     else
                       raise "hash: unsupported algorithm '#{algorithm}'"
                     end
      digest = OpenSSL::Digest.new(openssl_name)
      digest.update(target.to_s)
      Crinja::Value.new(digest.final.hexstring)
    end

    # `password_hash(hashtype='sha512', salt=None)` - real Ansible's own
    # filter (passlib-backed), a salted crypt(3) hash suitable for
    # /etc/shadow. See the identical FilterEngine copy (filter_engine.cr)
    # for the full rationale - checked in both evaluators per the usual
    # rule since a `.j2` template could set a password field this way
    # too (real ansible-vault/user-management templates commonly do).
    Crinja.filter(:password_hash) do
      hashtype = (arguments.varargs[0]?.try(&.to_s) || "sha512").downcase
      openssl_flag = case hashtype
                     when "md5"    then "-1"
                     when "sha256" then "-5"
                     when "sha512" then "-6"
                     else
                       raise "password_hash: unsupported hashtype '#{hashtype}' (supported: md5, sha256, sha512)"
                     end
      explicit_salt = arguments.varargs[1]?.try(&.to_s)
      salt = explicit_salt.presence || Random::Secure.hex(8)

      output = IO::Memory.new
      status = Process.run("openssl", ["passwd", openssl_flag, "-salt", salt, "-stdin"],
        input: IO::Memory.new(target.to_s), output: output)
      raise "password_hash: openssl passwd failed" unless status.success?
      Crinja::Value.new(output.to_s.strip)
    end

    # `type_debug` - real Ansible/Jinja2's own filter, Python's type
    # name for the value (`type(x).__name__`) - used almost exclusively
    # in role assert.yml sanity checks (`my_list | type_debug ==
    # "list"`). See the identical FilterEngine copy for the full
    # rationale; found via robertdebock.httpd's own assert.yml (round
    # 19).
    Crinja.filter(:type_debug) do
      type_name = case target.raw
                  when Array  then "list"
                  when Hash   then "dict"
                  when String then "str"
                  when Int64, Int32 then "int"
                  when Float64 then "float"
                  when Bool   then "bool"
                  when Nil    then "NoneType"
                  else "str"
                  end
      Crinja::Value.new(type_name)
    end

    # `to_json(**kwargs)` - real Ansible's own filter (ansible.plugins.
    # filter.core), a thin wrapper around Python's `json.dumps()`. Found
    # via geerlingguy.logstash's own 30-elasticsearch-output.conf.j2:
    # `hosts => {{ logstash_elasticsearch_hosts | to_json }}` - entirely
    # unimplemented, failing the whole template render outright ("no
    # filter with name \"to_json\" registered"). Python's `json.dumps`
    # defaults to `", "`/`": "` item/key separators (not Crystal
    # stdlib's own compact `,`/`:` JSON::Builder output) - matched here
    # via a small recursive dump rather than Crystal's own to_json, so a
    # byte-identical diff against real ansible-playbook's rendered file
    # holds even for the common single/few-element list/dict case.
    Crinja.filter(:to_json) do
      String.build { |io| CrystalPlay::JinjaFilters.python_json_dump(target, io) }
    end

    def self.python_json_dump(value : Crinja::Value, io : IO)
      case raw = value.raw
      when Nil
        io << "null"
      when Bool
        io << raw
      when Crinja::SafeString
        raw.to_s.to_json(io)
      when String
        raw.to_json(io)
      when Number
        io << raw
      when Array(Crinja::Value)
        io << '['
        raw.each_with_index do |item, index|
          io << ", " if index > 0
          python_json_dump(item, io)
        end
        io << ']'
      when Crinja::Dictionary
        io << '{'
        first = true
        raw.each do |key, item|
          io << ", " unless first
          first = false
          key.to_s.to_json(io)
          io << ": "
          python_json_dump(item, io)
        end
        io << '}'
      else
        raw.to_s.to_json(io)
      end
    end

    Crinja.filter(:difference) do
      arg = arguments.varargs[0]?
      target_vals = target.sequence? ? target.to_a : [] of Crinja::Value
      arg_set = Array(Crinja::Value).new
      a = arg
      arg_set = a.to_a if a && a.sequence?
      Crinja::Value.new(target_vals.reject { |item| arg_set.includes?(item) })
    end

    # `to_nice_yaml(indent=N, sort_keys=True)` - real Ansible's own
    # filter (ansible.plugins.filter.core), a pretty-printed YAML dump
    # commonly used to embed a structured variable straight into a
    # generated config file. Entirely unimplemented before - Crinja
    # raised "no filter with name \"to_nice_yaml\" registered", failing
    # the whole template render. Found via cloudalchemy.prometheus's own
    # alerting-rules template: `{{ prometheus_alert_rules | to_nice_yaml
    # (indent=2, sort_keys=False) | indent(2, False) }}`.
    #
    # Converts via target.to_json -> YAML.parse -> to_yaml (JSON is a
    # valid YAML flow-syntax subset, so this round-trips cleanly through
    # Crystal stdlib's own YAML formatter without hand-rolling a YAML
    # emitter) rather than a custom serializer. `sort_keys=` is honored
    # (Hash insertion order is preserved either way, sorted only when
    # asked); `indent=` is NOT - Crystal's YAML::Builder has no
    # configurable indent width, so this always emits its own default
    # (2 spaces for nested maps) regardless of what indent= requested.
    # Narrowly scoped like several other filters in this file - revisit
    # only if a real template needs indent= to actually change the
    # output width.
    Crinja.filter(:to_nice_yaml) do
      sort_keys = arguments.kwargs["sort_keys"]?.try { |v| JinjaFilters.real_truthy?(v) }
      sort_keys = true if sort_keys.nil?

      any = JinjaFilters.crinja_value_to_yaml_any(target)
      any = JinjaFilters.sort_yaml_keys(any) if sort_keys

      Crinja::Value.new(any.to_yaml.sub(/\A---\n/, "").rstrip)
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

    # `basename`/`dirname` - Python's `os.path.basename`/`os.path.dirname`,
    # real Ansible filters (not standard Jinja2). Ported from this
    # codebase's own hand-rolled `FilterEngine` (found missing there via
    # geerlingguy.mysql's `mysql_log_error | dirname` - see that file's
    # own comment for the exact failure mode) to close the same gap in
    # Crinja, as prep for CRINJA.md's step-5 evaluator convergence -
    # Crinja had neither registered at all.
    Crinja.filter(:basename) { File.basename(target.to_s) }
    Crinja.filter(:dirname) { File.dirname(target.to_s) }

    # `combine(*others)` - shallow dict merge, later argument wins on key
    # collisions. Real Ansible's own filter (not standard Jinja2).
    # Ported from `FilterEngine#combine_hash` (same shallow, non-
    # recursive semantics - `recursive=`/`list_merge=` kwargs real
    # Ansible also supports are not implemented here, matching the
    # hand-rolled version's own scope).
    Crinja.filter(:combine) do
      varargs = arguments.varargs
      base = target.raw

      if base.is_a?(Hash)
        merged = base.dup
        varargs.each do |other|
          other_raw = other.raw
          other_raw.each { |key, value| merged[key] = value } if other_raw.is_a?(Hash)
        end
        Crinja::Value.new(merged)
      else
        target
      end
    end

    # `intersect(other)` - elements of *target* that also appear in
    # *other*, deduplicated, order taken from *target*. Real Ansible's
    # own filter (not standard Jinja2). Ported from `FilterEngine`'s own
    # version (found missing there via konstruktoid-hardening's
    # `ansible_facts.packages.keys() | intersect(packages_blocklist)` -
    # see that file's own comment for the correctness+hang impact of
    # this filter silently no-op'ing).
    Crinja.filter(:intersect) do
      other_set = (arguments.varargs[0]?.try(&.each.to_a) || [] of Crinja::Value).to_set
      seen = Set(Crinja::Value).new
      target.each.to_a.select { |item| other_set.includes?(item) && seen.add?(item) }
    end

    # `max`/`min` - real Jinja2 core filters, not Ansible-specific - now
    # registered directly in the fork (weirdbricks/crinja,
    # src/lib/filter/collections.cr), not here.

    # `regex_search(pattern, group_ref='')` - real Ansible's own filter
    # (not standard Jinja2): searches *pattern* anywhere in the target
    # (Python `re.search`, not a full match), and with a backreference-
    # style second argument (`'\\1'`) returns that captured group's text
    # instead of the whole match. No match resolves to Undefined -
    # ported from `FilterEngine`'s own version (see that file's own
    # comment on why Undefined rather than an empty string: a caller
    # chaining `| first` needs a real miss, not a silently-succeeding
    # empty match). Found missing there via konstruktoid-hardening's own
    # `sshd_version.stderr_lines | regex_search('OpenSSH_(...)', '\\1')
    # | first`.
    Crinja.filter({pattern: Crinja::UNDEFINED, group_ref: ""}, :regex_search) do
      pattern = arguments["pattern"].to_s
      group_ref = arguments["group_ref"].to_s
      match = target.to_s.match(Regex.new(pattern))
      if match
        if group_ref.empty?
          match[0]
        else
          index = group_ref.gsub(/\D/, "").to_i?
          index ? match[index]? : nil
        end
      end || Crinja::UNDEFINED
    end

    # `match`/`search` Jinja tests - real Ansible tests
    # (ansible.builtin.match/search), not standard Jinja2. `match`
    # anchors at the start of the string (Python `re.match`), `search`
    # matches anywhere (Python `re.search`) - same distinction as the
    # `regex` test above, which defaults to search-anywhere. Missing
    # from Crinja's core test registry entirely (confirmed via the
    # differential harness, scripts/crinja_corpus/ - `[x] | reject('match',
    # ...)` failed with "no test with name \"match\" registered"; select/
    # reject's filter-form dispatches through `env.tests`, so registering
    # these as TESTS fixes both the `is match(...)` test form and the
    # `select('match', ...)`/`reject('match', ...)` filter form for free).
    Crinja.test(:match) do
      pattern = arguments.varargs[0]?.try(&.to_s) || ""
      !!(target.to_s =~ Regex.new("^(?:#{pattern})"))
    end

    Crinja.test(:search) do
      pattern = arguments.varargs[0]?.try(&.to_s) || ""
      !!(target.to_s =~ Regex.new(pattern))
    end

    # `ne`/`truthy` - real Jinja2 core tests, not Ansible-specific - now
    # registered directly in the fork (weirdbricks/crinja,
    # src/lib/test/tests.cr), not here.

    # `boolean`/`integer`/`float` - real Ansible's own type tests
    # (ansible.plugins.test.core), not standard Jinja2. Crinja's core
    # test registry (lib/crinja/src/lib/test/tests.cr) already has
    # `mapping`/`sequence`/`string`/`number`/`iterable`/`none` natively,
    # but never these three - found via a chained-ternary corpus
    # expression (`value | lower if value is boolean else value`,
    # scripts/crinja_corpus/) that otherwise parsed and ran fine once
    # the no-parens-call-swallows-`else` bug (crinja_no_parens_call_ext.
    # cr) was fixed. This exact type-test set was already fixed once
    # before, round 18 (robertdebock.zabbix_server) - but only in the
    # hand-rolled `ConditionalEvaluator`, never ported to Crinja's own
    # registry, so any of these three reached through a REAL `.j2`
    # template or a `{{ }}` ternary (routed through Crinja, not the
    # hand-rolled evaluator) still failed. `boolean`/`integer` need the
    # real Python distinction that `bool` is a SEPARATE type from `int`
    # even though Crystal's own `Bool`/`Int32`/`Int64` don't have that
    # ambiguity to begin with, so no special-casing needed there.
    Crinja.test(:boolean) { target.raw.is_a?(Bool) }
    Crinja.test(:integer) { target.raw.is_a?(Int32) || target.raw.is_a?(Int64) }
    Crinja.test(:float) { target.raw.is_a?(Float64) }

    # `flatten(levels=none, skip_nulls=true)` - real Ansible's own filter
    # (not standard Jinja2): flattens nested lists, by default completely
    # (`levels:` bounds the depth instead) and dropping `None`/`nil`
    # entries by default (`skip_nulls: false` keeps them). Found via
    # ansible-gitlab-runner's own `[gitlab_runner.get('docker_pull_
    # policy', [])] | flatten` (building a `--docker-pull-policy` CLI arg
    # list that may itself already be a list, hence wrapping in `[...]`
    # first and flattening back down) - entirely unimplemented before,
    # caught only once the differential harness's corpus was widened to
    # scrape whole `{% for %}` blocks (see `scrape_corpus.py`).
    Crinja.filter({levels: nil, skip_nulls: true}, :flatten) do
      levels_arg = arguments["levels"]
      max_depth = levels_arg.raw.nil? ? nil : levels_arg.to_i
      skip_nulls = arguments["skip_nulls"].truthy?

      JinjaFilters.flatten_array(target.each.to_a, max_depth, skip_nulls)
    end

    # :nodoc:
    def self.flatten_array(items : Array(Crinja::Value), max_depth : Int32?, skip_nulls : Bool, depth : Int32 = 0) : Array(Crinja::Value)
      result = [] of Crinja::Value
      items.each do |item|
        raw = item.raw
        if raw.is_a?(Array(Crinja::Value)) && (max_depth.nil? || depth < max_depth)
          result.concat(flatten_array(raw, max_depth, skip_nulls, depth + 1))
        elsif skip_nulls && raw.nil?
          # dropped
        else
          result << item
        end
      end
      result
    end

    # `shuffle(seed=none)` - real Ansible's own filter
    # (ansible.builtin.shuffle, not standard Jinja2): a random permutation
    # of the target list, deterministic when `seed:` is given (real
    # Ansible seeds Python's own `random.Random`, most commonly with
    # `inventory_hostname` - so the same host always gets the same
    # permutation across idempotent reruns, e.g. dev-sec os_hardening's
    # own bcrypt-password generation:
    # `('...alphabet...' | shuffle(seed=inventory_hostname) | join)[:22]`).
    # Deliberately does NOT attempt to replicate Python's own Mersenne-
    # Twister-based `random.Random(seed).shuffle()` permutation bit-for-
    # bit - a different language's PRNG producing a different (but still
    # valid, still deterministic-per-seed) permutation is fine for what
    # this filter is actually used for in practice (idempotent random
    # password/order generation), the same way this codebase doesn't
    # attempt to replicate CPython's exact float-rounding behavior
    # elsewhere either. Seeds Crystal's own `Random` from the given
    # seed's own string content so the SAME seed always reproduces the
    # SAME permutation within crystal-ansible itself, across runs.
    Crinja.filter({seed: nil}, :shuffle) do
      seed_arg = arguments["seed"]
      items = target.each.to_a
      rng = seed_arg.raw.nil? ? Random.new : Random.new(seed_arg.to_s.hash)
      items.shuffle(random: rng)
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
