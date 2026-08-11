require "json"
require "./variable_substitutor/expression_evaluator"
require "./variable_substitutor/comparison_evaluator"
require "./variable_substitutor/filter_engine"
require "./variable_substitutor/array_slicer"
require "./variable_substitutor/variable_lookup"
require "./variable_substitutor/crinja_renderer"

module CrystalPlay
  # Sentinel a rendered param value is compared against to detect real
  # Ansible's `omit` magic variable (`{{ item.proto | default(omit) }}` -
  # konstruktoid-hardening's "Allow outgoing specified ports" task uses
  # exactly this to drop `proto:` for loop items that don't specify one).
  # Real Ansible's `omit` causes the *parameter itself* to be dropped from
  # the module call entirely, not set to some placeholder value - can't be
  # represented as a plain rendered string, so FilterEngine's `default`
  # resolves a bare `omit` argument to this unique marker instead, and
  # #substitute_task_params (the one place that assembles a task's final
  # param hash) strips any key whose fully-substituted value equals it.
  OMIT_SENTINEL = "__crystal_ansible_omit__"

  # VariableSubstitutor - Main class for variable substitution
  # Uses modular components from variable_substitutor/ directory
  class VarSubstitutor
    @vars : Hash(String, JSON::Any)
    @host_name : String
    # Both are built on first use rather than in the constructor. A
    # VarSubstitutor is constructed 2-4x per task per host (when:,
    # execute_task_once, apply_changed_failed_when, delegate_to:), but
    # the overwhelmingly common case is a task whose params contain no
    # placeholders at all - `substitute` returns on the `includes?("{{")`
    # early exit and reaches neither component. Eagerly constructing them
    # meant ~98% of the cost of that case was the constructor, not the
    # substitution: ExpressionEvaluator alone builds four more objects
    # (ComparisonEvaluator, FilterEngine, ArraySlicer, VariableLookup).
    #
    # Behavior-preserving: both hold a reference to the same @vars hash
    # (they never copy it), so building one later observes exactly the
    # same variables it would have seen at construction time.
    @evaluator : VariableSubstitutor::ExpressionEvaluator?
    @renderer : VariableSubstitutor::CrinjaRenderer?

    # Guards the `{%`/`{#` escalation in #substitute against genuine
    # infinite recursion: CrinjaRenderer#prepare_crinja_vars pre-renders
    # any `{{`-containing variable value via a *fresh* VarSubstitutor
    # (see that method's own comment - "no risk of this recursing back
    # into this same render", which held only for a value containing
    # `{{` alone). A value containing BOTH `{{` AND a block tag (`{%`/
    # `{#`) escalates straight to `renderer.render` here, which calls
    # prepare_crinja_vars again on the *same* @vars, which builds
    # *another* fresh VarSubstitutor for the same still-unrendered
    # value, forever - real bug found benchmarking cloudalchemy.
    # grafana's own `grafana_package: "grafana{% if ... %}-rpi{% endif
    # %}{{ (grafana_version != 'latest') | ternary(...) }}"` (vars/
    # debian.yml - unconditional role vars, not a default), which
    # crashed the whole engine with a stack overflow instead of failing
    # one task. `@vars` is fixed for a renderer's lifetime and rendering
    # never yields the fiber (CrinjaRenderer's own shared_env comment),
    # so a single process-wide counter - not a per-instance one, since
    # each recursion level constructs a brand new VarSubstitutor/
    # CrinjaRenderer pair - is the correct guard here.
    @@block_tag_escalation_depth = 0
    MAX_BLOCK_TAG_ESCALATION_DEPTH = 50

    def initialize(vars : Hash(String, String | JSON::Any) = {} of String => String | JSON::Any, 
                   host_name : String = "localhost",
                   facts : Hash(String, JSON::Any) = {} of String => JSON::Any)
      @host_name = host_name
      
      # Convert all vars to JSON::Any
      @vars = Hash(String, JSON::Any).new
      vars.each do |key, value|
        @vars[key] = case value
        when JSON::Any
          value
        when String
          JSON::Any.new(value)
        else
          JSON.parse(value.to_json)
        end
      end
      
      # Add magic variables
      add_magic_variables(facts)
    end

    private def evaluator : VariableSubstitutor::ExpressionEvaluator
      @evaluator ||= VariableSubstitutor::ExpressionEvaluator.new(@vars)
    end

    private def renderer : VariableSubstitutor::CrinjaRenderer
      @renderer ||= VariableSubstitutor::CrinjaRenderer.new(@vars)
    end
    
    # Magic variables, using the same precedence TaskExecutor#
    # build_vars_context applies, so a bare `when:` and a `{{ }}`
    # expression can never disagree about what they mean.
    #
    # Only `inventory_hostname` is unconditional - it *is* the inventory
    # name and nothing else defines it. The other two are fallbacks:
    #
    # - `ansible_host` is the connection address. An inventory line like
    #   `web1 ansible_host=192.0.2.55` must win; overwriting it with the
    #   inventory name was wrong (verified against ansible-core 2.19.4:
    #   it reports 192.0.2.55) and, in vars_context, would also redirect
    #   PluginManager#get_connection_host to the wrong machine.
    # - `ansible_hostname` is a *fact* - the target's own hostname, which
    #   is frequently not the inventory name at all (ansible-core reports
    #   the real hostname). A gathered fact must win over this fallback.
    private def add_magic_variables(facts : Hash(String, JSON::Any))
      @vars["inventory_hostname"] = JSON::Any.new(@host_name)
      @vars["ansible_hostname"] ||= JSON::Any.new(@host_name)
      @vars["ansible_host"] ||= JSON::Any.new(@host_name)

      facts.each do |key, value|
        @vars["ansible_#{key}"] = value
      end
    end
    
    def substitute(text : String) : String
      return text unless text.includes?("{{")

      if text.includes?("{%") || text.includes?("{#")
        return text if @@block_tag_escalation_depth >= MAX_BLOCK_TAG_ESCALATION_DEPTH
        @@block_tag_escalation_depth += 1
        begin
          return renderer.render(text)
        ensure
          @@block_tag_escalation_depth -= 1
        end
      end

      result = expand_mustache_spans(text) { |inner| evaluator.evaluate(inner.strip).strip }

      # Ansible re-templates a rendered result that still contains "{{" -
      # this happens whenever a variable's own value is itself a template
      # string, e.g. dev-sec os_hardening's include_tasks loop items whose
      # fields are defaults like `mode: "{{ os_mnt_dev_dir_mode }}"`:
      # `{{ mount.mode }}` renders to that literal string on the first
      # pass, and needs a second pass to become the real "0755". Bounded
      # (and stops as soon as a pass makes no further progress) so a value
      # that can never fully resolve, or one that legitimately contains a
      # literal "{{", doesn't loop forever.
      #
      # A leftover "{%"/"{#" (not just "{{") needs the same re-pass, but
      # routed through the FULL Crinja renderer, not another mustache-
      # span-only pass - expand_mustache_spans has no concept of block
      # tags at all. Real bug found benchmarking githubixx.ansible_role_
      # wireguard: `wireguard_remote_directory`'s own default value is a
      # multi-line `{%- if ... -%}...{%- elif ... -%}...{%- endif -%}`
      # block (no `{{ }}` inside at all) - a task param like `dest: "{{
      # wireguard_remote_directory }}/{{ wireguard_conf_filename }}"`
      # fetched that raw block-tag text as a plain string (format_value
      # doesn't template it) and, since the outer loop only ever checked
      # for leftover "{{", never got a second pass to actually evaluate
      # it - the literal, unparsed "{%- if ... %}" text became the real
      # `dest:` path, so the config was never actually written anywhere
      # real, and the wg-quick service failed to start ("config file
      # does not exist") with no obvious tie back to this.
      depth = 0
      while (result.includes?("{{") || result.includes?("{%") || result.includes?("{#")) && depth < 5
        next_result = if result.includes?("{%") || result.includes?("{#")
                        break if @@block_tag_escalation_depth >= MAX_BLOCK_TAG_ESCALATION_DEPTH
                        @@block_tag_escalation_depth += 1
                        begin
                          renderer.render(result)
                        ensure
                          @@block_tag_escalation_depth -= 1
                        end
                      else
                        expand_mustache_spans(result) { |inner| evaluator.evaluate(inner.strip).strip }
                      end
        break if next_result == result
        result = next_result
        depth += 1
      end

      result
    end

    # Finds each `{{ ... }}` span in *text* and replaces it with the
    # block's return value, tracking brace depth (and quotes) inside the
    # expression so a literal `{}`/`{a: 1}` dict argument - e.g.
    # `default({})`, `combine({})` - doesn't get mistaken for the span's
    # own closing `}}`. The previous implementation used
    # `/\{\{([^}]+)\}\}/`, whose `[^}]+` cannot match *any* `}` character
    # at all, so an expression containing an inner `}` (from a dict
    # literal) could never find a valid close and was left completely
    # unrendered.
    private def expand_mustache_spans(text : String, & : String -> String) : String
      result = String::Builder.new
      i = 0
      n = text.size
      while i < n
        if i + 1 < n && text[i] == '{' && text[i + 1] == '{'
          close_at = find_mustache_close(text, i + 2)
          if close_at
            result << yield text[(i + 2)...close_at]
            i = close_at + 2
            next
          end
        end
        result << text[i]
        i += 1
      end
      result.to_s
    end

    # Scans from *start* (just past the opening `{{`) for the `}}` that
    # closes this expression, treating any `{`/`}` that appears inside a
    # quoted string or inside a balanced `{...}` sub-expression as part of
    # the expression body rather than the terminator. Returns the index of
    # the first `}` of the closing `}}`, or nil if none is found.
    private def find_mustache_close(text : String, start : Int32) : Int32?
      state = MustacheScanState.new
      j = start
      n = text.size
      while j < n
        return j if state.closes_at?(text, j)
        j += 1
      end
      nil
    end

    # Per-character scan state for #find_mustache_close - split out so the
    # scanning loop itself stays a single branch, and the "is this `}` the
    # real close, an inner literal `}`, or the start of a nested `{...}`"
    # decision lives in one place.
    private class MustacheScanState
      property depth = 0
      property quote : Char? = nil

      def closes_at?(text : String, j : Int32) : Bool
        char = text[j]
        if q = quote
          self.quote = nil if char == q
          return false
        end

        case char
        when '\'', '"'
          self.quote = char
          false
        when '{'
          self.depth += 1
          false
        when '}'
          brace_closes?(text, j)
        else
          false
        end
      end

      private def brace_closes?(text : String, j : Int32) : Bool
        if depth > 0
          self.depth -= 1
          false
        else
          j + 1 < text.size && text[j + 1] == '}'
        end
      end
    end

    def substitute_hash(hash : Hash(String, String)) : Hash(String, String)
      result = Hash(String, String).new
      hash.each { |k, v| result[substitute(k)] = substitute(v) }
      result
    end
    
    def substitute_array(array : Array(String)) : Array(String)
      array.map { |item| substitute(item) }
    end
    
    def set_variable(name : String, value : String | JSON::Any)
      @vars[name] = value.is_a?(JSON::Any) ? value : JSON::Any.new(value)
      # Invalidate rather than eagerly rebuild - same semantics, and the
      # next `substitute` rebuilds only whichever component it actually
      # needs. Nulling the renderer is what drops its memoized
      # JSON::Any -> Crinja::Value conversion of the old variable set,
      # so this must stay in step with CrinjaRenderer's @template_vars.
      @evaluator = nil
      @renderer = nil
    end
    
    def get_vars : Hash(String, JSON::Any)
      @vars
    end
    
    def has_variable?(name : String) : Bool
      @vars.has_key?(name)
    end
  end
end
