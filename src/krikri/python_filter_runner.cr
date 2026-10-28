require "json"
require "krikri-jinja/krikri_jinja"

# Runner for role-local custom FILTER plugins - a role's own
# `filter_plugins/*.py` (and the playbook-adjacent `filter_plugins/`),
# the filter-side twin of PythonModuleRunner's `library/*.py` support
# (0.9.819). Ansible loads a role's own `filter_plugins/` directory
# on the CONTROLLER the same way it loads role-private modules: a plugin
# file exposing a `FilterModule` class whose `filters()` method returns
# the `{filter_name: callable}` dict (e.g. stackhpc.luks's `luks_key`,
# MichaelRigart.interfaces's `bond_check`). Before this, any task
# templating through such a filter hard-failed with "No filter named
# 'X'." where ansible-playbook resolved and ran it.
#
# Unlike a module, a filter runs controller-side during Jinja2 template
# rendering - there is nothing to upload to a target. The runner instead
# delegates to the CONTROLLER's own python3 (the same interpreter
# Ansible itself needs on the controller): a small wrapper script is fed
# the plugin source paths plus the filter call as JSON on stdin, imports
# the plugin files, instantiates `FilterModule`, calls `filters()`, and
# either reports the exposed names ("list") or invokes the requested
# filter with the given arguments and prints the JSON-encoded result
# ("call"). No Python is embedded or reimplemented here; nothing runs
# unless a `filter_plugins/*.py` source actually exists for the current
# role/playbook, and every failure (no python3, plugin syntax error, an
# exception inside the filter, a non-JSON-serializable result) degrades
# to the caller - which falls back to the plain "No filter named 'X'."
# UnknownFilterError exactly as before, so roles WITHOUT custom filter
# plugins (the overwhelming majority) behave bit-for-bit identically.
#
# Deliberately scoped to role-private `filter_plugins/` directories and
# the playbook-adjacent `filter_plugins/` (Ansible's two most
# common search roots, mirroring PythonModuleRunner#find_source);
# third-party COLLECTION filter plugins (bodsch.*, community.*) are
# still the unchanged scope cut - those live inside installed
# collections, not in the playbook tree this runner can see.
#
# `@pass_context`-decorated filters (stackhpc.luks's whole
# `filter_plugins/general.py` - `luks_key` etc., round 952562) follow
# Jinja2's calling convention: Jinja auto-injects a Context as the
# FIRST positional argument, ahead of the piped value, so `{{ item |
# luks_key }}` calls `luks_key(context, item)`. Calling the function
# with just the piped value put `item` in the `context` slot and failed
# with "missing 1 required positional argument". The wrapper detects
# the decoration (`jinja_pass_arg` for jinja2 >= 3.0, the older
# `contextfilter` marker for < 3.0) and prepends a minimal stub
# Context built from the play vars the Crystal caller passes along.
# The stub is NOT a real jinja2 Context: it supports the common
# access patterns (`context.get(name)`/`context.resolve(name)`/
# `context['name']`/`context.vars`/`context.get_all()`) over the
# play's variable snapshot only - no hostvars resolution, no template
# caching, no lazy evaluation - which covers filters that read play
# variables but not ones relying on deeper Context machinery.
module Krikri
  module PythonFilterRunner
    extend self

    # Raised when a filter invocation fails after the filter was found
    # and dispatched (a Python exception inside the filter, an
    # unparseable wrapper response). Callers either degrade to the
    # plain unknown-filter error or surface it as a task failure.
    class FilterError < Exception
    end

    # Every legacy role LOADED this run contributes its plugin directories
    # to the search path for the REST of the run, matching ansible-core's
    # `add_all_plugin_dirs(self._role_path)` at Role.load: a meta
    # dependency's filters (nephelaiio.plugins' `sorted_get` serving
    # nephelaiio.i3's own defaults, round 5250000) stay reachable from
    # every later task, not only from the dependent role's own. Populated
    # by RoleLoader.load_role for non-collection roles; load order kept
    # (deduped) so the nearest role's plugin wins a name conflict, like
    # the loader's own append order.
    @@loaded_role_plugin_roots = {} of String => Array(String)
    @@plugin_roots_mutex = Mutex.new

    def register_role_plugin_roots(role_path : String, collection_name : String? = nil) : Nil
      # Collection-hosted roles resolve plugins through their collection,
      # not role-adjacent directories - Ansible's own gate at Role.load.
      return if collection_name
      @@plugin_roots_mutex.synchronize do
        {"filter_plugins", "test_plugins", "library"}.each do |subdir|
          dir = File.join(role_path, subdir)
          next unless Dir.exists?(dir)
          roots = @@loaded_role_plugin_roots[subdir] ||= [] of String
          roots << dir unless roots.includes?(dir)
        end
      end
    end

    # Directories whose filter_plugins/ files scan_unloadable_plugins has
    # already handed to filter_names. Roles load all run long (play roles,
    # meta dependencies, include_role:), so the render-entry trigger calls
    # back whenever ANY marker-bearing string is rendered, and only still-
    # unseen directories cost a scan. The trigger's own mutex also keeps
    # concurrent render fibers from scanning the same not-yet-cached file
    # in parallel, which would print its warning twice - the once-per-file
    # behaviour filter_names relies on is not itself mutex-protected.
    @@scanned_filter_dirs = Set(String).new
    @@scan_mutex = Mutex.new

    # The "Skipping plugin" warning for an unloadable filter_plugins/*.py
    # file fires when the Templar first compiles a template that USES A
    # FILTER (live-verified against ansible-playbook 2.19.11 for issue
    # #307): `{{ 1 + 1 }}`, a block-tag-only string, a test-only `x is
    # defined` and a static template: file all print NOTHING, while the
    # first `|`-filter-bearing templating (builtin or custom, task param
    # or template-module .j2) imports every file of every loaded role's
    # (and the playbook-adjacent) filter_plugins/ and warns inline at
    # that point. Merely containing Jinja markers is NOT the trigger,
    # and the eager scan-at-Role.load this replaces was even further
    # off: it printed the warning before PLAY even started.
    def scan_unloadable_plugins(playbook_dir : String? = nil) : Nil
      @@scan_mutex.synchronize do
        # The playbook-adjacent directory warns FIRST, before the loaded
        # roles' directories, matching the observed ansible-playbook
        # warning order (live-verified vs 2.19.11) - find_sources' own
        # resolution precedence (roles first) is untouched by this.
        roots = [] of String
        roots << File.join(playbook_dir, "filter_plugins") if playbook_dir && !playbook_dir.empty?
        roots.concat(loaded_role_roots("filter_plugins"))
        roots.each do |dir|
          next if @@scanned_filter_dirs.includes?(dir)
          @@scanned_filter_dirs << dir
          next unless Dir.exists?(dir)
          files = py_sources_in(dir)
          filter_names(files) unless files.empty?
        end
      end
    end

    # Every filter call in the AST as (name, line) pairs, in source order.
    # The shared walk behind the filter_plugins scan gate AND the template
    # action's compile-time filter-name validation: Ansible/Jinja2 compile
    # the whole template, so a filter name is resolved even inside a branch
    # that never executes (see TemplateActionPlugin#validate_template_filters).
    def self.collect_filter_calls(node : KrikriJinja::Nodes::Node) : Array({String, Int32})
      collect_node_filters(node)
    end

    # The compile-frame twin of collect_filter_calls, used by the template
    # action's filter-name validation: only the (name, line) pairs real
    # Jinja2 resolves at COMPILE time. compiler.py's _filter_test_common
    # fails "No filter named 'x'." up front only when the filter's frame
    # is not soft; visit_If (if_frame = frame.soft()) and visit_CondExpr
    # (frame = frame.soft()) hand soft frames to everything they enclose,
    # so an unknown filter in a never-executed if branch or conditional
    # expression is deferred and surfaces at render time instead. Every
    # other block construct (for, with, filter/set/call block, macro,
    # block) builds its frame with Frame.inner(), whose constructor
    # unconditionally resets soft_frame to False - which is why a for
    # nested in a dead if still fails at compile time even though the if
    # never runs (live-verified vs 2.19.11, issue #660).
    def self.collect_compile_time_filter_calls(node : KrikriJinja::Nodes::Node) : Array({String, Int32})
      compile_frame_filters(node, false)
    end

    # The render-side triggers: a parsed template/expression whose AST
    # contains a filter call runs the scan once (already-scanned dirs
    # are skipped inside). The AST walk is the exact gate - a naive
    # "text contains |" would also fire on a pipe inside a string
    # literal, printing a warning where ansible stays silent.
    def self.scan_for_filter_use(template : KrikriJinja::Nodes::TemplateNode, playbook_dir : String?) : Nil
      scan_unloadable_plugins(playbook_dir) unless collect_filter_calls(template).empty?
    end

    def self.scan_for_filter_use(expr : KrikriJinja::Nodes::ExprNode, playbook_dir : String?) : Nil
      scan_unloadable_plugins(playbook_dir) unless collect_filter_calls(expr).empty?
    end

    # Same gate for callers that hold only the expression SOURCE text
    # (executor paths that hand the bare expression straight to the
    # engine). A parse failure can never be filter-related, so it skips
    # the scan - the render itself reports the syntax problem later.
    def self.scan_for_filter_expression(source : String, playbook_dir : String?) : Nil
      scan_for_filter_use(KrikriJinja.parse_expression(source), playbook_dir)
    rescue KrikriJinja::TemplateError
      nil
    end

    private def self.collect_node_filters(node : KrikriJinja::Nodes::Node) : Array({String, Int32})
      case node
      when KrikriJinja::Nodes::FilterNode
        collect_expr_filters(node)
      when KrikriJinja::Nodes::FilterBlockNode
        collect_expr_filters(node.filter) + collect_list_filters(node.body)
      when KrikriJinja::Nodes::TemplateNode
        collect_list_filters(node.body)
      when KrikriJinja::Nodes::OutputNode
        collect_expr_filters(node.expr)
      when KrikriJinja::Nodes::IfNode
        collect_if_filters(node)
      when KrikriJinja::Nodes::ForNode
        collect_for_filters(node)
      else
        collect_template_rest_filters(node)
      end
    end

    private def self.collect_if_filters(node : KrikriJinja::Nodes::IfNode) : Array({String, Int32})
      branch_calls = node.branches.flat_map do |(cond, body)|
        collect_expr_filters(cond) + collect_list_filters(body)
      end
      branch_calls + collect_body_filters(node.orelse)
    end

    private def self.collect_for_filters(node : KrikriJinja::Nodes::ForNode) : Array({String, Int32})
      collect_expr_filters(node.iter) + collect_opt_expr_filters(node.test) +
        collect_list_filters(node.body) + collect_body_filters(node.orelse)
    end

    # The less common template-level node kinds (named blocks, macros,
    # with/import/include/...) - split out only to keep each walker's
    # cyclomatic complexity at the ameba gate.
    private def self.collect_template_rest_filters(node : KrikriJinja::Nodes::Node) : Array({String, Int32})
      case node
      when KrikriJinja::Nodes::SetNode
        collect_set_filters(node)
      when KrikriJinja::Nodes::BlockNode
        collect_list_filters(node.body)
      when KrikriJinja::Nodes::MacroNode
        collect_macro_filters(node)
      when KrikriJinja::Nodes::CallNode
        collect_call_filters(node)
      when KrikriJinja::Nodes::WithNode
        collect_with_filters(node)
      when KrikriJinja::Nodes::IncludeNode, KrikriJinja::Nodes::ExtendsNode, KrikriJinja::Nodes::ImportNode
        collect_expr_filters(node.template)
      when KrikriJinja::Nodes::DoNode
        collect_expr_filters(node.expr)
      when KrikriJinja::Nodes::AutoescapeNode
        collect_list_filters(node.body)
      else
        [] of {String, Int32}
      end
    end

    private def self.collect_set_filters(node : KrikriJinja::Nodes::SetNode) : Array({String, Int32})
      block_filter = if name = node.filter_name
                       [{name, node.line}]
                     else
                       [] of {String, Int32}
                     end
      block_filter + collect_args_filters(node.filter_args, node.filter_kwargs) +
        collect_expr_filters(node.expr) + collect_opt_expr_filters(node.attr_target) +
        collect_body_filters(node.body)
    end

    private def self.collect_macro_filters(node : KrikriJinja::Nodes::MacroNode) : Array({String, Int32})
      param_defaults = node.params.flat_map { |(_, default)| collect_opt_expr_filters(default) }
      collect_list_filters(node.body) + param_defaults
    end

    private def self.collect_call_filters(node : KrikriJinja::Nodes::CallNode) : Array({String, Int32})
      collect_expr_filters(node.macro_expr) + collect_args_filters(node.args, node.kwargs) +
        collect_body_filters(node.body)
    end

    private def self.collect_with_filters(node : KrikriJinja::Nodes::WithNode) : Array({String, Int32})
      node.bindings.flat_map { |(_, value)| collect_expr_filters(value) } +
        collect_list_filters(node.body)
    end

    private def self.collect_expr_filters(expr : KrikriJinja::Nodes::ExprNode) : Array({String, Int32})
      case expr
      when KrikriJinja::Nodes::FilterNode
        [{expr.name, expr.line}] + collect_expr_filters(expr.target) +
          collect_args_filters(expr.args, expr.kwargs)
      when KrikriJinja::Nodes::ConstNode, KrikriJinja::Nodes::NameNode, KrikriJinja::Nodes::InTestNode
        [] of {String, Int32}
      when KrikriJinja::Nodes::ListExprNode
        expr.items.flat_map { |item| collect_expr_filters(item) }
      when KrikriJinja::Nodes::TupleExprNode
        expr.items.flat_map { |item| collect_expr_filters(item) }
      when KrikriJinja::Nodes::DictExprNode
        expr.keys.flat_map { |key| collect_expr_filters(key) } +
          expr.values.flat_map { |value| collect_expr_filters(value) }
      when KrikriJinja::Nodes::BinOpNode
        collect_expr_filters(expr.left) + collect_expr_filters(expr.right)
      when KrikriJinja::Nodes::UnaryOpNode
        collect_expr_filters(expr.operand)
      when KrikriJinja::Nodes::CompareNode
        collect_expr_filters(expr.left) +
          expr.comparators.flat_map { |comparator| collect_expr_filters(comparator) }
      else
        collect_expr_rest_filters(expr)
      end
    end

    private def self.collect_expr_rest_filters(expr : KrikriJinja::Nodes::ExprNode) : Array({String, Int32})
      case expr
      when KrikriJinja::Nodes::TestNode
        # A test itself (`x is defined`) does NOT build the filter set in
        # real ansible - live-verified: `{{ 1 is defined }}` prints no
        # warning while `{{ [1, 2] | first }}` does - but a filter nested
        # inside the test's target/arguments does.
        collect_expr_filters(expr.target) + collect_args_filters(expr.args, expr.kwargs)
      when KrikriJinja::Nodes::GetattrNode
        collect_expr_filters(expr.obj)
      when KrikriJinja::Nodes::GetitemNode
        collect_expr_filters(expr.obj) + collect_expr_filters(expr.key)
      when KrikriJinja::Nodes::SliceNode
        collect_slice_filters(expr)
      when KrikriJinja::Nodes::CallExprNode
        collect_expr_filters(expr.func) + collect_args_filters(expr.args, expr.kwargs)
      when KrikriJinja::Nodes::CondExprNode
        collect_cond_filters(expr)
      when KrikriJinja::Nodes::ConcatNode
        expr.parts.flat_map { |part| collect_expr_filters(part) }
      else
        [] of {String, Int32}
      end
    end

    private def self.collect_slice_filters(expr : KrikriJinja::Nodes::SliceNode) : Array({String, Int32})
      collect_expr_filters(expr.obj) + collect_opt_expr_filters(expr.start) +
        collect_opt_expr_filters(expr.stop) + collect_opt_expr_filters(expr.step)
    end

    private def self.collect_cond_filters(expr : KrikriJinja::Nodes::CondExprNode) : Array({String, Int32})
      collect_expr_filters(expr.test) + collect_expr_filters(expr.truthy) +
        collect_opt_expr_filters(expr.falsy)
    end

    # Nilable slots (an `{% if %}`/`{% for %}` `{% else %}` body, a
    # `{% set %}`/`{% call %}` body, the nilable `{% for %}` inline
    # test / slice bound / macro default / condexpr falsy arm) contribute
    # exactly when they carry a filter call; the non-nilable trio siblings
    # keep every collector's `+` chain at the ameba gate.
    private def self.collect_body_filters(body : Array(KrikriJinja::Nodes::Node)?) : Array({String, Int32})
      body.try { |list| collect_list_filters(list) } || [] of {String, Int32}
    end

    private def self.collect_list_filters(body : Array(KrikriJinja::Nodes::Node)) : Array({String, Int32})
      body.flat_map { |child| collect_node_filters(child) }
    end

    private def self.collect_opt_expr_filters(expr : KrikriJinja::Nodes::ExprNode?) : Array({String, Int32})
      expr.try { |sub| collect_expr_filters(sub) } || [] of {String, Int32}
    end

    private def self.collect_args_filters(args : Array(KrikriJinja::Nodes::ExprNode),
                                          kwargs : Array(Tuple(String, KrikriJinja::Nodes::ExprNode))) : Array({String, Int32})
      args.flat_map { |arg| collect_expr_filters(arg) } +
        kwargs.flat_map { |(_, value)| collect_expr_filters(value) }
    end

    # The soft-frame-aware twins of the collectors above: the same walk,
    # but a FilterNode is kept only when its frame is not soft (the
    # `soft` argument mirrors compiler.py's Frame.soft_frame).
    private def self.compile_frame_filters(node : KrikriJinja::Nodes::Node,
                                           soft : Bool) : Array({String, Int32})
      case node
      when KrikriJinja::Nodes::IfNode
        # visit_If: if_frame = frame.soft() covers the test, every elif
        # and the else body - soft no matter what frame the if sits in
        node.branches.flat_map { |(_, body)| compile_body_filters(body, true) } +
          compile_body_filters(node.orelse, true)
      when KrikriJinja::Nodes::ForNode
        # visit_For: the iter is visited with the ENCLOSING frame, but
        # the inline test and the body/else get frame.inner() frames
        # whose constructor resets soft_frame to False
        compile_expr_filters(node.iter, soft) +
          compile_opt_expr_filters(node.test, false) +
          compile_body_filters(node.body, false) +
          compile_body_filters(node.orelse, false)
      when KrikriJinja::Nodes::SetNode
        # a set BLOCK is an AssignBlock inner frame; a plain `{% set %}`
        # visits its expressions with the frame it sits in
        set_soft = node.body ? false : soft
        block_filter = node.filter_name.try { |name| [{name, node.line}] } || [] of {String, Int32}
        block_filter + compile_args_filters(node.filter_args, node.filter_kwargs, set_soft) +
          compile_expr_filters(node.expr, set_soft) +
          compile_opt_expr_filters(node.attr_target, set_soft) +
          compile_body_filters(node.body, set_soft)
      when KrikriJinja::Nodes::CallNode
        # the call itself is visited with the enclosing frame, the
        # macro body (call block) is a macro_body inner frame
        compile_expr_filters(node.macro_expr, soft) +
          compile_args_filters(node.args, node.kwargs, soft) +
          compile_body_filters(node.body, false)
      when KrikriJinja::Nodes::WithNode
        # visit_With: the values are visited with the ENCLOSING frame,
        # the body with the inner with_frame
        node.bindings.flat_map { |(_, value)| compile_expr_filters(value, soft) } +
          compile_body_filters(node.body, false)
      when KrikriJinja::Nodes::FilterBlockNode
        # visit_FilterBlock: even the filter expression is visited with
        # the inner filter_frame
        compile_expr_filters(node.filter, false) + compile_body_filters(node.body, false)
      when KrikriJinja::Nodes::BlockNode, KrikriJinja::Nodes::AutoescapeNode
        compile_body_filters(node.body, false)
      when KrikriJinja::Nodes::MacroNode
        # macro_body's inner frame - a macro's filters resolve when the
        # macro is DEFINED, not when it is called
        node.params.flat_map { |(_, default)| compile_opt_expr_filters(default, false) } +
          compile_body_filters(node.body, false)
      else
        compile_frame_rest_filters(node, soft)
      end
    end

    private def self.compile_frame_rest_filters(node : KrikriJinja::Nodes::Node,
                                                soft : Bool) : Array({String, Int32})
      case node
      when KrikriJinja::Nodes::TemplateNode
        compile_body_filters(node.body, soft)
      when KrikriJinja::Nodes::OutputNode
        compile_expr_filters(node.expr, soft)
      when KrikriJinja::Nodes::DoNode
        compile_expr_filters(node.expr, soft)
      when KrikriJinja::Nodes::IncludeNode, KrikriJinja::Nodes::ExtendsNode, KrikriJinja::Nodes::ImportNode
        compile_expr_filters(node.template, soft)
      else
        [] of {String, Int32}
      end
    end

    private def self.compile_body_filters(body : Array(KrikriJinja::Nodes::Node)?,
                                          soft : Bool) : Array({String, Int32})
      body.try { |list| compile_list_filters(list, soft) } || [] of {String, Int32}
    end

    private def self.compile_list_filters(body : Array(KrikriJinja::Nodes::Node),
                                          soft : Bool) : Array({String, Int32})
      body.flat_map { |child| compile_frame_filters(child, soft) }
    end

    private def self.compile_opt_expr_filters(expr : KrikriJinja::Nodes::ExprNode?,
                                              soft : Bool) : Array({String, Int32})
      expr.try { |sub| compile_expr_filters(sub, soft) } || [] of {String, Int32}
    end

    private def self.compile_args_filters(args : Array(KrikriJinja::Nodes::ExprNode),
                                          kwargs : Array(Tuple(String, KrikriJinja::Nodes::ExprNode)),
                                          soft : Bool) : Array({String, Int32})
      args.flat_map { |arg| compile_expr_filters(arg, soft) } +
        kwargs.flat_map { |(_, value)| compile_expr_filters(value, soft) }
    end

    # Inside an expression subtree softness can only CHANGE at a
    # conditional expression (visit_CondExpr softens its whole subtree
    # including the test); a soft frame stays soft for everything below
    # it, so a soft expression defers every filter it holds.
    private def self.compile_expr_filters(expr : KrikriJinja::Nodes::ExprNode,
                                          soft : Bool) : Array({String, Int32})
      return [] of {String, Int32} if soft
      case expr
      when KrikriJinja::Nodes::CondExprNode
        # frame = frame.soft() before the test and both arms are visited,
        # so nothing in a conditional expression resolves at compile time
        [] of {String, Int32}
      when KrikriJinja::Nodes::FilterNode
        [{expr.name, expr.line}] + compile_expr_filters(expr.target, false) +
          compile_args_filters(expr.args, expr.kwargs, false)
      when KrikriJinja::Nodes::ConstNode, KrikriJinja::Nodes::NameNode, KrikriJinja::Nodes::InTestNode
        [] of {String, Int32}
      when KrikriJinja::Nodes::ListExprNode, KrikriJinja::Nodes::TupleExprNode
        expr.items.flat_map { |item| compile_expr_filters(item, false) }
      when KrikriJinja::Nodes::DictExprNode
        expr.keys.flat_map { |key| compile_expr_filters(key, false) } +
          expr.values.flat_map { |value| compile_expr_filters(value, false) }
      when KrikriJinja::Nodes::BinOpNode
        compile_expr_filters(expr.left, false) + compile_expr_filters(expr.right, false)
      when KrikriJinja::Nodes::UnaryOpNode
        compile_expr_filters(expr.operand, false)
      when KrikriJinja::Nodes::CompareNode
        compile_expr_filters(expr.left, false) +
          expr.comparators.flat_map { |comparator| compile_expr_filters(comparator, false) }
      else
        compile_expr_rest_filters(expr)
      end
    end

    private def self.compile_expr_rest_filters(expr : KrikriJinja::Nodes::ExprNode) : Array({String, Int32})
      case expr
      when KrikriJinja::Nodes::TestNode
        compile_expr_filters(expr.target, false) + compile_args_filters(expr.args, expr.kwargs, false)
      when KrikriJinja::Nodes::GetattrNode
        compile_expr_filters(expr.obj, false)
      when KrikriJinja::Nodes::GetitemNode
        compile_expr_filters(expr.obj, false) + compile_expr_filters(expr.key, false)
      when KrikriJinja::Nodes::SliceNode
        compile_expr_filters(expr.obj, false) + compile_opt_expr_filters(expr.start, false) +
          compile_opt_expr_filters(expr.stop, false) + compile_opt_expr_filters(expr.step, false)
      when KrikriJinja::Nodes::CallExprNode
        compile_expr_filters(expr.func, false) + compile_args_filters(expr.args, expr.kwargs, false)
      when KrikriJinja::Nodes::ConcatNode
        expr.parts.flat_map { |part| compile_expr_filters(part, false) }
      else
        [] of {String, Int32}
      end
    end

    # The callback_plugins twin (issue #596, ovirt.disaster-recovery
    # 1.3.0's stdout.py: `from __future__ import` after other imports ->
    # SyntaxError). Unlike the filter scan above, Ansible's callback
    # loader imports a role's callback_plugins/*.py EAGERLY at role
    # load, so the warning fires at playbook load time - before the
    # first PLAY banner - and only for roles loaded STATICALLY (play
    # roles:, import_role:, and their meta dependencies): a role reached
    # only through include_role: prints nothing (live-verified vs
    # 2.19.11). Directory-scoped so a role loaded twice (a play role also
    # import_role:'d) costs one scan, and the per-file warning dedup
    # below comes from filter_names' own once-per-file cache.
    @@scanned_callback_dirs = Set(String).new

    # Ansible's "Skipping plugin" warning for a role's unloadable
    # callback_plugins/*.py, emitted at the static role load itself
    # (which for krikri's parser is playbook parse time, before any PLAY
    # output). Reuses the filter wrapper's import check: a file that
    # fails to import is reported skipped with str(exc) - for a
    # SyntaxError exactly Ansible's tail ("from __future__ imports must
    # occur at the beginning of the file (stdout.py, line 6)"). A VALID
    # callback file just imports cleanly and contributes no filter names
    # (find_sources never consults callback_plugins/ roots), so nothing
    # is registered or executed beyond the import check Ansible itself
    # performs at load.
    def warn_unloadable_role_callback_plugins(role_path : String, collection_name : String? = nil) : Nil
      # Collection-hosted roles resolve plugins through their collection,
      # not role-adjacent directories - same gate as
      # register_role_plugin_roots.
      return if collection_name
      dir = File.join(role_path, "callback_plugins")
      @@scan_mutex.synchronize do
        return if @@scanned_callback_dirs.includes?(dir)
        @@scanned_callback_dirs << dir
      end
      return unless Dir.exists?(dir)
      files = py_sources_in(dir)
      filter_names(files) unless files.empty?
    end

    # Test teardown support for the registry scan trigger touches: a spec
    # that registers a fixture role would otherwise keep it reachable from
    # EVERY later marker-bearing render in the suite process (the trigger
    # consults the loaded-role registry), so specs must deregister their
    # fixtures and their scanned-dir coverage before finishing.
    def unregister_role_plugin_roots_under(base_path : String) : Nil
      @@plugin_roots_mutex.synchronize do
        @@loaded_role_plugin_roots.each_value do |roots|
          roots.reject! { |dir| dir.starts_with?(base_path) }
        end
        @@loaded_role_plugin_roots.reject! { |_, roots| roots.empty? }
      end
      @@scan_mutex.synchronize do
        @@scanned_filter_dirs.reject! { |dir| dir.starts_with?(base_path) }
        @@scanned_callback_dirs.reject! { |dir| dir.starts_with?(base_path) }
      end
    end

    # Every direct `.py` child under a plugin directory. Ansible loads
    # ALL files in a plugin directory, not name-matched ones, so there
    # is no per-filter filename check here the way a module's
    # `library/<name>.py` lookup has.
    private def py_sources_in(root : String) : Array(String)
      sources = [] of String
      Dir.each_child(root) do |entry|
        next unless entry.ends_with?(".py")
        path = File.join(root, entry)
        sources << path if File.file?(path)
      end
      sources
    end

    def loaded_role_roots(subdir : String) : Array(String)
      @@plugin_roots_mutex.synchronize do
        @@loaded_role_plugin_roots[subdir]?.try(&.dup) || [] of String
      end
    end

    # Finds every `.py` file under the role's own `filter_plugins/`, the
    # `filter_plugins/` of every role LOADED so far this run (Ansible's
    # add_all_plugin_dirs at Role.load - a meta dependency's filters stay
    # reachable from every later task, which is how nephelaiio.plugins'
    # `sorted_get` served nephelaiio.i3's own defaults, round 5250000),
    # and the playbook-adjacent `filter_plugins/` (nearest-first order;
    # Ansible loads ALL files in a plugin directory, not name-matched
    # ones, so there is no per-filter filename check here the way a
    # module's `library/<name>.py` lookup has). Empty when no root exists
    # - the overwhelmingly common case.
    def find_sources(role_path : String?, playbook_dir : String?) : Array(String)
      roots = [] of String
      roots << File.join(role_path, "filter_plugins") if role_path && !role_path.empty?
      roots.concat(loaded_role_roots("filter_plugins"))
      roots << File.join(playbook_dir, "filter_plugins") if playbook_dir && !playbook_dir.empty?

      sources = [] of String
      roots.each do |root|
        sources.concat(py_sources_in(root)) if Dir.exists?(root)
      end
      sources.uniq
    end

    # One retry for a wrapper-LEVEL failure (nil = python3 couldn't be
    # spawned at all - fork/exec hiccup, OOM kill of the short-lived
    # interpreter under a loaded controller - and ok:false = the wrapper
    # crashed): the introspection it wraps is the read-only "list"
    # action, so a retry is safe; the "call" action is never routed
    # through here, since a filter may have side effects. The result is
    # deliberately NOT cached by filter_names, so a still-failing lookup
    # is retried on the NEXT render instead of being trusted for the
    # rest of the run (issue #675).
    private def run_wrapper_retrying(payload) : JSON::Any?
      result = run_wrapper(payload)
      return result if result && result["ok"]?.try(&.as_bool?)
      sleep 0.05
      run_wrapper(payload)
    end

    # The CONTROLLER's own python3 - the interpreter Ansible needs
    # on the controller anyway (same detection pattern facts_gatherer
    # uses for its controller-side needs).
    def python_executable : String?
      Process.find_executable("python3") || Process.find_executable("python")
    end

    # Whether *name* is exposed by any of *sources*' FilterModule
    # classes. Results are cached per source file (keyed by path,
    # invalidated by mtime) - a `when:` clause's compile-time filter
    # pre-pass can ask this repeatedly for the same role.
    def defines_filter?(name : String, sources : Array(String)) : Bool
      filter_names(sources).includes?(name)
    end

    # The set of filter names exposed across *sources*. A source file
    # that fails to introspect (syntax error, no python3, a
    # `filters()` that raises) contributes no names - never raises. A
    # file whose import raises additionally gets Ansible's "Skipping
    # plugin" warning (Ansible prints one stderr line per unloadable
    # file and keeps loading the rest); it is emitted only on a cache
    # miss, i.e. once per file per process, matching Ansible's
    # once-per-load behaviour.
    #
    # Only a wrapper that actually ANSWERED ({"ok": true}) is cached:
    # a wrapper-level failure (python3 unspawnable, an ok:false crash)
    # used to be cached as this file's empty name set, permanently
    # turning every later lookup of its filters into "No filter named"
    # for the rest of the run - the compile-time filter validation and
    # the render's one-chance role-local retry consult this same cache,
    # so one transient spawn hiccup under a heavily loaded controller
    # failed the whole run (issue #675). An UNLOADABLE file (import
    # error) still caches as empty: that answer is final, and it keeps
    # the "Skipping plugin" warning once-per-process like Ansible's.
    def filter_names(sources : Array(String)) : Set(String)
      names = Set(String).new
      sources.each do |path|
        mtime = (File.info(path).modification_time.to_unix_ms rescue nil)
        next unless mtime

        if cached = @@names_cache[path]?
          if cached[0] == mtime
            cached[1].each { |cached_name| names << cached_name }
            next
          end
        end

        result = run_wrapper_retrying({
          "action" => "list",
          "paths"  => [path],
        })
        set = Set(String).new
        if result && result["ok"]?.try(&.as_bool?)
          result["names"]?.try(&.as_a?).try do |exposed|
            exposed.each { |exposed_name| set << exposed_name.to_s }
          end
          if skipped = result["skipped"]?.try(&.as_a?)
            skipped.each do |entry|
              error = entry["error"]?.try(&.as_s?) || "unknown error"
              emit_skip_warning(path, error)
            end
          end
          @@names_cache[path] = {mtime, set}
        end
        set.each { |set_name| names << set_name }
      end
      names
    end

    # Invokes filter *name* from *sources* with the Jinja operand
    # *value* and its resolved arguments, returning the structured
    # result. Raises FilterError when the filter is not found or the
    # invocation fails (callers degrade to the plain unknown-filter
    # error).
    def call_filter(name : String, sources : Array(String), value : JSON::Any,
                    args : Array(JSON::Any), kwargs : Hash(String, JSON::Any),
                    vars : Hash(String, JSON::Any)? = nil) : JSON::Any
      result = run_wrapper({
        "action" => "call",
        "paths"  => sources,
        "name"   => name,
        "value"  => value,
        "args"   => args,
        "kwargs" => kwargs,
        "vars"   => vars,
      })
      raise FilterError.new("filter plugin wrapper produced no result (is python3 available?)") unless result
      unless result["ok"]?.try(&.as_bool?)
        detail = result["error"]?.try(&.as_s?) || "unknown error"
        raise FilterError.new("custom filter '#{name}' failed: #{detail}")
      end
      result["result"]? || JSON::Any.new(nil)
    end

    @@names_cache = Hash(String, {Int64, Set(String)}).new

    # Where "Skipping plugin" warnings go - STDERR in production,
    # replaceable so a spec can capture the text without touching the
    # process's STDERR.
    class_property warning_sink : IO = STDERR

    # Same plain, uncolored style as the other `[WARNING]:` lines
    # (playbook_parser.cr); Ansible's wording has no trailing period and
    # the path is absolute.
    private def emit_skip_warning(path : String, error : String) : Nil
      warning_sink.puts "[WARNING]: Skipping plugin (#{File.expand_path(path)}), cannot load: #{error}"
    end

    # Runs the wrapper script below against one request. Returns the
    # parsed response JSON, or nil on ANY failure (no python3, nonzero
    # exit, unparseable output) - callers treat nil as "not available".
    private def run_wrapper(payload) : JSON::Any?
      python = python_executable
      return nil unless python

      stdout = IO::Memory.new
      stderr = IO::Memory.new
      status = Process.run(python, ["-c", WRAPPER],
        input: IO::Memory.new(payload.to_json),
        output: stdout, error: stderr)
      return nil unless status.success?

      parsed = (JSON.parse(stdout.to_s) rescue nil)
      return nil unless parsed && parsed.as_h?
      parsed
    rescue
      nil
    end

    # The controller-side wrapper: imports each plugin file, merges
    # every FilterModule class's `filters()` dict, then either reports
    # the merged names ("list") or invokes the requested filter with
    # the JSON-encoded operand and arguments ("call") and prints the
    # JSON-encoded result. A file that fails to import is reported in
    # the "skipped" list instead of failing the whole response - Ansible
    # keeps loading a directory's remaining plugin files and warns on
    # stderr for the one that failed, so the skip arrives as data on
    # stdout and the Crystal side turns it into that stderr line.
    # Always responds with a single-line JSON object
    # ({"ok": true, ...} / {"ok": false, kind, error}), so a plugin
    # that prints its own noise cannot corrupt the protocol - only the
    # LAST line of stdout is parsed.
    WRAPPER = <<-PYTHON
      import importlib.util
      import json
      import os
      import sys


      _loaded = []


      def _load_plugin(path):
          modname = "krikri_filter_%d" % len(_loaded)
          spec = importlib.util.spec_from_file_location(modname, path)
          if spec is None or spec.loader is None:
              raise ImportError("cannot load filter plugin: %s" % path)
          module = importlib.util.module_from_spec(spec)
          spec.loader.exec_module(module)
          _loaded.append(module)
          return module


      def _is_pass_context(func):
          # jinja2 >= 3.0's @pass_context sets `jinja_pass_arg` to a
          # _PassArg enum member; its `.name` is "context" only for
          # pass_context (pass_environment/pass_eval_context share the
          # attribute but need different first args, so they are NOT
          # matched here). jinja2 < 3.0's @contextfilter set the plain
          # boolean `contextfilter` marker instead. No jinja2 import is
          # needed for either check, so the wrapper works regardless of
          # which jinja2 (if any) the controller has - only the plugin
          # file itself needs jinja2 for its decorator.
          arg = getattr(func, "jinja_pass_arg", None)
          if arg is not None and getattr(arg, "name", None) == "context":
              return True
          return bool(getattr(func, "contextfilter", False))


      class _StubContext(object):
          # Minimal stand-in for jinja2.runtime.Context: covers the
          # variable-lookup patterns custom filters actually use
          # (context.get / context.resolve / context['name'] /
          # context.vars / context.get_all) over the play vars snapshot
          # krikri passes in. Filters reaching for environment machinery
          # beyond this (context.environment, caching, live hostvars)
          # are outside what a JSON-marshaled subprocess can offer.
          def __init__(self, variables):
              self.vars = variables
              self.parent = variables
              self.environment = None

          def resolve(self, name, default=None):
              return self.vars.get(name, default)

          def get(self, key, default=None):
              return self.vars.get(key, default)

          def get_all(self):
              return self.vars

          def __getitem__(self, key):
              return self.vars[key]

          def __contains__(self, key):
              return key in self.vars


      def _plugin_filters(path):
          module = _load_plugin(path)
          plugin_dir = os.path.dirname(os.path.abspath(path))
          if plugin_dir not in sys.path:
              sys.path.insert(0, plugin_dir)
          plugin_class = getattr(module, "FilterModule", None)
          if plugin_class is None:
              return {}
          # Ansible's own PluginLoader instantiates the plugin
          # class before calling filters() on the instance - a
          # filters() defined as a plain instance method (the common
          # spelling) fails with "missing self" when called on the
          # class directly.
          filters = plugin_class().filters()
          if not isinstance(filters, dict):
              return {}
          return filters


      def _serialize(value):
          if isinstance(value, (set, frozenset)):
              return list(value)
          if isinstance(value, bytes):
              return value.decode("utf-8", "replace")
          return str(value)


      def _load_all(paths):
          # Ansible's PluginLoader warns about a plugin file that fails
          # to import and keeps loading the rest, so one broken file
          # must not take down its siblings' filters.
          names = {}
          skipped = []
          for path in paths:
              try:
                  names.update(_plugin_filters(path))
              except Exception as exc:
                  skipped.append({"path": path, "error": str(exc)})
          return names, skipped


      def main():
          payload = json.loads(sys.stdin.read())
          names, skipped = _load_all(payload.get("paths", []))
          if payload.get("action") == "list":
              sys.stdout.write(json.dumps(
                  {"ok": True, "names": sorted(names), "skipped": skipped}))
              return
          name = payload.get("name")
          func = names.get(name)
          if func is None:
              sys.stdout.write(json.dumps(
                  {"ok": False, "kind": "not_found",
                   "error": "no filter named %s in the given plugin files" % name}))
              return
          if _is_pass_context(func):
              call_args = [_StubContext(payload.get("vars") or {})]
          else:
              call_args = []
          call_args.append(payload.get("value"))
          call_args.extend(payload.get("args") or [])
          result = func(*call_args, **(payload.get("kwargs") or {}))
          sys.stdout.write(json.dumps({"ok": True, "result": result}, default=_serialize))


      try:
          main()
      except Exception as exc:
          sys.stdout.write(json.dumps(
              {"ok": False, "kind": "error",
               "error": "%s: %s" % (type(exc).__name__, exc)}))
      PYTHON
  end
end
