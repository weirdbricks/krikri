require "../spec_helper"
require "../../src/crystal_play/variable_substitutor/crinja_renderer"

describe CrystalPlay::VariableSubstitutor::CrinjaRenderer do
  it "re-templates a variable whose own value is itself a {{ }} expression" do
    # Real bug found benchmarking geerlingguy.nginx: role defaults/main.yml
    # commonly defines a var whose *value* is itself more Jinja -
    # `nginx_worker_processes: '"{{ ansible_processor_vcpus | default(
    # ansible_processor_count) }}"'` - relying on real Ansible's own
    # recursive re-templating of every variable value wherever it's used,
    # including inside a real .j2 template FILE (not just a plain task
    # param `{{ }}`, which VarSubstitutor#substitute already handles via
    # its own multi-pass loop). Real Jinja2 itself has no such recursive
    # behavior - a variable's string value is just a string to it - so
    # `{{ nginx_worker_processes }}` in nginx.conf.j2 rendered the
    # literal, still-unparsed inner `{{ ... }}` text straight into the
    # config file, which nginx's own parser then rejected outright
    # ("worker_processes directive invalid value").
    v = Hash(String, JSON::Any).new
    v["ansible_processor_count"] = JSON::Any.new(1_i64)
    v["nginx_worker_processes"] = JSON::Any.new(%("{{ ansible_processor_vcpus | default(ansible_processor_count) }}"))
    renderer = CrystalPlay::VariableSubstitutor::CrinjaRenderer.new(v)

    renderer.render("worker_processes  {{ nginx_worker_processes }};").should eq(%(worker_processes  "1";))
  end

  it "re-renders a nested-template variable back to its real array type, not the array's stringified text" do
    # Real bug found benchmarking robertdebock.docker (round 104):
    # `docker_pip_packages: "{{ _docker_pip_packages[ansible_facts[
    # 'os_family']] | default(_docker_pip_packages['default']) }}"`
    # (robertdebock.docker's own vars/main.yml) - a var whose ENTIRE
    # value (nothing else around it) is a `{{ }}` expression that
    # itself evaluates to a real list. #prepare_crinja_vars always
    # wrapped the re-rendered result as a plain String (the STRING
    # "[\"docker\"]", 10 characters), never re-parsing it back to JSON
    # - so `docker_pip_packages | length` measured the STRING's
    # character count (10) instead of the list's element count (1),
    # and the role's own `when: docker_pip_packages | length > 0`
    # guard on its "Install docker pip packages" task always passed
    # even for the empty-list Debian case, feeding `ansible.builtin.
    # pip: name: "[]"` the literal string "[]" as a package name
    # ("ERROR: Invalid requirement: '[]'"). Distinguished from the
    # nginx_worker_processes case above (which must NOT be reparsed,
    # since its literal surrounding quote characters are meaningful
    # output) by requiring the raw value to be a PURE `{{ }}` span
    # with nothing else around it.
    v = Hash(String, JSON::Any).new
    v["inner_list"] = JSON::Any.new("{{ ['docker'] }}")
    renderer = CrystalPlay::VariableSubstitutor::CrinjaRenderer.new(v)

    renderer.render("{{ inner_list | length }}").should eq("1")
  end

  it "re-templates a still-unrendered {{ }} nested inside a list-of-dicts variable's own field" do
    # Real bug found benchmarking geerlingguy.postgresql: its own
    # pg_hba.conf.j2 iterates `postgresql_hba_entries` (a list of
    # dicts) via `{% for client in ... %} ... {{ client.auth_method
    # }} ...{% endfor %}`, where each entry's `auth_method:` field is
    # itself `"{{ postgresql_auth_method }}"` - a role default computed
    # from ANOTHER default. #prepare_crinja_vars only ever re-rendered
    # a *top-level* String value - `postgresql_hba_entries` itself is
    # an Array, so it never even reached the `raw.is_a?(String)` check
    # at all, and the literal unrendered "{{ postgresql_auth_method }}"
    # text landed straight into the rendered config file (PostgreSQL
    # then refused to start: "invalid authentication method '{{'").
    v = Hash(String, JSON::Any).new
    v["postgresql_auth_method"] = JSON::Any.new("md5")
    v["postgresql_hba_entries"] = JSON.parse(%([{"type": "host", "auth_method": "{{ postgresql_auth_method }}"}]))
    renderer = CrystalPlay::VariableSubstitutor::CrinjaRenderer.new(v)

    result = renderer.render("{% for client in postgresql_hba_entries %}{{ client.type }} {{ client.auth_method }}{% endfor %}")
    result.should eq("host md5")
  end

  it "leaves an ordinary variable (no embedded template) unaffected" do
    v = Hash(String, JSON::Any).new
    v["greeting"] = JSON::Any.new("hello")
    renderer = CrystalPlay::VariableSubstitutor::CrinjaRenderer.new(v)

    renderer.render("{{ greeting }}, world").should eq("hello, world")
  end

  it "supports Python's str.split(...) method-call syntax inside a {% if %}" do
    # Real bug found benchmarking geerlingguy.solr: its own
    # solr_default_core_path default is `{% if solr_version.split('.')
    # [0] < '9' %}...{% endif %}` - a plain Crystal String doesn't
    # implement crinja_call, so `.split(...)` resolved as "split is
    # undefined" (Crinja::TypeError), and CrinjaRenderer#render's own
    # blanket `rescue` then returned the ENTIRE template - not just the
    # one broken expression - completely unrendered. The plain
    # hand-rolled {{ }} evaluator already supported `.split(...)`
    # standalone (`{{ solr_version.split('.')[0] }}`) - this gap was
    # Crinja-only, and only surfaced once `.split` sat inside a `{%
    # if %}` (which forces escalation to the full Crinja renderer).
    v = Hash(String, JSON::Any).new
    v["solr_version"] = JSON::Any.new("8.11.2")
    renderer = CrystalPlay::VariableSubstitutor::CrinjaRenderer.new(v)

    renderer.render("{% if solr_version.split('.')[0] < '9' %}old{% else %}new{% endif %}").should eq("old")
  end

  it "does not eat a literal space right after a block tag under trim_blocks (only a real newline)" do
    # Real bug found benchmarking geerlingguy.solr: solr_default_core_
    # path's own default is `{% if ... %}{{ a }}/conf/{% else %}{{ a
    # }}/conf/{% endif %}`, used inside `command: "cp -r {{
    # solr_default_core_path }} {{ solr_home }}/data/{{ item }}/"` -
    # the space between the two cp arguments sits right after `{%
    # endif %}` with no newline before the next `{{ }}`. Real Jinja2's
    # trim_blocks only ever removes a newline immediately following a
    # block tag - it should do nothing when there's no newline there.
    # Crinja's own StringTrimmer.trim, when the text segment right
    # after a block tag has no newline in it at all, unconditionally
    # lstripped the WHOLE segment (correct only for an explicit `{%-
    # %}` minus-trim, not for trim_blocks alone), eating the space and
    # gluing both cp arguments into one ("cp: missing destination file
    # operand").
    v = Hash(String, JSON::Any).new
    v["x"] = JSON::Any.new(true)
    renderer = CrystalPlay::VariableSubstitutor::CrinjaRenderer.new(v)

    renderer.render("cp -r {% if x %}A{% else %}B{% endif %} /dest/").should eq("cp -r A /dest/")
  end

  it "defaults the comment filter to a bare '#' style" do
    v = Hash(String, JSON::Any).new
    renderer = CrystalPlay::VariableSubstitutor::CrinjaRenderer.new(v)

    renderer.render("{{ 'Ansible managed' | comment }}").should eq("#\n# Ansible managed\n#")
  end

  it "exposes the whole variable scope under the 'vars' magic variable, for dynamic-key lookups" do
    # Real bug found benchmarking openstack.ansible-hardening's own
    # audit-rule template: `{% if vars['security_rhel7_audit_' +
    # command_sanitized] | bool %}` (picking which of ~40 individually-
    # named enable/disable flags applies to the audit rule currently
    # being rendered) - real Ansible's own `vars` magic variable, a dict
    # of the whole current scope, entirely absent before ("vars is
    # undefined" failed the whole template render outright).
    v = Hash(String, JSON::Any).new
    v["security_rhel7_audit_foo"] = JSON::Any.new(true)
    renderer = CrystalPlay::VariableSubstitutor::CrinjaRenderer.new(v)

    renderer.render("{{ vars['security_rhel7_audit_foo'] }}").should eq("True")
  end

  it "honors decoration= for a non-'#' comment style" do
    # Real bug found benchmarking geerlingguy.php: `{{ ansible_managed |
    # comment(decoration='; ') }}` (www.conf.j2's own header, a php-fpm
    # INI-style pool file) previously ignored decoration= entirely and
    # always used "#" - not a valid INI comment character, so php-fpm's
    # own config parser rejected the file outright at startup ("value is
    # NULL for a ZEND_INI_PARSER_ENTRY"), even though the file looked
    # fine to a human reader.
    v = Hash(String, JSON::Any).new
    renderer = CrystalPlay::VariableSubstitutor::CrinjaRenderer.new(v)

    renderer.render("{{ 'Ansible managed' | comment(decoration='; ') }}").should eq(";\n; Ansible managed\n;")
  end

  it "resolves a fully-qualified collection filter name (ansible.builtin.X) to the same bare filter" do
    # Real bug found benchmarking robertdebock.vsftpd: `vsftpd.conf.j2`
    # uses `| ansible.builtin.ternary('YES', 'NO')` throughout (real
    # Ansible allows a filter to be referenced by its FQCN, exactly like
    # a module, resolving to the same filter registered under its bare
    # trailing name) - Crinja's own filter-name grammar only ever
    # expected a single bare IDENTIFIER after `|`, so any dotted filter
    # name crashed the whole template render ("Unexpected POINT")
    # instead of resolving like a plain `| ternary(...)` call.
    v = Hash(String, JSON::Any).new
    renderer = CrystalPlay::VariableSubstitutor::CrinjaRenderer.new(v)

    renderer.render("{{ true | ansible.builtin.ternary('YES', 'NO') }}").should eq("YES")
    renderer.render("{{ false | ansible.builtin.ternary('YES', 'NO') }}").should eq("NO")
  end

  it "honors the style= positional argument for comment()" do
    # Real bug found benchmarking robertdebock.php: `{{ "..." |
    # comment('c') }}` (php.ini.j2's own header) previously ignored the
    # style argument entirely (only `decoration=` was ever read) and
    # always fell back to the "plain" "#"-style border regardless of
    # style, producing a silently wrong (not crashing) comment banner -
    # real Ansible's own `comment()` supports 'plain'/'erlang'/'c'/
    # 'cblock'/'xml', each with its own decoration and (for cblock/xml)
    # distinct begin/end border lines.
    v = Hash(String, JSON::Any).new
    renderer = CrystalPlay::VariableSubstitutor::CrinjaRenderer.new(v)

    renderer.render("{{ 'Ansible managed' | comment('c') }}").should eq("//\n// Ansible managed\n//")
    renderer.render("{{ 'Ansible managed' | comment('erlang') }}").should eq("%\n% Ansible managed\n%")
    renderer.render("{{ 'Ansible managed' | comment('cblock') }}").should eq("/*\n *\n * Ansible managed\n *\n */")
    renderer.render("{{ 'Ansible managed' | comment('xml') }}").should eq("<!--\n -\n - Ansible managed\n -\n-->")
  end

  it "treats an empty string as falsy in 'and', matching real Python/Jinja2 truthiness" do
    # Real bug found benchmarking geerlingguy.kibana's own kibana.yml.j2:
    # `{% if kibana_elasticsearch_username and kibana_elasticsearch_
    # password %}` (both default to "") - Crinja's own Value#truthy?
    # only special-cased false/0/nil/undefined, so an empty string was
    # truthy, and And/Or's own `op1.truthy? && op2.call.truthy?` always
    # collapsed to true here - the rendered file had a LIVE (wrong)
    # `elasticsearch.username: ""` pair instead of real Ansible's own
    # commented-out `{% else %}` placeholder. Verified directly against
    # real Python's own jinja2.Environment, not just the real host.
    v = Hash(String, JSON::Any).new
    v["a"] = JSON::Any.new("")
    v["b"] = JSON::Any.new("")
    renderer = CrystalPlay::VariableSubstitutor::CrinjaRenderer.new(v)

    renderer.render(%({% if a and b %}T{% else %}F{% endif %})).should eq("F")
  end

  it "renders a bare boolean as Python-style 'True'/'False', not Crystal's lowercase" do
    # Real bug found benchmarking geerlingguy.supervisor's own
    # supervisord.conf.j2: `nodaemon = {{ supervisor_nodaemon }}`
    # (default `false`) rendered "nodaemon = false" - real Ansible's own
    # rendered file (verified directly against real ansible-playbook)
    # reads "nodaemon = False", Python's str(bool) capitalization.
    # Crinja's own Finalizer had no Bool-specific stringify overload and
    # fell through to Crystal's native lowercase Bool#to_s.
    v = Hash(String, JSON::Any).new
    renderer = CrystalPlay::VariableSubstitutor::CrinjaRenderer.new(v)

    renderer.render("{{ true }}").should eq("True")
    renderer.render("{{ false }}").should eq("False")
  end

  it "renders the to_json filter with Python's own ', '/': ' separators" do
    # Real bug found benchmarking geerlingguy.logstash's own 30-
    # elasticsearch-output.conf.j2: `hosts => {{
    # logstash_elasticsearch_hosts | to_json }}` - to_json was entirely
    # unimplemented, failing the whole template render. Python's own
    # json.dumps() (what real Ansible's to_json filter wraps) defaults
    # to ", "/": " separators, not Crystal stdlib's compact ","/":" -
    # verified directly against Python's own json.dumps.
    v = Hash(String, JSON::Any).new
    renderer = CrystalPlay::VariableSubstitutor::CrinjaRenderer.new(v)

    renderer.render(%({{ ["a", "b"] | to_json }})).should eq(%(["a", "b"]))
    renderer.render(%({{ {"a": 1, "b": "two"} | to_json }})).should eq(%({"a": 1, "b": "two"}))
  end

  it "renders the hash filter, real Ansible's own filter" do
    # Real bug found benchmarking geerlingguy.supervisor's own
    # supervisord.conf.j2: `{SHA}{{ supervisor_password|hash('sha1') }}`
    # - Crinja raised "no filter with name \"hash\" registered", failing
    # the whole template render. Values verified against Python's own
    # hashlib.
    renderer = CrystalPlay::VariableSubstitutor::CrinjaRenderer.new({} of String => JSON::Any)
    renderer.render(%({{ "mysecret" | hash('sha1') }})).should eq("e9fe51f94eadabf54dbf2fbbd57188b9abee436e")
    renderer.render(%({{ "mysecret" | hash }})).should eq("e9fe51f94eadabf54dbf2fbbd57188b9abee436e")
    renderer.render(%({{ "mysecret" | hash('md5') }})).should eq("06c219e5bc8378f3a8a3f83b4b7e4649")
  end

  it "honors \\1 backreferences in regex_replace's replacement string" do
    # Real bug found benchmarking devsec.hardening.ssh_hardening's own
    # `sshd_version_raw.stderr | regex_replace('.*_([0-9]*.[0-9]).*',
    # '\1')` (parsing `ssh -V`'s stderr down to a bare version number).
    # jinja_filters.cr used to rewrite `\1`/`\2` replacement
    # backreferences to `$1`/`$2` on the mistaken assumption Crystal's
    # String#gsub(Regex, String) used Ruby-style `$`-backreferences -
    # it doesn't special-case `$1` at all, so the "translated"
    # replacement was emitted completely literally ("$1" instead of
    # the captured "8.9"), and every downstream `is version(...)` gate
    # depending on the parsed value evaluated wrong as a result.
    renderer = CrystalPlay::VariableSubstitutor::CrinjaRenderer.new({} of String => JSON::Any)
    renderer.render(
      %({{ "OpenSSH_8.9p1 Ubuntu-3, OpenSSL 3.0.2 15 Mar 2022" | regex_replace('.*_([0-9]*.[0-9]).*', '\\1') }})
    ).should eq("8.9")
  end

  it "renders to_nice_yaml, real Ansible's own pretty-YAML filter" do
    # Real bug found benchmarking cloudalchemy.prometheus's own alerting-
    # rules template: `{{ prometheus_alert_rules | to_nice_yaml(indent=2,
    # sort_keys=False) }}` - to_nice_yaml was entirely unimplemented,
    # Crinja raised "no filter with name \"to_nice_yaml\" registered",
    # failing the whole template render (all-or-nothing).
    v = Hash(String, JSON::Any).new
    renderer = CrystalPlay::VariableSubstitutor::CrinjaRenderer.new(v)

    renderer.render(%({{ [{"name": "x", "rules": ["a", "b"]}] | to_nice_yaml }})).should eq(
      "- name: x\n  rules:\n  - a\n  - b"
    )
  end

  it "sorts to_nice_yaml's own mapping keys by default, honors sort_keys=False" do
    v = Hash(String, JSON::Any).new
    renderer = CrystalPlay::VariableSubstitutor::CrinjaRenderer.new(v)

    renderer.render(%({{ {"b": 1, "a": 2} | to_nice_yaml }})).should eq("a: 2\nb: 1")
    renderer.render(%({{ {"b": 1, "a": 2} | to_nice_yaml(sort_keys=False) }})).should eq("b: 1\na: 2")
  end

  it "type_debug returns Python's own type name" do
    # Real bug found benchmarking robertdebock.httpd's own assert.yml:
    # `httpd_additionnal_modules | type_debug == "list"` - entirely
    # unimplemented, so the assert failed outright regardless of the
    # variable's actual (correct) type.
    v = Hash(String, JSON::Any).new
    v["mylist"] = JSON.parse(%(["a", "b"]))
    renderer = CrystalPlay::VariableSubstitutor::CrinjaRenderer.new(v)

    renderer.render("{{ mylist | type_debug }}").should eq("list")
    renderer.render(%({{ "x" | type_debug }})).should eq("str")
    renderer.render("{{ 5 | type_debug }}").should eq("int")
  end

  it "password_hash produces a real crypt(3) hash" do
    v = Hash(String, JSON::Any).new
    renderer = CrystalPlay::VariableSubstitutor::CrinjaRenderer.new(v)

    result = renderer.render(%({{ "secret" | password_hash('sha512') }}))
    result.should start_with("$6$")
    result.should_not contain("secret")
  end

  it "renders a whitespace-trim marker on an expression tag (not just a block tag)" do
    # Real bug found benchmarking prometheus.prometheus._common's own
    # vars/main.yml: `{{ (...) -}}` (a `-}}` trim marker directly on a
    # `{{ }}` output tag) - the vendored Crinja shard's own expression
    # lexer mistokenized the trailing "-" as a literal minus OPERATOR
    # rather than a trim marker, corrupting `'x' -}}` into `'x' -
    # <undefined>`, rendering the literal text "undefined" instead of
    # "x". The block-tag form (`{%- if x -%}`) already worked correctly;
    # only the expression-tag form was broken.
    v = Hash(String, JSON::Any).new
    renderer = CrystalPlay::VariableSubstitutor::CrinjaRenderer.new(v)

    renderer.render(%(a{{ 'x' -}}b)).should eq("axb")
    renderer.render(%(a{{- 'x' }}b)).should eq("axb")
  end

  it "supports Jinja2's native inline ternary (`X if COND else Y`), entirely unimplemented before" do
    # Real bug found benchmarking prometheus.prometheus._common's own
    # vars/main.yml: the vendored Crinja shard's parser had NO grammar
    # rule for Jinja2/Python's inline conditional expression at all -
    # `{{ 'a' if x else 'b' }}` failed outright ("expression was not
    # fully parsed"), and the parenthesized form `{{ ('a' if x else 'b')
    # }}` failed differently ("Expected RIGHT_PAREN, got IDENTIFIER").
    # Note: unrelated to the separate `| ternary(...)` FILTER this
    # codebase already implements (jinja_filters.cr) - that's Ansible's
    # own filter syntax, a different construct from Jinja2's native
    # inline `if`/`else` expression fixed here.
    v = Hash(String, JSON::Any).new
    v["x"] = JSON::Any.new(true)
    renderer = CrystalPlay::VariableSubstitutor::CrinjaRenderer.new(v)

    renderer.render(%({{ 'a' if x else 'b' }})).should eq("a")
    renderer.render(%({{ ('a' if x else 'b') }})).should eq("a")

    v["x"] = JSON::Any.new(false)
    renderer2 = CrystalPlay::VariableSubstitutor::CrinjaRenderer.new(v)
    renderer2.render(%({{ 'a' if x else 'b' }})).should eq("b")
  end

  it "renders the exact real-world block-tag + parenthesized-ternary + is-test combination" do
    v = Hash(String, JSON::Any).new
    v["pkg_mgr"] = JSON::Any.new("apt")
    renderer = CrystalPlay::VariableSubstitutor::CrinjaRenderer.new(v)

    result = renderer.render(%({% if pkg_mgr == 'apt' %}{{ ('python-apt' if (1 is number) else 'python3-apt') -}}{% else %}{% endif %}))
    result.should eq("python-apt")
  end

  it "still renders correctly when the trim-marker fix runs alongside real {% %} block tags" do
    v = Hash(String, JSON::Any).new
    v["pkg_mgr"] = JSON::Any.new("apt")
    renderer = CrystalPlay::VariableSubstitutor::CrinjaRenderer.new(v)

    result = renderer.render(%({% if pkg_mgr == 'apt' %}{{ 'python3-apt' -}}{% else %}{% endif %}))
    result.should eq("python3-apt")
  end

  it "does not blow up combinatorially when a {% %}-block-tag var sits alongside a large nested-facts-shaped var context" do
    # Real bug found live-verifying round 22 (the Crinja step-5
    # convergence work): prometheus.prometheus.node_exporter, going
    # through _common role's own vars/main.yml, has one var -
    # `_common_dependencies` - whose value is pure `{% if %}...{%
    # endif %}` block tags (no `{{ }}`). Re-templating it re-entered
    # `#prepare_crinja_vars`, which re-walks ALL of `@vars` (including
    # deeply nested `ansible_facts`, via `rerender_nested_templates`'s
    # own Array/Hash recursion, added for the geerlingguy.postgresql
    # nested-list bug) - and since `@vars` never changes, found the
    # SAME block-tag var still raw and recursed again.
    # `@@block_tag_escalation_depth`'s cap of 50 bounds the RECURSION
    # DEPTH, but each of those 50 levels re-walks the entire nested
    # var context from scratch, so real-world `ansible_facts` (hundreds
    # of nested leaf strings from a live `setup` module gather) turned
    # a cheap single re-template into 50x that walk - pegged a CPU
    # core indefinitely in practice (observed >30s with zero progress)
    # long before the depth cap was reached. This spec mirrors that
    # shape (one block-tag var + a facts-sized nested var context) and
    # must complete promptly, not hang.
    # Mirrors prometheus.prometheus._common's own real vars/main.yml
    # (trimmed to the entries that matter for this shape) - other
    # {{ }}-templated vars in the same scope, referencing filters/
    # lookups of their own, are what turned the bounded recursion
    # depth into real wall-clock cost.
    v = Hash(String, JSON::Any).new
    v["ansible_facts"] = JSON.parse(%({"pkg_mgr":"apt","python_version":"3.10"}))
    v["ansible_parent_role_names"] = JSON.parse(%(["prometheus.prometheus.node_exporter"]))
    v["ansible_collection_name"] = JSON::Any.new("prometheus.prometheus")
    v["_common_dependencies"] = JSON::Any.new(
      %({% if (ansible_facts['pkg_mgr'] == 'apt') %}{{ ('python-apt' if ansible_facts['python_version'] is version('3', '<') else 'python3-apt') -}}{% else %}{% endif %})
    )
    v["_common_binary_name"] = JSON::Any.new(%({{ __common_binary_basename }}))
    v["_common_service_name"] = JSON::Any.new(%({{ __common_parent_role_short_name }}))
    v["_common_binary_url"] = JSON::Any.new("")
    v["__common_binary_basename"] = JSON::Any.new(%({{ _common_binary_url | urlsplit('path') | basename }}))
    v["__common_parent_role_short_name"] = JSON::Any.new(
      %({{ ansible_parent_role_names | first | regex_replace(ansible_collection_name ~ '.', '') }})
    )
    v["__common_github_api_headers"] = JSON::Any.new(
      %({{ {'GITHUB_TOKEN': lookup('ansible.builtin.env', 'GITHUB_TOKEN')} if (lookup('ansible.builtin.env', 'GITHUB_TOKEN')) else {} }})
    )
    renderer = CrystalPlay::VariableSubstitutor::CrinjaRenderer.new(v)

    started = Time.instant
    result = renderer.render("{{ _common_dependencies }}")
    elapsed = Time.instant - started

    result.should eq("python3-apt")
    elapsed.should be < 3.seconds
  end
end
