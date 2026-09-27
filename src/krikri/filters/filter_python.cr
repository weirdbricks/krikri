require "json"

module Krikri
  module VariableSubstitutor
    # Python-delegation paths: role-local `filter_plugins/*.py` custom filters
    # (try_python_filter) and the krikri-jinja registration seam
    # (delegate_to_jinja_filter)
    class FilterEngine
      # Runs *filter_name* from a role-local/playbook-adjacent
      # `filter_plugins/*.py` source (if one exists and defines the
      # name) against *value*, returning the structured result - or nil
      # whenever the mechanism is unavailable or fails, so the caller
      # raises the unchanged UnknownFilterError. The filter runs
      # controller-side (real Ansible loads filter plugins during
      # template rendering, never on the target), via the controller's
      # own python3.
      private def try_python_filter(value : JSON::Any, filter_name : String, filter_args : String) : JSON::Any?
        vars = @vars
        return nil unless vars
        role_path = vars["role_path"]?.try(&.as_s?)
        playbook_dir = vars["playbook_dir"]?.try(&.as_s?)
        return nil unless role_path || playbook_dir

        sources = PythonFilterRunner.find_sources(role_path, playbook_dir)
        return nil if sources.empty?
        return nil unless PythonFilterRunner.defines_filter?(filter_name, sources)

        pos_args = [] of JSON::Any
        kwargs = Hash(String, JSON::Any).new
        split_top_level_args(filter_args).each do |raw|
          if (kwarg = raw.match(/^\s*([A-Za-z_]\w*)\s*=(?!=)\s*(.*)$/m)) &&
             !quoted_literal?(raw.strip)
            kwargs[kwarg[1]] = resolve_expression(kwarg[2])
          else
            pos_args << resolve_expression(raw)
          end
        end

        # @vars rides along so a @pass_context-decorated filter (e.g.
        # stackhpc.luks's luks_key family, round 952562) gets a Context
        # stub that can actually resolve play variables - see
        # PythonFilterRunner's header.
        PythonFilterRunner.call_filter(filter_name, sources, value, pos_args, kwargs, vars)
      rescue ex : PythonFilterRunner::FilterError
        # The filter was FOUND and dispatched - a failure past this point
        # is the filter's own error (an exception it raised), never an
        # unknown-filter condition. The blanket rescue below used to
        # swallow this too, so Accelize.aws_fpga's round-83177 task
        # failed as "No filter named 'xrt_latest'." where real Ansible
        # fails the same task with the filter's actual error ("The
        # filter plugin 'xrt_latest' failed: No XRT version found for
        # this OS", ansible-core 2.19.4 live-verified) - report the real
        # cause, in real Ansible's wording. Everything else (no python3,
        # no sources, name not defined by any source) still degrades to
        # nil -> the plain UnknownFilterError above, exactly as before.
        raise FilterFailureError.new(
          (ex.message || "filter failed").sub(
            /^custom filter '#{filter_name}' failed: /,
            "The filter plugin '#{filter_name}' failed: "
          )
        )
      rescue
        nil
      end

      # The consolidation seam: dispatches one filter name to its single
      # registration on the shared krikri-jinja engine
      # (krikri_jinja_filters.cr) instead of a parallel hand-rolled
      # JSON::Any copy. *value* has already been fully resolved and
      # recursively re-rendered by the time a filter sees it, so it is
      # handed over as-is. The kwargs are the pre-parsed kwarg values
      # (#parse_kwarg / #split_positional_and_kwargs).
      #
      # String-kwarg convenience overload (dict2items shape). Only correct
      # for STRING kwargs - a boolean kwarg passed as its text form would
      # read "false" as truthy, so bool kwargs use the general overload.
      private def delegate_to_jinja_filter(name : String, value : JSON::Any, kwargs : Hash(String, String)) : JSON::Any
        delegate_to_jinja_filter(name, value, kwargs.transform_values { |text| JSON::Any.new(text) })
      end

      # General form: JSON kwarg values (so Bool kwargs survive as real
      # bools) plus optional positional varargs - the multi-argument shape
      # filters like `combine(other1, other2, ...)` need.
      private def delegate_to_jinja_filter(name : String, value : JSON::Any, kwargs : Hash(String, JSON::Any),
                                           varargs : Array(JSON::Any) = [] of JSON::Any) : JSON::Any
        engine = KrikriJinja.default_engine
        filter = engine.filters[name]
        context = KrikriJinja::Context.new(engine.globals, nil, false, KrikriJinja::Undefined.new, engine.filters, engine.tests)
        context.host_context = JinjaHostContext.new(@vars || Hash(String, JSON::Any).new)
        KrikriJinja.to_json_any(filter.call(
          KrikriJinja.from_json_any(value),
          varargs.map { |arg| KrikriJinja.from_json_any(arg) },
          kwargs.transform_values { |arg| KrikriJinja.from_json_any(arg) },
          context
        ))
      end
    end
  end
end
