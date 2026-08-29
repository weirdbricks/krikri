require "crinja"
require "yaml"
require "base64"
require "uuid"
require "openssl/digest"
require "http/client"
require "uri"
require "./variable_substitutor/crinja_renderer"
require "./vault"

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
    # The `style` positional/keyword argument (real Ansible:
    # `comment(text, style='plain', **kw)`) previously silently ignored -
    # only the plain "# "-decorated shape was ever produced, regardless of
    # an explicit `| comment('c')`/`| comment('cblock')`/`| comment('xml')`/
    # `| comment('erlang')` call. Found via robertdebock.php's own
    # `php.ini.j2`: `{{ "..." | comment('c') }}` needs a `//`-commented
    # banner (`;` is php.ini's real comment char, but the role's author
    # chose 'c' style anyway) - crystal-ansible produced a `#`-commented
    # banner instead, silently wrong (not a crash) since `;` isn't even
    # what either style uses, but still a real content divergence from
    # real Ansible's byte-for-byte output. Ported from real Ansible's own
    # `ansible/plugins/filter/core.py#comment` algorithm exactly,
    # including `cblock`'s/`xml`'s distinct `/* ... */`/`<!-- ... -->`
    # begin/end border lines (different from their per-line decoration).
    # Overrides the vendored shard's own `first`/`last` (lib/crinja/src/
    # lib/filter/collections.cr) - real Jinja2's `do_first`/`do_last`
    # raise a clean "No first/last item, sequence was empty." the moment
    # anything touches the result, on a genuinely empty sequence. The
    # vendored version instead let a bare Crystal `Array#first`/`#last`
    # raise its own unhelpful "Index out of bounds" - or, worse, inside
    # `CrinjaRenderer#render`'s bare `rescue` (used for plain `{{ }}`
    # task-param substitution), got silently swallowed into rendering
    # the ORIGINAL unparsed `{{ ... }}` text rather than failing at all.
    # Same real-world trigger as the hand-rolled FilterEngine's own
    # `first`/`last` fix below: `ansible_mounts | selectattr(...) |
    # first` when nothing matches. Deliberately narrow - only the
    # "empty sequence" case gets a real error; a general Undefined-
    # sentinel redesign (covering undefined-variable propagation more
    # broadly) is bigger, separately-deferred work - see
    # KNOWN_MISSING.md.
    Crinja.filter(:first) do
      if target.undefined?
        Crinja::UNDEFINED
      elsif target.sequence? && target.size == 0
        raise Crinja::RuntimeError.new("No first item, sequence was empty.")
      else
        target.first.raw
      end
    end

    Crinja.filter(:last) do
      raise Crinja::RuntimeError.new("No last item, sequence was empty.") if target.sequence? && target.size == 0
      target.last.raw
    end

    Crinja.filter(:comment) do
      style = (arguments.varargs[0]?.try(&.to_s) || arguments.kwargs["style"]?.try(&.to_s) || "plain")

      beginning, style_decoration, ending = case style
                                            when "erlang"
                                              {"", "% ", ""}
                                            when "c"
                                              {"", "// ", ""}
                                            when "cblock"
                                              {"/*", " * ", " */"}
                                            when "xml"
                                              {"<!--", " - ", "-->"}
                                            else
                                              {"", "# ", ""}
                                            end

      prepostfix = arguments.kwargs["decoration"]?.try(&.to_s) || style_decoration
      beginning = arguments.kwargs["beginning"]?.try(&.to_s) || beginning
      ending = arguments.kwargs["end"]?.try(&.to_s) || ending
      decoration = arguments.kwargs["decoration"]?.try(&.to_s) || style_decoration
      prefix = arguments.kwargs["prefix"]?.try(&.to_s) || prepostfix.rstrip
      postfix = arguments.kwargs["postfix"]?.try(&.to_s) || prepostfix.rstrip
      prefix_count = arguments.kwargs["prefix_count"]?.try(&.to_s.to_i) || 1
      postfix_count = arguments.kwargs["postfix_count"]?.try(&.to_s.to_i) || 1

      str_beginning = beginning.empty? ? "" : "#{beginning}\n"
      str_prefix = prefix.empty? ? "" : (["#{prefix}"] * prefix_count).join('\n') + "\n"
      lines = target.to_s.split('\n')
      str_text = lines.map { |line| line.empty? ? decoration.rstrip : "#{decoration}#{line}" }.join('\n')
      str_postfix = (postfix_count > 0 ? ("\n" + (["#{postfix}"] * postfix_count).join('\n')) : "")
      str_end = ending.empty? ? "" : "\n#{ending}"

      commented = "#{str_beginning}#{str_prefix}#{str_text}#{str_postfix}#{str_end}"
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
    # `eth0/100`). `\1`/`\2` group backreferences in *replacement*
    # (Python's `re.sub` syntax) need NO translation - Crystal's own
    # `String#gsub(Regex, String)` already interprets `\1`/`\2` the
    # same way. This used to rewrite them to `$1`/`$2` on the mistaken
    # assumption that Crystal used Ruby-style `$`-backreferences;
    # Crystal's gsub does not special-case `$1` at all, so the
    # "translated" replacement string was emitted completely literally
    # - devsec.hardening.ssh_hardening's own `sshd_version_raw.stderr |
    # regex_replace('.*_([0-9]*.[0-9]).*', '\1')` (parsing `ssh -V`'s
    # output down to a bare version number) produced the literal string
    # "$1" instead of "8.9", which then failed every downstream `is
    # version(...)` when: gate that depends on it.
    Crinja.filter(:regex_replace) do
      pattern = arguments.varargs[0]?.try(&.to_s) || ""
      replacement = arguments.varargs[1]?.try(&.to_s) || ""
      Crinja::Value.new(target.to_s.gsub(Regex.new(pattern), replacement))
    end

    # `hash(algorithm='sha1')` - real Ansible's own filter
    # (ansible.plugins.filter.core), wrapping Python's `hashlib.new()`.
    # Defaults to sha1 when no argument is given, matching real Ansible.
    # Found via geerlingguy.supervisor's own supervisord.conf.j2:
    # `password = {SHA}{{ supervisor_password|hash('sha1') }}` (a
    # standard `{SHA}`-prefixed base64-ish supervisord auth format built
    # on top of the raw hex digest this filter itself returns).
    # `quote` - Ansible's own filter (ansible.builtin.quote), wraps a
    # string in shell-safe quotes (shlex.quote equivalent), used to
    # safely interpolate a value into a shell command or config file
    # line. Crystal's `Process.quote` matches Python's `shlex.quote`
    # byte-for-byte on every case checked (plain strings pass through
    # unquoted, strings with spaces get single-quoted, embedded single
    # quotes get the `'\''`-escape dance, empty string becomes `''`).
    # Found live via prometheus.prometheus.alertmanager's own
    # alertmanager.yml.j2: `resolve_timeout: {{
    # alertmanager_resolve_timeout | quote }}`.
    Crinja.filter(:quote) { Process.quote(target.to_s) }

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
                  when Array        then "list"
                  when Hash         then "dict"
                  when String       then "str"
                  when Int64, Int32 then "int"
                  when Float64      then "float"
                  when Bool         then "bool"
                  when Nil          then "NoneType"
                  else                   "str"
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

    # `to_yaml(**kwargs)` - real Ansible's own filter, real PyYAML
    # default (block style, keys sorted) - same conversion as
    # to_nice_yaml above (Crystal's YAML::Builder has no configurable
    # indent width either way, so the two produce identical output),
    # kept as a separate registration since real Ansible does too.
    Crinja.filter(:to_yaml) do
      any = JinjaFilters.sort_yaml_keys(JinjaFilters.crinja_value_to_yaml_any(target))
      Crinja::Value.new(any.to_yaml.sub(/\A---\n/, "").rstrip)
    end

    # `b64encode(encoding='utf-8')`/`b64decode()` - real Ansible's own
    # filters, standard (not urlsafe) base64. Entirely unregistered
    # before - "no filter with name \"b64encode\" registered", failing
    # the whole template render, same failure class as to_nice_yaml
    # before it was added.
    Crinja.filter(:b64encode) { Crinja::Value.new(Base64.strict_encode(target.to_s)) }
    Crinja.filter(:b64decode) do
      begin
        Crinja::Value.new(Base64.decode_string(target.to_s))
      rescue
        raise "b64decode: invalid base64 input"
      end
    end

    # `from_json()`/`from_yaml()` - real Ansible's own filters, parse a
    # JSON/YAML string into a real Crinja value (dict/list/scalar) -
    # mirrors of to_json/to_nice_yaml above. Converts through
    # CrinjaRenderer.json_any_to_crinja_value (the same JSON::Any ->
    # Crinja::Value converter #prepare_crinja_vars already uses for
    # every ordinary variable) rather than a second hand-rolled one.
    Crinja.filter(:from_json) do
      begin
        CrystalPlay::VariableSubstitutor::CrinjaRenderer.json_any_to_crinja_value(JSON.parse(target.to_s))
      rescue
        raise "from_json: invalid JSON input"
      end
    end
    Crinja.filter(:from_yaml) do
      begin
        CrystalPlay::VariableSubstitutor::CrinjaRenderer.json_any_to_crinja_value(JSON.parse(YAML.parse(target.to_s).to_json))
      rescue
        raise "from_yaml: invalid YAML input"
      end
    end

    # `checksum()` - real Ansible's own filter, always sha1 (distinct
    # from the general-purpose `hash(algorithm=...)` filter above).
    Crinja.filter(:checksum) do
      digest = OpenSSL::Digest.new("SHA1")
      digest.update(target.to_s)
      Crinja::Value.new(digest.final.hexstring)
    end

    # `union(other)` - real Ansible's own filter, set union preserving
    # first-seen order (matches Ansible's own dedup approach - a
    # duplicate within either source list is also collapsed, not just
    # cross-list duplicates).
    Crinja.filter(:union) do
      other = arguments.varargs[0]?
      left = target.sequence? ? target.to_a : [] of Crinja::Value
      right = (other && other.sequence?) ? other.to_a : [] of Crinja::Value
      combined = (left + right).uniq(&.to_s)
      Crinja::Value.new(combined)
    end

    # `path_join()` - real Ansible filter: joins a list of path
    # components with os.path.join semantics (an absolute component
    # resets the accumulated path).
    Crinja.filter(:path_join) do
      parts = target.sequence? ? target.to_a.map(&.to_s) : [] of String
      joined = parts.reduce("") { |acc, part| part.starts_with?('/') ? part : File.join(acc, part) }
      Crinja::Value.new(joined)
    end

    # `splitext()` - real Ansible filter, mirrors Python's
    # os.path.splitext: [root, ext].
    Crinja.filter(:splitext) do
      str = target.to_s
      ext = File.extname(str)
      root = ext.empty? ? str : str[0, str.size - ext.size]
      Crinja::Value.new([root, ext])
    end

    # `urldecode()` - real Ansible filter, percent-decodes a URL-encoded
    # string.
    Crinja.filter(:urldecode) { Crinja::Value.new(URI.decode(target.to_s)) }

    # `urlsplit(query='')` - real Ansible filter: with no argument,
    # returns the full breakdown dict; with a component name argument,
    # returns just that component (real Ansible: the positional/keyword
    # arg is literally named `query` despite selecting any component).
    Crinja.filter({query: ""}, :urlsplit) do
      uri = URI.parse(target.to_s) rescue nil

      if uri
        full = {
          "scheme"   => uri.scheme || "",
          "netloc"   => (uri.host ? "#{uri.host}#{uri.port ? ":#{uri.port}" : ""}" : ""),
          "hostname" => uri.host || "",
          "port"     => uri.port ? uri.port.to_s : "",
          "path"     => uri.path || "",
          "query"    => uri.query || "",
          "fragment" => uri.fragment || "",
          "username" => uri.user || "",
          "password" => uri.password || "",
        }
        component = arguments["query"].to_s
        component.empty? ? Crinja::Value.new(full) : Crinja::Value.new(full[component]? || "")
      else
        Crinja::Value.new(nil)
      end
    end

    # `zip(other1, other2=None)`/`zip_longest(other1, other2=None,
    # fillvalue=None)` - real Ansible filters, Python's own zip()/
    # itertools.zip_longest(). Declared-keyword-args form (not the plain
    # block form - see the `version` test's own comment on why: multiple
    # positional arguments don't reliably split via `arguments.varargs`)
    # caps this at up to 2 extra list arguments (3-way zip total) -
    # covers the overwhelming majority of real-world usage; a real 4+way
    # zip would need a different registration approach entirely.
    {% for name in [:zip, :zip_longest] %}
      Crinja.filter({other1: Crinja::UNDEFINED, other2: Crinja::UNDEFINED, fillvalue: Crinja::UNDEFINED}, {{ name }}) do
        longest = {{ name.stringify }} == "zip_longest"
        lists = [target] + [arguments["other1"], arguments["other2"]].reject(&.undefined?)
        arrays = lists.map { |l| l.sequence? ? l.to_a : [] of Crinja::Value }
        fillvalue = arguments["fillvalue"].undefined? ? Crinja::Value.new(nil) : arguments["fillvalue"]
        size = longest ? (arrays.map(&.size).max? || 0) : (arrays.map(&.size).min? || 0)
        rows = (0...size).map { |i| Crinja::Value.new(arrays.map { |arr| arr[i]? || fillvalue }) }
        Crinja::Value.new(rows)
      end
    {% end %}

    # `product(other1, other2=None)` - real Ansible filter, Python's own
    # itertools.product(): Cartesian product of target and every other
    # list argument. Same up-to-2-extra-lists cap as zip above.
    Crinja.filter({other1: Crinja::UNDEFINED, other2: Crinja::UNDEFINED}, :product) do
      lists = [target] + [arguments["other1"], arguments["other2"]].reject(&.undefined?)
      arrays = lists.map { |l| l.sequence? ? l.to_a : [] of Crinja::Value }
      result = arrays.reduce([[] of Crinja::Value]) do |acc, arr|
        acc.flat_map { |row| arr.map { |item| row + [item] } }
      end
      Crinja::Value.new(result.map { |row| Crinja::Value.new(row) })
    end

    # `regex_escape(re_type='python')` - real Ansible filter, escapes
    # regex special characters.
    Crinja.filter(:regex_escape) { Crinja::Value.new(Regex.escape(target.to_s)) }

    # `to_nice_json(indent=4, sort_keys=True)` - real Ansible filter, a
    # pretty-printed JSON dump (mirrors to_nice_yaml above). Converts via
    # crinja_value_to_yaml_any -> to_json (round-tripping through the
    # same YAML::Any conversion to_nice_yaml already uses, since Crystal
    # doesn't have a direct Crinja::Value -> JSON serializer here) rather
    # than a hand-rolled one; Crystal's own JSON#to_pretty_json (2-space
    # indent) is used rather than a 4-space emitter - same scope limit
    # to_nice_yaml's own indent= already documents.
    Crinja.filter(:to_nice_json) do
      sort_keys = arguments.kwargs["sort_keys"]?.try { |v| JinjaFilters.real_truthy?(v) }
      sort_keys = true if sort_keys.nil?

      any = JinjaFilters.crinja_value_to_yaml_any(target)
      any = JinjaFilters.sort_yaml_keys(any) if sort_keys
      Crinja::Value.new(JSON.parse(any.to_json).to_pretty_json)
    end

    # `human_readable(isbits=False, unit=None)`/`human_to_bytes(
    # default_unit=None, isbits=False)` - real Ansible filters (bytes
    # count <-> "1.00 KB"-style string), both base-1024 (isbits: selects
    # the bit-suffix table and multiplies by 8 first, real Ansible does
    # NOT switch to base-1000 for bits).
    HUMAN_READABLE_SUFFIXES     = {"Bytes", "KB", "MB", "GB", "TB", "PB", "EB", "ZB", "YB"}
    HUMAN_READABLE_BIT_SUFFIXES = {"bits", "Kb", "Mb", "Gb", "Tb", "Pb", "Eb", "Zb", "Yb"}

    def self.format_human_readable(bytes : Int64, isbits : Bool) : String
      value = isbits ? bytes.to_f * 8 : bytes.to_f
      suffixes = isbits ? HUMAN_READABLE_BIT_SUFFIXES : HUMAN_READABLE_SUFFIXES
      suffixes.each_with_index do |suffix, i|
        unit = 1024.0 ** i
        next_unit = 1024.0 ** (i + 1)
        if value < next_unit || i == suffixes.size - 1
          return i == 0 ? "#{value.to_i} #{suffix}" : "%.2f %s" % [value / unit, suffix]
        end
      end
      "#{bytes} Bytes"
    end

    def self.parse_human_to_bytes(str : String) : Int64
      match = str.strip.match(/^([\d.]+)\s*([A-Za-z]*)$/)
      return str.to_i64? || 0_i64 unless match

      number = match[1].to_f
      unit = match[2].downcase
      multiplier = case unit
                   when "", "b", "bytes" then 1_i64
                   when "kb"             then 1024_i64
                   when "mb"             then 1024_i64 ** 2
                   when "gb"             then 1024_i64 ** 3
                   when "tb"             then 1024_i64 ** 4
                   when "pb"             then 1024_i64 ** 5
                   else                       1_i64
                   end
      (number * multiplier).to_i64
    end

    Crinja.filter(:human_readable) do
      isbits = arguments.kwargs["isbits"]?.try { |v| JinjaFilters.real_truthy?(v) } || false
      bytes = target.to_s.to_i64? || 0_i64
      Crinja::Value.new(JinjaFilters.format_human_readable(bytes, isbits))
    end
    Crinja.filter(:human_to_bytes) { Crinja::Value.new(JinjaFilters.parse_human_to_bytes(target.to_s)) }

    # `md5()`/`sha1()` - real Ansible filters, standalone hex digests
    # (distinct from the general `hash(algorithm=)` filter above).
    Crinja.filter(:md5) do
      digest = OpenSSL::Digest.new("MD5")
      digest.update(target.to_s)
      Crinja::Value.new(digest.final.hexstring)
    end
    Crinja.filter(:sha1) do
      digest = OpenSSL::Digest.new("SHA1")
      digest.update(target.to_s)
      Crinja::Value.new(digest.final.hexstring)
    end

    # `expanduser()`/`expandvars()` - real Ansible filters, mirror
    # Python's os.path.expanduser/expandvars (a leading `~` -> $HOME;
    # `$VAR`/`${VAR}` -> the controller's own environment, unset left
    # as-is).
    Crinja.filter(:expanduser) do
      str = target.to_s
      home = ENV["HOME"]? || ""
      Crinja::Value.new(str.starts_with?("~/") ? File.join(home, str[2..]) : (str == "~" ? home : str))
    end
    Crinja.filter(:expandvars) do
      expanded = target.to_s.gsub(/\$\{(\w+)\}|\$(\w+)/) do |match|
        name = $1? || $2?
        name ? (ENV[name]? || match) : match
      end
      Crinja::Value.new(expanded)
    end

    # `normpath()`/`relpath(start='.')`/`commonpath()` - real Ansible
    # filters, mirror Python's os.path.normpath/relpath/commonpath.
    def self.normalize_path(path : String) : String
      return "." if path.empty?
      absolute = path.starts_with?('/')
      parts = path.split('/').reject { |p| p.empty? || p == "." }

      result = [] of String
      parts.each do |part|
        if part == ".." && !result.empty? && result.last != ".."
          result.pop
        elsif part == ".." && !absolute
          result << part
        elsif part != ".."
          result << part
        end
      end

      joined = result.join("/")
      absolute ? "/#{joined}" : (joined.empty? ? "." : joined)
    end

    def self.common_path(paths : Array(String)) : String
      return "" if paths.empty?
      segments = paths.map { |p| p.split('/').reject(&.empty?) }
      first = segments.first
      common = first.each_with_index.take_while { |seg, i| segments.all? { |s| s[i]? == seg } }.map(&.[0])
      prefix = paths.first.starts_with?('/') ? "/" : ""
      "#{prefix}#{common.join("/")}"
    end

    Crinja.filter(:normpath) { Crinja::Value.new(JinjaFilters.normalize_path(target.to_s)) }
    Crinja.filter({start: "."}, :relpath) do
      Crinja::Value.new(Path[target.to_s].relative_to(Path[arguments["start"].to_s]).to_s)
    end
    Crinja.filter(:commonpath) do
      paths = target.sequence? ? target.to_a.map(&.to_s) : [] of String
      Crinja::Value.new(JinjaFilters.common_path(paths))
    end

    # `log(base=math.e)`/`pow(x)` - real Ansible filters.
    Crinja.filter({base: Crinja::UNDEFINED}, :log) do
      num = target.to_s.to_f? || 0.0
      base_arg = arguments["base"]
      Crinja::Value.new(base_arg.undefined? ? Math.log(num) : Math.log(num, base_arg.to_s.to_f? || Math::E))
    end
    Crinja.filter({x: 0}, :pow) do
      num = target.to_s.to_f? || 0.0
      Crinja::Value.new(num ** (arguments["x"].to_s.to_f? || 0.0))
    end

    # `to_uuid(namespace=ANSIBLE_NAMESPACE)` - real Ansible filter, a
    # deterministic UUID5 using Ansible's own default namespace (not the
    # standard DNS namespace).
    Crinja.filter(:to_uuid) do
      Crinja::Value.new(UUID.v5(target.to_s, UUID.new("361E6D51-FAEC-444A-9079-341386DA8E2E")).to_s)
    end

    # `symmetric_difference(other)` - real Ansible filter: elements in
    # exactly one of target/other, not both.
    Crinja.filter(:symmetric_difference) do
      other = arguments.varargs[0]?
      left = (target.sequence? ? target.to_a : [] of Crinja::Value).uniq(&.to_s)
      right = (other && other.sequence? ? other.to_a : [] of Crinja::Value).uniq(&.to_s)
      result = left.reject { |i| right.any? { |r| r.to_s == i.to_s } } + right.reject { |i| left.any? { |l| l.to_s == i.to_s } }
      Crinja::Value.new(result)
    end

    # `combinations(n)`/`permutations(n=None)` - real Ansible filters,
    # Python's own itertools.combinations()/itertools.permutations().
    def self.combinations(array : Array(Crinja::Value), n : Int32) : Array(Array(Crinja::Value))
      return [[] of Crinja::Value] if n == 0
      return [] of Array(Crinja::Value) if n > array.size || array.empty?
      head = array.first
      tail = array[1..]
      combinations(tail, n - 1).map { |c| [head] + c } + combinations(tail, n)
    end

    def self.permutations(array : Array(Crinja::Value), n : Int32) : Array(Array(Crinja::Value))
      return [[] of Crinja::Value] if n == 0
      return [] of Array(Crinja::Value) if n > array.size || array.empty?
      result = [] of Array(Crinja::Value)
      array.each_with_index do |item, i|
        rest = array[0...i] + array[(i + 1)..]
        permutations(rest, n - 1).each { |p| result << ([item] + p) }
      end
      result
    end

    Crinja.filter({n: 2}, :combinations) do
      arr = target.sequence? ? target.to_a : [] of Crinja::Value
      Crinja::Value.new(JinjaFilters.combinations(arr, arguments["n"].to_i).map { |c| Crinja::Value.new(c) })
    end
    Crinja.filter({n: Crinja::UNDEFINED}, :permutations) do
      arr = target.sequence? ? target.to_a : [] of Crinja::Value
      n = arguments["n"].undefined? ? arr.size : arguments["n"].to_i
      Crinja::Value.new(JinjaFilters.permutations(arr, n).map { |p| Crinja::Value.new(p) })
    end

    # `rekey_on_member(member, duplicates='error')` - real Ansible
    # filter: converts a list of dicts into a dict keyed by each
    # element's own `member` field value.
    Crinja.filter({member: "", duplicates: "error"}, :rekey_on_member) do
      member = arguments["member"].to_s
      duplicates = arguments["duplicates"].to_s
      result = Crinja::Dictionary.new
      arr = target.sequence? ? target.to_a : [] of Crinja::Value
      arr.each do |item|
        key = item.raw.is_a?(Crinja::Dictionary) ? item.raw.as(Crinja::Dictionary)[Crinja::Value.new(member)]? : nil
        next unless key
        key_str = Crinja::Value.new(key.to_s)
        if duplicates == "error" && result.has_key?(key_str)
          raise "rekey_on_member: duplicate key '#{key}'"
        end
        result[key_str] = item
      end
      Crinja::Value.new(result)
    end

    # `extract(container, morekeys=None)` - real Ansible filter: target
    # is used as an index/key into *container*.
    Crinja.filter({container: Crinja::UNDEFINED, morekeys: Crinja::UNDEFINED}, :extract) do
      container = arguments["container"]
      extracted = case raw = container.raw
                  when Array(Crinja::Value)
                    idx = target.to_s.to_i?
                    idx ? raw[idx]? : nil
                  when Crinja::Dictionary
                    raw[Crinja::Value.new(target.to_s)]?
                  else
                    nil
                  end

      if extracted && !arguments["morekeys"].undefined?
        morekeys = arguments["morekeys"]
        keys = morekeys.sequence? ? morekeys.to_a.map(&.to_s) : [morekeys.to_s]
        keys.reduce(extracted) { |acc, key| acc.raw.is_a?(Crinja::Dictionary) ? (acc.raw.as(Crinja::Dictionary)[Crinja::Value.new(key)]? || Crinja::Value.new(nil)) : Crinja::Value.new(nil) }
      else
        extracted || Crinja::Value.new(nil)
      end
    end

    # `from_yaml_all()` - real Ansible filter: parses a multi-document
    # YAML string (`---`-separated) into a list of parsed documents.
    Crinja.filter(:from_yaml_all) do
      docs = target.to_s.split(/^---\s*$/m).map(&.strip).reject(&.empty?)
      values = docs.map { |doc| CrystalPlay::VariableSubstitutor::CrinjaRenderer.json_any_to_crinja_value(JSON.parse(YAML.parse(doc).to_json)) }
      Crinja::Value.new(values)
    end

    # `vault(secret, vault_id=None, salt=None)`/`unvault(secret)` - real
    # Ansible filters: encrypt/decrypt ansible-vault ciphertext using
    # *secret* as an explicit filter-argument password (NOT the session-
    # wide --vault-password-file/--ask-vault-pass secret).
    Crinja.filter({secret: ""}, :vault) do
      Crinja::Value.new(CrystalPlay::Vault.encrypt(target.to_s, arguments["secret"].to_s))
    end
    Crinja.filter({secret: ""}, :unvault) do
      Crinja::Value.new(CrystalPlay::Vault.decrypt(target.to_s, arguments["secret"].to_s))
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
    # Real bug found live benchmarking prometheus.prometheus.prometheus
    # (round 30): `arguments.varargs` for a test registered via the
    # plain `Crinja.test(:name) do ... end` block form (no declared
    # keyword args) does NOT reliably split multiple positional test
    # arguments (`is version('2.7.0', '>=')`) into separate varargs
    # entries - confirmed by instrumenting this exact test: called with
    # 2 positional args, `arguments.varargs` came back with size 1,
    # its single element a Crinja::Value WRAPPING AN ARRAY of both
    # arguments together, so `arguments.varargs[1]?` (the operator) was
    # always nil and silently defaulted to "==" regardless of what was
    # actually passed - `is version(X, '<')`/`'>'`/`'>='`/etc all
    # silently behaved as `is version(X, '==')` instead. The DECLARED-
    # keyword-args form (`Crinja.test({key: default}, :name) do ...
    # end`, already used correctly elsewhere in this file for multi-arg
    # filters like `regex_search`) doesn't have this bug - positional
    # args bind correctly to the declared keyword names. Switched both
    # `version` and `version_compare` to that form.
    Crinja.test({compare_to: "", operator: "=="}, :version) do
      JinjaFilters.version_test(target.to_s, arguments["compare_to"].to_s, arguments["operator"].to_s)
    end

    # `version_compare` - deprecated alias for `version` (identical
    # signature/semantics), still emitted by real Ansible collection
    # templates (e.g. prometheus.prometheus's `systemd.service.j2`:
    # `{%- if (alertmanager_version is version_compare('0.13.0', '>=')) %}`).
    # Real Ansible's `version` test module registers both names for the
    # exact same implementation; Crinja only had `version` registered
    # here, so any template using the deprecated spelling failed its
    # entire render ("no test with name 'version_compare' registered" -
    # Crinja has no partial-render fallback). Found live benchmarking
    # prometheus.prometheus.alertmanager (round 26).
    Crinja.test({compare_to: "", operator: "=="}, :version_compare) do
      JinjaFilters.version_test(target.to_s, arguments["compare_to"].to_s, arguments["operator"].to_s)
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

    # `fileglob` - real Ansible's ansible.builtin.fileglob LOOKUP plugin,
    # usable as a filter via `map('ansible.builtin.fileglob')` (as
    # opposed to the separate `with_fileglob:` loop keyword, which
    # #resolve_fileglob in task_executor/executor.cr already handles -
    # this is the *filter* form, entirely unregistered before, so
    # `map('ansible.builtin.fileglob')` silently passed each glob
    # PATTERN STRING through unchanged instead of expanding it. Real
    # Ansible's own lookup returns the empty list for a pattern matching
    # no files (not an error) - `flatten` on the mapped results then
    # correctly produces an empty overall list, and a `loop:` over that
    # is skipped entirely, matching real Ansible. Without this, a
    # pattern matching nothing was instead treated as ONE loop item -
    # the literal, unexpanded glob string itself - which then failed
    # downstream ("Source file not found: rules/*.yml"). Found live
    # benchmarking prometheus.prometheus.prometheus (round 30)'s own
    # "Copy custom alerting rule files" task, whose default
    # `prometheus_alert_rules_files: [prometheus/rules/*.yml,
    # prometheus/rules/*.yaml]` matches nothing on a fresh install and
    # should skip cleanly, matching real Ansible's `skipping: [target]`.
    Crinja.filter(:fileglob) { Crinja::Value.new(Dir.glob(target.to_s).sort!) }

    # `realpath` - real Ansible's ansible.builtin.realpath filter,
    # resolving a path to its canonical absolute form (symlinks
    # resolved). Chained after `fileglob` in the same real-world idiom
    # above (`... | map('ansible.builtin.fileglob') | flatten |
    # map('ansible.builtin.realpath')`) - also entirely unregistered.
    Crinja.filter(:realpath) { File.realpath(target.to_s) }

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

    # `dict2items(key_name='key', value_name='value')` - real Ansible's
    # own filter (NOT standard Jinja2; the Crinja corpus confirms
    # Python/Jinja2 reject it as "No filter named 'dict2items'"),
    # converts a dict to a list of `{key_name: k, value_name: v}` items
    # so `{% for item in my_dict | dict2items %}` can iterate. The Crinja
    # side is needed alongside the hand-rolled FilterEngine version
    # because a `.j2` template's `{% for %}` block tag chain routes
    # through Crinja's own filter pipeline, not FilterEngine. dev-sec
    # os_hardening's `loop: "{{ os_vars | dict2items }}"` shape hits
    # FilterEngine (plain `{{ }}`), but a hypothetical
    # `{% for item in my_dict | dict2items %}` would hit THIS filter,
    # and a real-world role using a `.j2` template with a dict-iterating
    # for-loop needs both sides wired. Same defaults / kwarg shape as
    # FilterEngine's version (defaults to `key`/`value`; the kwarg
    # override path matches FilterEngine exactly so a role that
    # switches between `{{ }}` and `{% %}` usage gets the same output).
    # Ordered Hash iteration in Crystal preserves insertion order, which
    # matches CPython 3.7+ dict semantics and the implicit ordering
    # Ansible users have come to depend on.
    Crinja.filter({key_name: "key", value_name: "value"}, :dict2items) do
      key_name = arguments["key_name"].to_s
      value_name = arguments["value_name"].to_s
      base = target.raw

      # A genuinely UNDEFINED input is fatal in real Ansible ("dict2items
      # requires a dictionary, got ...AnsibleUndefined"), not an empty
      # result - differentialed against ansible-core 2.19.4, where every
      # filter except default/d/type_debug fails on an undefined value.
      # Same bug the hand-rolled evaluator had (see CrystalPlay.
      # undefined_filter_chain_source), found and fixed independently on
      # each side per this repo's CLAUDE.md: `{{ nope | dict2items }}`
      # in a real .j2 rendered as `[]` and the template task succeeded.
      # `{{ nope | default({}) | dict2items }}` is untouched - default
      # has already replaced the Undefined by the time this runs.
      raise Crinja::UndefinedError.new(base.name.presence || "dict2items input") if base.is_a?(Crinja::Undefined)

      if base.is_a?(Hash)
        Crinja::Value.new(base.map { |k, v| {key_name => k, value_name => v} })
      else
        Crinja::Value.new([] of Crinja::Value)
      end
    end

    # `items2dict(key_name='key', value_name='value')` - the inverse of
    # dict2items: takes a list of dicts (each carrying a `key_name`
    # field and a `value_name` field) and produces a single dict mapping
    # key_name -> value_name. Real Ansible's own filter, same
    # Python-ansible-only status as dict2items. Mirrors FilterEngine's
    # implementation: elements that aren't dicts or that don't carry
    # the named key field are silently dropped; on a key collision
    # later in the list wins (matches `combine`'s own later-wins
    # precedence). Same kwarg API as FilterEngine.
    Crinja.filter({key_name: "key", value_name: "value"}, :items2dict) do
      key_name = arguments["key_name"].to_s
      value_name = arguments["value_name"].to_s
      result = {} of Crinja::Value => Crinja::Value
      # Same strict-undefined requirement as dict2items above.
      raw_target = target.raw
      raise Crinja::UndefinedError.new(raw_target.name.presence || "items2dict input") if raw_target.is_a?(Crinja::Undefined)
      target.each do |item|
        next unless item.raw.is_a?(Hash)
        h = item.raw.as(Hash)
        k = h[key_name]?
        next unless k
        v = h[value_name]?
        result[k] = v if v
      end
      Crinja::Value.new(result)
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
    # instead of the whole match. No match resolves to Python None/JSON
    # null - real Ansible's own return value (NOT undefined), so a
    # downstream `is not none` sees the miss and `| default(...)` without
    # a truthy second arg does not fire, same as real Jinja. Found
    # missing there via konstruktoid-hardening's own `sshd_version.
    # stderr_lines | regex_search('OpenSSH_(...)', '\\1') | first`.
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
      end || nil
    end

    # `regex_findall(pattern, multiline=False, ignorecase=False)` - real
    # Ansible's own filter (Python `re.findall`): returns every non-
    # overlapping match. With no capture groups, each match is the
    # whole matched substring; with capture groups, each match is a
    # list of that match's group strings (Python returns a tuple, but
    # this codebase already represents everything JSON-compatible, so
    # a list, matching how ExpressionEvaluator/FilterEngine already
    # render tuple-shaped values elsewhere). Entirely unimplemented
    # before - real bug found live-verifying prometheus.prometheus.
    # node_exporter: its own _common role builds a checksum-filename
    # lookup with `raw.splitlines() | map('regex_findall', '^([a-fA-
    # F0-9]+)\\s+(.+)$') | ...` - silently a no-op (each line passed
    # through unchanged instead of being split into [checksum,
    # filename]), so the whole checksum dict ended up empty and every
    # download failed its checksum verification.
    Crinja.filter({pattern: Crinja::UNDEFINED, multiline: false, ignorecase: false}, :regex_findall) do
      pattern = arguments["pattern"].to_s
      options = Regex::Options::None
      options |= Regex::Options::MULTILINE if arguments["multiline"].truthy?
      options |= Regex::Options::IGNORE_CASE if arguments["ignorecase"].truthy?
      regex = Regex.new(pattern, options)

      target.to_s.scan(regex).map do |match|
        if match.size > 1
          (1...match.size).map { |i| match[i]? || "" }
        else
          match[0]
        end
      end
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
    # `is any`/`is all` - real Jinja2 (3.0+) built-in tests checking
    # whether any/every item of an iterable is truthy (Python's
    # `any()`/`all()` builtins applied to the sequence, not a Jinja
    # test in vanilla Python but promoted to a test in Jinja2 itself).
    # Neither was registered in the fork at all - found live via
    # prometheus.prometheus.alertmanager's own `systemd.service.j2`:
    # `{% if (alertmanager_web_config.values() | map('length') |
    # select('gt', 0) | list is any) %}`.
    Crinja.test(:any) { target.each.any?(&.truthy?) }
    Crinja.test(:all) { target.each.all?(&.truthy?) }

    # `subset`/`superset`/`contains` - real Ansible's own tests
    # (ansible.builtin, not standard Jinja2), common in `assert:`-heavy
    # hardening roles checking one list/dict against another. Entirely
    # unregistered before - "no test with name \"subset\" registered",
    # failing the whole template render.
    Crinja.test({other: [] of Crinja::Value}, :subset) do
      other = arguments["other"]
      other_arr = other.sequence? ? other.to_a : [] of Crinja::Value
      target_arr = target.sequence? ? target.to_a : [] of Crinja::Value
      target_arr.all? { |item| other_arr.includes?(item) }
    end
    Crinja.test({other: [] of Crinja::Value}, :superset) do
      other = arguments["other"]
      other_arr = other.sequence? ? other.to_a : [] of Crinja::Value
      target_arr = target.sequence? ? target.to_a : [] of Crinja::Value
      other_arr.all? { |item| target_arr.includes?(item) }
    end
    # `contains(item)` - Python's `item in a` for whichever container
    # shape *a* (target) actually is.
    Crinja.test({other: nil}, :contains) do
      other = arguments["other"]
      case raw = target.raw
      when Array(Crinja::Value)
        raw.includes?(other)
      when Crinja::Dictionary
        raw.has_key?(Crinja::Value.new(other.to_s))
      when String
        raw.includes?(other.to_s)
      else
        false
      end
    end

    # `exists`/`file`/`directory`/`link`/`link_exists`/`same_file(other)`
    # - real Ansible's own path-check tests, always against the
    # CONTROLLER's filesystem (same as `lookup('file', ...)` above -
    # these are plain os.path.* wrappers running in the controller's own
    # Python process, never the target's).
    Crinja.test(:exists) { File.exists?(target.to_s) }
    Crinja.test(:file) { File.file?(target.to_s) }
    Crinja.test(:directory) { Dir.exists?(target.to_s) }
    Crinja.test(:link) { File.symlink?(target.to_s) }
    Crinja.test(:link_exists) { !!File.info?(target.to_s, follow_symlinks: false) }
    Crinja.test({other: ""}, :same_file) do
      path1 = target.to_s
      path2 = arguments["other"].to_s
      (File.exists?(path1) && File.exists?(path2)) ? File.same?(path1, path2) : false
    end

    # `mount` - real Ansible test, real os.path.ismount(). Shells to the
    # real `mountpoint(8)` utility (util-linux), same approach the
    # ConditionalEvaluator copy of this test takes.
    Crinja.test(:mount) { Process.run("mountpoint", ["-q", target.to_s]).success? rescue false }

    # `vault_encrypted`/`vaulted_file` - real Ansible tests:
    # vault_encrypted checks a STRING value's own content; vaulted_file
    # reads a path (on the CONTROLLER) and checks its content.
    Crinja.test(:vault_encrypted) { CrystalPlay::Vault.encrypted?(target.to_s) }
    Crinja.test(:vaulted_file) do
      content = File.read(target.to_s) rescue nil
      content ? CrystalPlay::Vault.encrypted?(content) : false
    end

    # `urn` - real Ansible test: validates the value is a syntactically
    # well-formed URN (RFC 8141: "urn:<nid>:<nss>").
    URN_PATTERN = /^urn:[a-zA-Z0-9][a-zA-Z0-9-]{0,31}:[a-zA-Z0-9()+,\-.:=@;$_!*'%\/?#]+$/i
    Crinja.test(:urn) { !!(target.to_s =~ URN_PATTERN) }

    # `started`/`finished`/`timedout`/`reachable`/`unreachable` - real
    # Ansible tests on a registered result dict (`async_status:`/
    # `wait_for_connection:` shape). `started:`/`finished:` are a plain
    # INTEGER 0/1 in that real result shape, not a JSON bool - checked
    # for either a truthy bool or a non-zero number, same as the
    # ConditionalEvaluator copy of this test. "reachable" inverts the
    # SAME `unreachable` field real Ansible's own implementation checks.
    def self.async_field_truthy?(target : Crinja::Value, field : String) : Bool
      value = target[field]
      return false if value.undefined?
      case raw = value.raw
      when Bool         then raw
      when Int32, Int64 then raw != 0
      else                   false
      end
    end

    Crinja.test(:started) { JinjaFilters.async_field_truthy?(target, "started") }
    Crinja.test(:finished) { JinjaFilters.async_field_truthy?(target, "finished") }
    Crinja.test(:timedout) { JinjaFilters.async_field_truthy?(target, "timedout") }
    Crinja.test(:unreachable) { JinjaFilters.async_field_truthy?(target, "unreachable") }
    Crinja.test(:reachable) { !JinjaFilters.async_field_truthy?(target, "unreachable") }

    # Real Jinja2's comparison-operator test aliases - used almost
    # exclusively as a `select()`/`reject()`/`map(attribute=...)`
    # predicate name (`values() | select('gt', 0)`), not written
    # directly as `is gt(...)` in a template. The fork already
    # registers `equalto`/`lessthan`/`greaterthan`/`ne` (see
    # tests.cr) but not the short `eq`/`lt`/`le`/`gt`/`ge` spellings
    # real Jinja2 registers as aliases of the same tests. Found live
    # via prometheus.prometheus.alertmanager's own systemd.service.j2:
    # `select('gt', 0)`.
    Crinja.test({other: 0}, :eq) { target == arguments["other"] }
    Crinja.test({other: 0}, :lt) { target.to_i < arguments["other"].to_i }
    Crinja.test({other: 0}, :le) { target.to_i <= arguments["other"].to_i }
    Crinja.test({other: 0}, :gt) { target.to_i > arguments["other"].to_i }
    Crinja.test({other: 0}, :ge) { target.to_i >= arguments["other"].to_i }

    Crinja.test(:boolean) { target.raw.is_a?(Bool) }

    # `failed`/`changed`/`skipped`/`succeeded`/`success` - real Ansible's
    # own register-result introspection tests (`{{ some_result is failed
    # }}`), not standard Jinja2 at all. Reads the named field off a
    # registered task result dict; "succeeded"/"success" aren't real
    # result-dict keys (Ansible doesn't store a positive "it worked"
    # flag, only "failed"), so both are the inverse of "failed" instead.
    # A field genuinely absent defaults to false, matching real Ansible's
    # own tests never raising for a missing field. Ported from
    # `ConditionalEvaluator.result_field` (used for bare `when:`/
    # `failed_when:` conditions) so the SAME test names work identically
    # inside a real `{{ }}`/`.j2` expression routed through Crinja, not
    # just a bare condition - needed before any hand-rolled-evaluator
    # construct that might use these (like the `boolean_logic?` branch
    # in expression_evaluator.cr) can safely delegate to Crinja instead.
    def self.result_field(target : Crinja::Value, field : String) : Bool
      case raw = target.raw
      when Hash(String, Crinja::Value)
        raw[field]?.try(&.truthy?) || false
      when Hash(Crinja::Value, Crinja::Value)
        raw[Crinja::Value.new(field)]?.try(&.truthy?) || false
      else
        false
      end
    end

    Crinja.test(:failed) { JinjaFilters.result_field(target, "failed") }
    Crinja.test(:failure) { JinjaFilters.result_field(target, "failed") }
    Crinja.test(:changed) { JinjaFilters.result_field(target, "changed") }
    Crinja.test(:change) { JinjaFilters.result_field(target, "changed") }
    Crinja.test(:skipped) { JinjaFilters.result_field(target, "skipped") }
    Crinja.test(:skip) { JinjaFilters.result_field(target, "skipped") }
    Crinja.test(:succeeded) { !JinjaFilters.result_field(target, "failed") }
    Crinja.test(:success) { !JinjaFilters.result_field(target, "failed") }
    Crinja.test(:successful) { !JinjaFilters.result_field(target, "failed") }
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

    # `to_datetime(format='%Y-%m-%d %H:%M:%S')` - real Ansible's own
    # filter (ansible.plugins.filter.core), parses a string into a
    # datetime object that real Ansible's Jinja2 can then do arithmetic
    # on. dev-sec os_hardening's own password-ageing verification parses
    # `chage -l`'s date output this way, then subtracts two of them for a
    # day-count assert: `( a | to_datetime(...) - b | to_datetime(...)
    # ).days`. Not shipped in the general-purpose fork (Ansible-specific);
    # registered here, producing a real `Crinja::Value` wrapping a
    # `::Time` - the "Crinja-side Time type" this file previously had no
    # way to produce (CRINJA.md's documented reason it was never
    # registered). Subtraction between two such values works via the
    # fork's `-`/TimeDelta support (crystal-play-0.9.5); the hand-rolled
    # FilterEngine#parse_to_datetime tagged-JSON path is unchanged and
    # remains the fallback. On an unparseable string, raising routes the
    # whole expression to that fallback (which yields nil, matching prior
    # behavior) rather than crashing.
    Crinja.filter({format: "%Y-%m-%d %H:%M:%S"}, :to_datetime) do
      format = arguments["format"].to_s
      Crinja::Value.new(Time.parse(target.to_s, format, Time::Location::UTC))
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

    # Shared by the `version`/`version_compare` Crinja tests above.
    def self.version_test(target : String, compare_to : String, operator : String) : Bool
      cmp = compare_versions(target, compare_to)
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

    # `lookup(type, arg1, ...)` - real Ansible's own Jinja global
    # function, callable directly from a `.j2` template file (not just a
    # bare `{{ }}` task param, the only path ExpressionEvaluator's own
    # #evaluate_lookup covered before this). Was entirely unregistered
    # in Crinja before - "no function with name \"lookup\"", failing the
    # whole template render.
    #
    # Mirrors all of ExpressionEvaluator#evaluate_lookup's lookup types,
    # including url/first_found (ported once a real template actually
    # needed one, per the note this comment used to carry).
    #
    # Declared keyword-args form (`Crinja.function({...}, :lookup)`), not
    # the plain block form - found the hard way (see the `version` test
    # above's own comment) that `arguments.varargs` for the plain form
    # doesn't reliably split multiple positional arguments into separate
    # entries.
    # Capped at 4 extra positional args (a1..a4) beyond `type` - covers
    # every lookup type registered below (the widest, `subelements`,
    # needs 3; the variadic ones - list/items/together/nested/varnames/
    # random_choice - are capped at 4 combined terms, same "declared-
    # keyword-args form can't be truly variadic" tradeoff zip/product
    # filters already made above).
    Crinja.function({type: "", a1: Crinja::UNDEFINED, a2: Crinja::UNDEFINED, a3: Crinja::UNDEFINED, a4: Crinja::UNDEFINED}, :lookup) do
      lookup_type = arguments["type"].to_s
      arg1 = arguments["a1"]
      role_path_value = env.context["role_path"]
      role_path = role_path_value.undefined? ? nil : role_path_value.to_s
      variadic_terms = [arguments["a1"], arguments["a2"], arguments["a3"], arguments["a4"]].reject(&.undefined?)

      case lookup_type
      when "env"
        var_name = arg1.to_s
        Crinja::Value.new(var_name.empty? ? "" : (ENV[var_name]? || ""))
      when "config"
        # Multi-arg config lookup - see ExpressionEvaluator's own config
        # branch for the full rationale (buluma.multi, round 190).
        names = variadic_terms.map(&.to_s).reject { |t| t.downcase.starts_with?("wantlist=") || t.empty? }
        values = names.map { |n| JinjaFilters.ansible_config_value(n) }
        if names.size > 1 || variadic_terms.any? { |t| t.to_s.downcase.starts_with?("wantlist=true") }
          Crinja::Value.new(values)
        else
          Crinja::Value.new(values[0]? || "")
        end
      when "vars"
        name = arg1.to_s
        name.empty? ? Crinja::Value.new(nil) : env.context[name]
      when "file"
        path = arg1.to_s
        resolved = JinjaFilters.resolve_lookup_path(path, role_path)
        begin
          Crinja::Value.new(File.read(resolved).chomp)
        rescue
          Crinja::Value.new(nil)
        end
      when "pipe"
        command = arg1.to_s
        begin
          output = IO::Memory.new
          status = Process.run("/bin/sh", ["-c", command], output: output, error: Process::Redirect::Close)
          status.success? ? Crinja::Value.new(output.to_s.chomp) : Crinja::Value.new(nil)
        rescue
          Crinja::Value.new(nil)
        end
      when "lines"
        command = arg1.to_s
        begin
          output = IO::Memory.new
          status = Process.run("/bin/sh", ["-c", command], output: output, error: Process::Redirect::Close)
          status.success? ? Crinja::Value.new(output.to_s.split('\n').reject(&.empty?)) : Crinja::Value.new(nil)
        rescue
          Crinja::Value.new(nil)
        end
      when "template"
        path = arg1.to_s
        resolved = JinjaFilters.resolve_lookup_path(path, role_path)
        begin
          Crinja::Value.new(env.from_string(File.read(resolved)).render.chomp)
        rescue
          Crinja::Value.new(nil)
        end
      when "password"
        raw_arg = arg1.to_s
        Crinja::Value.new(JinjaFilters.password_lookup(raw_arg, role_path))
      when "unvault"
        # Session-wide vault secret (Vault.password), distinct from the
        # `unvault` FILTER above (an explicit filter-argument secret).
        path = arg1.to_s
        password = CrystalPlay::Vault.password
        begin
          (password && File.exists?(path)) ? Crinja::Value.new(CrystalPlay::Vault.decrypt(File.read(path), password).chomp) : Crinja::Value.new(nil)
        rescue
          Crinja::Value.new(nil)
        end
      when "dict"
        hash = arg1.raw.is_a?(Crinja::Dictionary) ? arg1.raw.as(Crinja::Dictionary) : Crinja::Dictionary.new
        Crinja::Value.new(hash.map { |k, v| Crinja::Value.new({"key" => Crinja::Value.new(k.to_s), "value" => v}) })
      when "list"
        Crinja::Value.new(variadic_terms)
      when "items"
        Crinja::Value.new(variadic_terms.flat_map { |t| t.sequence? ? t.to_a : [t] })
      when "together"
        arrays = variadic_terms.map { |t| t.sequence? ? t.to_a : [] of Crinja::Value }
        size = arrays.max_of?(&.size) || 0
        Crinja::Value.new((0...size).map { |i| Crinja::Value.new(arrays.map { |arr| arr[i]? || Crinja::Value.new(nil) }) })
      when "nested"
        arrays = variadic_terms.map { |t| t.sequence? ? t.to_a : [] of Crinja::Value }
        result = arrays.reduce([[] of Crinja::Value]) { |acc, arr| acc.flat_map { |row| arr.map { |item| row + [item] } } }
        Crinja::Value.new(result.map { |row| Crinja::Value.new(row) })
      when "varnames"
        patterns = variadic_terms.map { |t| Regex.new(t.to_s) rescue nil }.compact
        names = env.context.keys.select { |name| patterns.any?(&.matches?(name)) }
        Crinja::Value.new(names.map { |n| Crinja::Value.new(n) })
      when "indexed_items"
        arr = arg1.sequence? ? arg1.to_a : [] of Crinja::Value
        Crinja::Value.new(arr.map_with_index { |item, i| Crinja::Value.new([Crinja::Value.new(i), item]) })
      when "random_choice"
        items = variadic_terms.flat_map { |t| t.sequence? ? t.to_a : [t] }
        items.empty? ? Crinja::Value.new(nil) : items.sample
      when "subelements"
        source = arg1.sequence? ? arg1.to_a : [] of Crinja::Value
        subkey = arguments["a2"].to_s
        skip_missing = arguments["a3"].raw.is_a?(Crinja::Dictionary) ? (arguments["a3"].raw.as(Crinja::Dictionary)[Crinja::Value.new("skip_missing")]?.try(&.truthy?) || false) : false
        result = [] of Crinja::Value
        source.each do |parent|
          children = parent.raw.is_a?(Crinja::Dictionary) ? parent.raw.as(Crinja::Dictionary)[Crinja::Value.new(subkey)]? : nil
          next if children.nil? && skip_missing
          (children.try(&.to_a) || [] of Crinja::Value).each { |child| result << Crinja::Value.new([parent, child]) }
        end
        Crinja::Value.new(result)
      when "url"
        # lookup('url', url_expr[, wantlist=True]) - fetches from the
        # CONTROLLER, following redirects (see .fetch_url_lines below).
        # `wantlist` arrives as a plain caller-supplied kwarg - it's
        # deliberately NOT declared in this function's defaults tuple
        # (unlike type/a1..a4), since `Arguments#kwargs` already holds
        # whatever named args the caller actually passed regardless of
        # what's declared, and declaring it would force every OTHER
        # lookup type to also tolerate a stray `wantlist=` kwarg.
        wantlist = arguments.kwargs["wantlist"]?.try(&.truthy?) || false
        lines = JinjaFilters.fetch_url_lines(arg1.to_s)
        if lines.nil?
          Crinja::Value.new(nil)
        elsif wantlist
          Crinja::Value.new(lines.map { |line| Crinja::Value.new(line) })
        else
          Crinja::Value.new(lines.join(","))
        end
      when "first_found"
        # lookup('first_found', {'files': [...], 'paths': [...]}) - same
        # search order/role-relative resolution as ExpressionEvaluator's
        # own #evaluate_first_found, adapted to Crinja::Dictionary/Value
        # instead of JSON::Any.
        hash = arg1.raw.is_a?(Crinja::Dictionary) ? arg1.raw.as(Crinja::Dictionary) : nil
        files_val = hash.try(&.[Crinja::Value.new("files")]?)
        paths_val = hash.try(&.[Crinja::Value.new("paths")]?)
        files = (files_val && files_val.sequence?) ? files_val.to_a : [] of Crinja::Value
        paths = (paths_val && paths_val.sequence?) ? paths_val.to_a : ["files", "templates", "vars", "."].map { |root| Crinja::Value.new(root) }

        rendered_paths = paths.flat_map { |path_entry| JinjaFilters.resolve_first_found_roots(env.from_string(path_entry.to_s).render, role_path) }

        found = nil
        files.each do |file_entry|
          rendered_file = env.from_string(file_entry.to_s).render
          rendered_paths.each do |path|
            candidate = File.join(path, rendered_file)
            if File.exists?(candidate)
              found = candidate
              break
            end
          end
          break if found
        end
        Crinja::Value.new(found)
      when "sequence"
        Crinja::Value.new(JinjaFilters.sequence_lookup(arg1.to_s).map { |v| Crinja::Value.new(v) })
      when "csvfile"
        Crinja::Value.new(JinjaFilters.csvfile_lookup(arg1.to_s))
      when "ini"
        Crinja::Value.new(JinjaFilters.ini_lookup(arg1.to_s))
      else
        Crinja::Value.new(nil)
      end
    end

    # lookup('file'|'template', path) both name a CONTROLLER-side path
    # that - inside a role - is conventionally relative to the role's
    # own files/ dir (real Ansible's own behavior). An absolute path, or
    # a relative one outside any role context, passes through unchanged.
    # Same logic as ExpressionEvaluator's own #resolve_lookup_path,
    # duplicated rather than shared - see this file's own top-of-file
    # comment on why the two evaluators don't share implementation.

    def self.ansible_config_value(name : String) : String
      case name.upcase
      when "COLOR_OK"                    then "green"
      when "COLOR_CHANGED"               then "yellow"
      when "COLOR_SKIP"                  then "cyan"
      when "COLOR_UNREACHABLE"           then "bright red"
      when "COLOR_ERROR", "COLOR_FAILED" then "red"
      when "COLOR_DEBUG"                 then "dark gray"
      when "COLOR_VERBOSE"               then "blue"
      when "COLOR_WARN"                  then "bright purple"
      when "DEFAULT_BECOME_USER"         then "root"
      when "DEFAULT_ROLES_PATH"          then "~/.ansible/roles:/usr/share/ansible/roles:/etc/ansible/roles"
      when "DEFAULT_HOST_LIST"           then "/etc/ansible/hosts"
      when "RETRY_FILES_SAVE_PATH"       then ""
      when "DEFAULT_TIMEOUT"             then "10"
      when "DEFAULT_FORKS"               then "5"
      else
        ENV["ANSIBLE_#{name.upcase}"]? || ""
      end
    end

    def self.resolve_lookup_path(path : String, role_path : String?) : String
      return path if path.starts_with?('/')
      role_path ? File.join(role_path, "files", path) : path
    end

    # A relative first_found `paths:` entry can resolve against either
    # the role's own ROOT directory OR (buluma.confluence's own `paths:
    # ['../vars']` idiom, real Ansible resolves this relative to tasks/,
    # not role_path itself) its tasks/ subdirectory - same two-root
    # search ExpressionEvaluator's own #resolve_first_found_roots
    # applies (see that method's comment for the full story and the
    # round165 repro that found this gap independently on this,
    # separate, Crinja-backed evaluator).
    def self.resolve_first_found_roots(path : String, role_path : String?) : Array(String)
      return [path] if path.starts_with?('/')
      return [path] unless role_path

      [File.join(role_path, path), Path.new(role_path, "tasks", path).normalize.to_s]
    end

    # Mirrors ExpressionEvaluator's own #fetch_url_lines (redirect-
    # following GET, stripped/blank-rejected lines), returning a real
    # Array(String)? here instead of JSON array text - nil on any
    # failure (unreachable host, non-2xx, too many redirects).
    def self.fetch_url_lines(url : String, redirects_left : Int32 = 5) : Array(String)?
      return nil if redirects_left < 0

      response = HTTP::Client.get(url)

      if response.status.redirection? && (location = response.headers["Location"]?)
        resolved = URI.parse(location).absolute? ? location : URI.parse(url).resolve(location).to_s
        return fetch_url_lines(resolved, redirects_left - 1)
      end

      return nil unless response.success?

      response.body.lines.map(&.strip).reject(&.empty?)
    rescue
      nil
    end

    PASSWORD_CHARS  = ("a".."z").to_a + ("A".."Z").to_a + ("0".."9").to_a + [".", ",", ":", "-", "_"]
    PASSWORD_LENGTH = 20

    # lookup('sequence', 'start=1 end=5 stride=1 format=web%02d') - same
    # logic as ExpressionEvaluator's own #evaluate_sequence_lookup,
    # returning a real Array(String) here instead of JSON array text.
    def self.sequence_lookup(raw_arg : String) : Array(String)
      tokens = raw_arg.strip.split(/\s+/)
      opts = Hash(String, String).new
      if tokens[0]? && !tokens[0].includes?('=') && (range_match = tokens[0].match(/^(\d+)-(\d+)$/))
        opts["start"] = range_match[1]
        opts["end"] = range_match[2]
        tokens = tokens[1..]
      end
      tokens.each do |token|
        key, sep, val = token.partition('=')
        opts[key] = val unless sep.empty?
      end

      start = opts["start"]?.try(&.to_i) || 1
      stride = opts["stride"]?.try(&.to_i) || 1
      count = opts["count"]?.try(&.to_i)
      finish = opts["end"]?.try(&.to_i)
      format = opts["format"]?

      total = count || (finish ? ((finish - start) // stride) + 1 : 1)
      return [] of String if total < 0

      values = (0...total).map { |i| start + i * stride }
      format ? values.map { |v| (format % v) rescue v.to_s } : values.map(&.to_s)
    end

    # lookup('csvfile', 'key file=data.csv delimiter=, col=1') - same
    # logic as ExpressionEvaluator's own #evaluate_csvfile_lookup.
    def self.csvfile_lookup(raw_arg : String) : String?
      tokens = raw_arg.strip.split(/\s+/)
      key = tokens[0]?
      return nil unless key

      opts = Hash(String, String).new
      tokens[1..].each do |token|
        k, sep, v = token.partition('=')
        opts[k] = v unless sep.empty?
      end

      file = opts["file"]?
      return nil unless file
      delimiter = opts["delimiter"]? || ","
      col = opts["col"]?.try(&.to_i) || 1

      begin
        File.each_line(file) do |line|
          fields = line.split(delimiter)
          next unless fields[0]?.try(&.strip) == key
          return (fields[col]? || "").strip
        end
      rescue
      end
      nil
    end

    # lookup('ini', 'value section=section1 file=file.ini') - same logic
    # as ExpressionEvaluator's own #evaluate_ini_lookup.
    def self.ini_lookup(raw_arg : String) : String?
      tokens = raw_arg.strip.split(/\s+/)
      value_key = tokens[0]?
      return nil unless value_key

      opts = Hash(String, String).new
      tokens[1..].each do |token|
        k, sep, v = token.partition('=')
        opts[k] = v unless sep.empty?
      end

      file = opts["file"]?
      return nil unless file
      wanted_section = opts["section"]? || "DEFAULT"

      begin
        current_section = "DEFAULT"
        File.each_line(file) do |raw_line|
          line = raw_line.strip
          next if line.empty? || line.starts_with?(';') || line.starts_with?('#')
          if line.starts_with?('[') && line.ends_with?(']')
            current_section = line[1..-2]
            next
          end
          next unless current_section == wanted_section
          k, sep, v = line.partition('=')
          return v.strip if sep != "" && k.strip == value_key
        end
      rescue
      end
      nil
    end

    # lookup('password', 'path [length=N]') - generates a random
    # password ONCE and persists it to *path* (real Ansible's own
    # behavior: a later run/lookup reads the same file back rather than
    # generating a new value every time). Same logic as
    # ExpressionEvaluator's own #evaluate_password_lookup.
    def self.password_lookup(raw_arg : String, role_path : String?) : String
      tokens = raw_arg.strip.split(/\s+/)
      path = tokens[0]?
      return "" unless path
      resolved_path = resolve_lookup_path(path, role_path)

      length = PASSWORD_LENGTH
      tokens[1..].each do |token|
        length = token[7..].to_i? || length if token.starts_with?("length=")
      end

      return File.read(resolved_path).chomp if File.exists?(resolved_path)

      password = Array.new(length) { PASSWORD_CHARS.sample }.join
      begin
        dir = File.dirname(resolved_path)
        Dir.mkdir_p(dir) unless Dir.exists?(dir)
        File.write(resolved_path, password + "\n")
      rescue
      end
      password
    end
  end
end
