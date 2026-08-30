require "../spec_helper"
require "../../src/crystal_play/variable_substitutor/variable_lookup"

describe CrystalPlay::VariableSubstitutor::VariableLookup do
  it "resolves a simple string variable, preserving its own whitespace" do
    # Real bug found benchmarking robertdebock.functions (round 116):
    # format_value used to unconditionally strip every string value -
    # real Jinja2 never strips a rendered value's own whitespace (only
    # `{%- -%}` block-tag whitespace control does, an orthogonal
    # template-syntax feature operating on the surrounding text, not a
    # variable's own value). A variable whose real content legitimately
    # has meaningful leading/trailing whitespace (" Extra spaces. ")
    # silently lost it on every `{{ }}` reference.
    v = Hash(String, JSON::Any).new
    v["name"] = JSON::Any.new("  hello  ")
    lookup = CrystalPlay::VariableSubstitutor::VariableLookup.new(v)
    lookup.simple("name").should eq("  hello  ")
  end

  it "returns 'undefined' for a missing simple variable" do
    lookup = CrystalPlay::VariableSubstitutor::VariableLookup.new(Hash(String, JSON::Any).new)
    lookup.simple("missing").should eq("undefined")
  end

  it "resolves nested hash access" do
    v = Hash(String, JSON::Any).new
    v["user"] = JSON.parse(%({"name": "ada"}))
    lookup = CrystalPlay::VariableSubstitutor::VariableLookup.new(v)
    lookup.nested("user.name").should eq("ada")
  end

  it "returns 'undefined' for a missing nested key" do
    v = Hash(String, JSON::Any).new
    v["user"] = JSON.parse(%({"name": "ada"}))
    lookup = CrystalPlay::VariableSubstitutor::VariableLookup.new(v)
    lookup.nested("user.email").should eq("undefined")
  end

  it "resolves numeric array indexing" do
    v = Hash(String, JSON::Any).new
    v["items"] = JSON.parse(%(["a", "b", "c"]))
    lookup = CrystalPlay::VariableSubstitutor::VariableLookup.new(v)
    lookup.indexed("items[1]").should eq("b")
  end

  it "resolves character indexing on a plain string, matching real Jinja2/Python str[0]" do
    # Real bug found benchmarking geerlingguy.elasticsearch: its own
    # version-branch `when: elasticsearch_version[0] | int < 7` (on
    # elasticsearch_version: "7.x", a plain string) fell through
    # index_into's `else -> nil` case (only Array/Hash were handled),
    # `| int` on the resulting "undefined" defaulted to 0, and `0 < 7`
    # silently picked the WRONG config-file layout (pre-7.x
    # elasticsearch.yml/jvm.options instead of 7+'s
    # jvm.options.d/heap.options) - Elasticsearch then failed to start
    # against the mismatched config.
    v = Hash(String, JSON::Any).new
    v["version"] = JSON::Any.new("7.x")
    lookup = CrystalPlay::VariableSubstitutor::VariableLookup.new(v)
    lookup.indexed("version[0]").should eq("7")
    lookup.indexed("version[1]").should eq(".")
  end

  it "resolves negative character indexing on a plain string" do
    v = Hash(String, JSON::Any).new
    v["version"] = JSON::Any.new("7.x")
    lookup = CrystalPlay::VariableSubstitutor::VariableLookup.new(v)
    lookup.indexed("version[-1]").should eq("x")
  end

  it "resolves quoted hash key indexing" do
    v = Hash(String, JSON::Any).new
    v["config"] = JSON.parse(%({"host": "example.com"}))
    lookup = CrystalPlay::VariableSubstitutor::VariableLookup.new(v)
    lookup.indexed(%(config['host'])).should eq("example.com")
  end

  # Booleans rendered directly into template text (`{{ boolvar }}`) must
  # come out as Python/Jinja2's capitalized "True"/"False", not Crystal's
  # lowercase "true"/"false" - verified against real ansible-playbook (a
  # `copy: content:` with `{{ stat_result.stat.exists }}` renders "True").
  # This is distinct from ComparisonEvaluator's own internal "true"/"false"
  # protocol used for `when:` truthiness, which already tolerates both
  # cases and is untouched here.
  it "renders a boolean as capitalized True/False via simple lookup" do
    v = Hash(String, JSON::Any).new
    v["yes_flag"] = JSON::Any.new(true)
    v["no_flag"] = JSON::Any.new(false)
    lookup = CrystalPlay::VariableSubstitutor::VariableLookup.new(v)
    lookup.simple("yes_flag").should eq("True")
    lookup.simple("no_flag").should eq("False")
  end

  it "renders a boolean as True/False via nested lookup" do
    v = Hash(String, JSON::Any).new
    v["stat"] = JSON.parse(%({"exists": true, "isdir": false}))
    lookup = CrystalPlay::VariableSubstitutor::VariableLookup.new(v)
    lookup.nested("stat.exists").should eq("True")
    lookup.nested("stat.isdir").should eq("False")
  end

  it "renders a boolean as True/False via indexed access" do
    v = Hash(String, JSON::Any).new
    v["flags"] = JSON.parse(%([true, false]))
    lookup = CrystalPlay::VariableSubstitutor::VariableLookup.new(v)
    lookup.indexed("flags[0]").should eq("True")
    lookup.indexed("flags[1]").should eq("False")
  end

  it "resolves a Python-style .split(sep)[index] method call chained off a dotted path" do
    # Real bug found benchmarking geerlingguy.postgresql's own "Include
    # OS-specific variables (Debian)." task: `include_vars: "{{
    # ansible_facts.distribution }}-{{ ansible_facts.distribution_version
    # .split('.')[0] }}.yml"`. Two compounding gaps: resolve_nested's
    # naive `expr.split(".")` broke on the METHOD ARGUMENT's own literal
    # "." (splitting "split('.')" into two garbled parts instead of
    # leaving it whole), and even with that fixed, no String method-call
    # handling existed at all (only Hash's .keys()/.values()/.items()) -
    # together these always resolved to "undefined" ("Ubuntu-undefined.
    # yml" instead of "Ubuntu-22.yml").
    v = Hash(String, JSON::Any).new
    v["ansible_facts"] = JSON.parse(%({"distribution_version": "22.04"}))
    lookup = CrystalPlay::VariableSubstitutor::VariableLookup.new(v)
    lookup.indexed("ansible_facts.distribution_version.split('.')[0]").should eq("22")
    lookup.indexed("ansible_facts.distribution_version.split('.')[1]").should eq("04")
  end

  it "re-renders a vars: value that is a {{ }} span PLUS trailing literal text before a method call" do
    # Real bug found benchmarking Oefenweb.nginx's own vars/main.yml:
    # `nginx_conf_file: "{{ nginx_conf_path }}/nginx.conf"` - a template
    # span followed by literal text, not a `{{ }}` wrapping the WHOLE
    # string the way `rerender_if_templated`'s old code assumed. The old
    # `inner.ends_with?("}}")` check was false here (the raw value ends
    # in "/nginx.conf", not "}}"), so `inner` was left as the full mixed
    # string "{{ nginx_conf_path }}/nginx.conf" and handed whole to
    # ExpressionEvaluator#evaluate - which expects a bare Jinja
    # EXPRESSION, not text with literal `{`/`}` characters in it -
    # collapsing `nginx_conf_file.lstrip('/')` to an empty string instead
    # of "etc/nginx/nginx.conf". A bare `{{ nginx_conf_file }}`
    # reference alone rendered fine even before this fix (a different,
    # unaffected code path), which is what made this one easy to miss.
    v = Hash(String, JSON::Any).new
    v["nginx_conf_path"] = JSON::Any.new("/etc/nginx")
    v["nginx_conf_file"] = JSON::Any.new("{{ nginx_conf_path }}/nginx.conf")
    lookup = CrystalPlay::VariableSubstitutor::VariableLookup.new(v)
    lookup.nested("nginx_conf_file.lstrip('/')").should eq("etc/nginx/nginx.conf")
  end

  it "resolves Python-style .lstrip()/.rstrip()/.strip() method calls on a string, char-set not prefix semantics" do
    # Real bug found benchmarking buluma.ssh_keys's own known-hosts.yml:
    # `src: "{{ ssh_keys_known_hosts_path.lstrip('/') }}.j2"` - no
    # String method-call handling existed for lstrip/rstrip/strip at
    # all, so the whole `{{ }}` collapsed to "undefined" and
    # `template:`'s `src:` became the nonexistent path "undefined.j2".
    # Python's str.lstrip(chars) strips a CHARACTER SET, not a prefix
    # string - "xxyx".lstrip("xy") strips every leading x/y regardless
    # of order, not just a literal "xy" prefix - verified against real
    # Python, not assumed.
    v = Hash(String, JSON::Any).new
    v["path"] = JSON::Any.new("/etc/ssh/ssh_known_hosts")
    v["padded"] = JSON::Any.new("xxyx-hello-yxxy")
    lookup = CrystalPlay::VariableSubstitutor::VariableLookup.new(v)
    lookup.nested("path.lstrip('/')").should eq("etc/ssh/ssh_known_hosts")
    lookup.nested("padded.lstrip('xy')").should eq("-hello-yxxy")
    lookup.nested("padded.rstrip('xy')").should eq("xxyx-hello-")
    lookup.nested("padded.strip('xy')").should eq("-hello-")
  end

  it "resolves a Python-style .find(substring) method call on a string" do
    # Real bug found benchmarking geerlingguy.clamav's own "Run freshclam
    # after ClamAV packages change." task: `failed_when: - freshclam_
    # result is failed - freshclam_result.stderr.find('locked by
    # another process') != -1` (only override the command module's own
    # default nonzero-exit failure when THAT specific message is
    # present - Debian's post-install freshclam run means a plain
    # nonzero exit here is expected and not a real failure). No String
    # method-call handling existed for `.find(...)` at all (only
    # `.split(...)`) - resolve_nested's fallthrough (current isn't a
    # Hash) returned nil/undefined, and `undefined != -1` evaluated
    # true, so failed_when always fired regardless of the actual
    # message - real ansible-playbook's own run of the identical role
    # reports this task as "changed", not failed.
    v = Hash(String, JSON::Any).new
    v["r"] = JSON.parse(%({"stdout": "hello world"}))
    lookup = CrystalPlay::VariableSubstitutor::VariableLookup.new(v)
    lookup.nested("r.stdout.find('world')").should eq("6")
    lookup.nested("r.stdout.find('nope')").should eq("-1")
  end

  it "walks a .attr suffix after an [index], not just the index alone" do
    # Real bug found benchmarking openstack.ansible-hardening's own AIDE-
    # config guard: `when: aide_conf.results[0].stat.exists | bool`, a
    # registered LOOPED task's aggregated results, indexed then walked
    # further. resolve_indexed's old bracket-only regex scan had no
    # notion of anything after the final "]" - `results[0].stat.exists`
    # resolved to the *whole* results[0] hash instead of its nested
    # boolean. Piped through `| bool` in a when:, any non-empty rendered
    # hash is truthy, so a should-have-been-skipped task ran for real.
    v = Hash(String, JSON::Any).new
    v["aide_conf"] = JSON.parse(%({"results": [{"item": "/etc/aide.conf", "stat": {"exists": false}}]}))
    lookup = CrystalPlay::VariableSubstitutor::VariableLookup.new(v)
    lookup.indexed("aide_conf.results[0].stat.exists").should eq("False")

    # Indexing alone (no trailing suffix) still resolves the item itself.
    lookup.indexed("aide_conf.results[0].item").should eq("/etc/aide.conf")
  end

  it "resolves a no-argument .split() method call, splitting on whitespace runs like real Python" do
    # Real bug found benchmarking robertdebock.bootstrap's own `loop: "{{
    # bootstrap_facts_packages.split() }}"` (round 18). Only the quoted-
    # separator form (`.split('sep')`, fixed above for geerlingguy.
    # postgresql) matched string_method_call's regex - the bare no-arg
    # form fell through entirely (current stays a String, not a Hash,
    # so the dotted-access fallthrough returns nil/undefined), turning a
    # 4-package loop into a single bogus "undefined" item that then
    # failed to install as a real package name.
    v = Hash(String, JSON::Any).new
    v["pkgs"] = JSON::Any.new("python3 sudo gnupg python3-apt")
    lookup = CrystalPlay::VariableSubstitutor::VariableLookup.new(v)
    result = lookup.resolve("pkgs.split()")
    result.should_not be_nil
    (result || raise "unexpected nil").as_a.map(&.as_s).should eq(["python3", "sudo", "gnupg", "python3-apt"])
  end

  it "resolves a no-argument .splitlines() method call with real Python semantics, not Crystal's plain split(\"\\n\")" do
    # Real bug found live-verifying prometheus.prometheus.node_exporter
    # (round 22): its own _common role's checksum-file parsing starts
    # with `raw.splitlines()` on a plain `{{ }}` set_fact value (not
    # inside `{%`/`{#` block tags, so only the hand-rolled evaluator -
    # not Crinja's own python_string_methods.cr copy - ever sees it) -
    # entirely unrecognized here before, resolving the whole expression
    # to undefined and cascading into an always-empty checksum dict.
    # Same Python-vs-Crystal split semantics as .split() above: empty
    # input -> [], one trailing newline -> no spurious final empty
    # element.
    v = Hash(String, JSON::Any).new
    v["text"] = JSON::Any.new("line1\nline2\nline3\n")
    v["empty"] = JSON::Any.new("")
    lookup = CrystalPlay::VariableSubstitutor::VariableLookup.new(v)
    (lookup.resolve("text.splitlines()") || raise "unexpected nil").as_a.map(&.as_s).should eq(["line1", "line2", "line3"])
    (lookup.resolve("empty.splitlines()") || raise "unexpected nil").as_a.should eq([] of JSON::Any)
  end

  it "resolves bare {{ }} .startswith()/.endswith() method calls, not just inside a {% if %} escalation" do
    v = Hash(String, JSON::Any).new
    v["s"] = JSON::Any.new("node_exporter-1.8.2.linux-amd64.tar.gz")
    lookup = CrystalPlay::VariableSubstitutor::VariableLookup.new(v)
    (lookup.resolve("s.startswith('node_exporter')") || raise "unexpected nil").as_bool.should eq(true)
    (lookup.resolve("s.endswith('.tar.gz')") || raise "unexpected nil").as_bool.should eq(true)
    (lookup.resolve("s.startswith('other')") || raise "unexpected nil").as_bool.should eq(false)
  end

  it "re-renders a bare-identifier INDEX KEY (dict[some_var]) that is itself still-unrendered {{ }} text" do
    # Real bug found live-verifying prometheus.prometheus.node_exporter
    # (round 22): its own _common role's checksum verification does
    # `checksums[__common_binary_basename]` where `__common_binary_
    # basename` is itself a role var computed from another template
    # (`"{{ _common_binary_url | urlsplit('path') | basename }}"`, not
    # yet eagerly resolved at role-load time - stored raw in @vars, the
    # same shape this codebase has fixed at several OTHER bare-lookup
    # call sites (the plain bare-lookup fallback, the filter-chain
    # head, default()'s own argument, a bare comparison operand,
    # dotted-access base fetch) but not yet this one: resolve_index_key
    # fetched @vars[name] completely raw and used the LITERAL "{{ ... }}"
    # text as the dict key - a key that obviously doesn't exist, so
    # `checksums[__common_binary_basename]` silently returned undefined
    # even though a bare `{{ __common_binary_basename }}` substituted
    # correctly everywhere else in the same task. Every download's
    # checksum verification failed this way.
    v = Hash(String, JSON::Any).new
    v["binary_url"] = JSON::Any.new("https://example.com/path/to/foo.txt")
    v["binary_basename"] = JSON::Any.new(%({{ binary_url | urlsplit('path') | basename }}))
    v["mydict"] = JSON.parse(%({"foo.txt": "checksum1", "bar.txt": "checksum2"}))
    lookup = CrystalPlay::VariableSubstitutor::VariableLookup.new(v)
    (lookup.resolve("mydict[binary_basename]") || raise "unexpected nil").as_s.should eq("checksum1")
  end

  it "re-renders a dotted-access BASE variable that is itself still-unrendered {{ }} text before walking .method()/.attr off of it" do
    # Real Ansible's recursive re-templating - one more independent copy
    # of this bug class (already fixed at several OTHER call sites: the
    # bare-lookup fallback, the filter-chain head, default()'s own
    # argument, a bare comparison operand), this time for the dotted-
    # access BASE fetch specifically. Found via robertdebock.bootstrap's
    # own `bootstrap_facts_packages: "{{ _bootstrap_packages[...] |
    # default(...) }}"` (vars/main.yml, round 18): the var is stored in
    # @vars still as its own raw `{{ }}` text (lazy evaluation), and
    # resolve_nested previously fetched that literal text as-is and
    # called `.split()` directly on it instead of on its real rendered
    # value.
    v = Hash(String, JSON::Any).new
    v["inner"] = JSON::Any.new("hello world")
    v["outer"] = JSON::Any.new("{{ inner }}")
    lookup = CrystalPlay::VariableSubstitutor::VariableLookup.new(v)
    result = lookup.resolve("outer.split()")
    result.should_not be_nil
    (result || raise "unexpected nil").as_a.map(&.as_s).should eq(["hello", "world"])
  end

  it "resolves Python's `SEP.join(iterable)` method-call syntax on a quoted-literal separator" do
    # Real bug found benchmarking Oefenweb.fail2ban's own `name: "{{ '
    # '.join(fail2ban_dependencies).split() }}"` (building apt's package
    # list) - the receiver of .join() here is a quoted string LITERAL,
    # not a variable name, unlike every other dotted-path base this
    # resolver otherwise handles (a plain @vars[parts[0]]? lookup always
    # missed, since "' '" isn't a real variable). The whole expression
    # collapsed to nil/"undefined", used directly as apt's own name:
    # param.
    v = Hash(String, JSON::Any).new
    v["fail2ban_dependencies"] = JSON.parse(%(["fail2ban", "iptables"]))
    lookup = CrystalPlay::VariableSubstitutor::VariableLookup.new(v)

    result = lookup.resolve("' '.join(fail2ban_dependencies)")
    result.should_not be_nil
    (result || raise "unexpected nil").as_s.should eq("fail2ban iptables")
  end

  it "round-trips `SEP.join(iterable).split()` back to a list, the actual real-world idiom" do
    v = Hash(String, JSON::Any).new
    v["fail2ban_dependencies"] = JSON.parse(%(["fail2ban", "iptables"]))
    lookup = CrystalPlay::VariableSubstitutor::VariableLookup.new(v)

    result = lookup.resolve("' '.join(fail2ban_dependencies).split()")
    result.should_not be_nil
    (result || raise "unexpected nil").as_a.map(&.as_s).should eq(["fail2ban", "iptables"])
  end

  it "re-renders each element of a .join() list argument, another recursive-re-templating copy" do
    # Real bug found in the same round: Oefenweb.fail2ban's own real
    # fail2ban_dependencies has a templated 2nd element (a ternary
    # choosing a package name or an empty string), stored raw/unrendered
    # in @vars - joining without re-rendering each element first glued
    # the literal "{{ ... }}" text straight into the package name,
    # producing garbage that then failed to install.
    v = Hash(String, JSON::Any).new
    v["fail2ban_backend"] = JSON::Any.new("systemd")
    v["fail2ban_dependencies"] = JSON.parse(%(["fail2ban", "{{ (fail2ban_backend == 'systemd') | ternary('python3-systemd', '') }}"]))
    lookup = CrystalPlay::VariableSubstitutor::VariableLookup.new(v)

    result = lookup.resolve("' '.join(fail2ban_dependencies).split()")
    result.should_not be_nil
    (result || raise "unexpected nil").as_a.map(&.as_s).should eq(["fail2ban", "python3-systemd"])
  end

  it "drops an empty-string element after the join+split round-trip, matching Python's whitespace split" do
    v = Hash(String, JSON::Any).new
    v["fail2ban_dependencies"] = JSON.parse(%(["fail2ban", ""]))
    lookup = CrystalPlay::VariableSubstitutor::VariableLookup.new(v)

    result = lookup.resolve("' '.join(fail2ban_dependencies).split()")
    result.should_not be_nil
    (result || raise "unexpected nil").as_a.map(&.as_s).should eq(["fail2ban"])
  end

  it "resolves dict.get() even when its key argument is itself an indexed expression" do
    # Real bug found immediately after fixing dict.get() itself:
    # resolve()'s own top-level dispatch checked `expr.includes?("[")`
    # for the WHOLE expression before checking for a "." - a `[`
    # anywhere (even nested inside the .get() call's own ARGUMENT, e.g.
    # `ansible_facts['architecture']`) wrongly routed the whole
    # expression to resolve_indexed, which then cut the "base" off
    # mid-expression at that nested bracket instead of delegating to
    # resolve_nested (and its own hash_method_call dict.get() support)
    # the way the whole-expression's own TOP-LEVEL structure (a dotted
    # method call) actually requires.
    v = Hash(String, JSON::Any).new
    v["ansible_facts"] = JSON.parse(%({"architecture": "x86_64"}))
    lookup = CrystalPlay::VariableSubstitutor::VariableLookup.new(v)

    result = lookup.resolve(%({'x86_64': 'amd64'}.get(ansible_facts['architecture'], ansible_facts['architecture'])))
    result.should_not be_nil
    (result || raise "unexpected nil").as_s.should eq("amd64")
  end

  it "still routes a genuine top-level indexed+dotted expression to resolve_indexed (no regression)" do
    # ansible_facts.getent_passwd[item][4] - resolve_indexed already
    # correctly delegates the dotted PREFIX to resolve_nested
    # internally before walking the bracket suffix; resolve_nested's
    # own parts loop has no notion of a trailing `[...]` at all, so this
    # must keep routing through resolve_indexed, not resolve_nested.
    v = Hash(String, JSON::Any).new
    v["ansible_facts"] = JSON.parse(%({"getent_passwd": {"root": ["x", "0", "0", "root", "/root", "/bin/bash"]}}))
    lookup = CrystalPlay::VariableSubstitutor::VariableLookup.new(v)

    result = lookup.resolve("ansible_facts.getent_passwd['root'][4]")
    result.should_not be_nil
    (result || raise "unexpected nil").as_s.should eq("/root")
  end

  it "resolves Python's dict.get(key, default) method-call syntax on a literal dict base" do
    # Real bug found benchmarking prometheus.prometheus.node_exporter's
    # own `_node_exporter_go_ansible_arch` default: `{'i386': '386',
    # 'x86_64': 'amd64', ...}.get(ansible_facts['architecture'],
    # ansible_facts['architecture'])` (an architecture-name lookup table
    # feeding its GitHub release download URL) - entirely unimplemented,
    # resolved to nil/"undefined" regardless of a real key match,
    # silently corrupting the download URL into a 404.
    v = Hash(String, JSON::Any).new
    v["my_arch"] = JSON::Any.new("x86_64")
    lookup = CrystalPlay::VariableSubstitutor::VariableLookup.new(v)

    result = lookup.resolve(%({'i386': '386', 'x86_64': 'amd64', 'aarch64': 'arm64'}.get(my_arch, my_arch)))
    result.should_not be_nil
    (result || raise "unexpected nil").as_s.should eq("amd64")
  end

  it "dict.get() falls back to its default argument when the key isn't present" do
    v = Hash(String, JSON::Any).new
    v["my_arch"] = JSON::Any.new("riscv64")
    lookup = CrystalPlay::VariableSubstitutor::VariableLookup.new(v)

    result = lookup.resolve(%({'x86_64': 'amd64'}.get(my_arch, my_arch)))
    result.should_not be_nil
    (result || raise "unexpected nil").as_s.should eq("riscv64")
  end
end
