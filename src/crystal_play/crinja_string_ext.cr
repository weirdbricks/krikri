require "crinja"

# Real Jinja2/Python exposes str.split(...) as a plain method call
# (`solr_version.split('.')[0] < '9'`, geerlingguy.solr's own
# solr_default_core_path default) - Crinja's method dispatch (Resolver#
# resolve_getattr/resolve_method, see lib/crinja/src/runtime/resolver.cr)
# only calls through to crinja_call for types that implement it
# (lib/crinja/src/object.cr's Crinja::Object::Auto pattern); a plain
# Crystal String doesn't, so `.split(...)` resolved as "split is
# undefined" (Crinja::TypeError) instead of ever running.
#
# That TypeError doesn't just break the one expression: CrinjaRenderer
# #render's own blanket `rescue` catches ANY exception from a render
# attempt and falls back to returning the ENTIRE original template
# text unrendered - so the whole `{% if %}...{% endif %}` block's raw
# Jinja source leaked straight into the "rendered" value, corrupting
# every task param built from it (get_url found the same "whole
# template silently didn't render" failure mode independently, over a
# missing filter rather than a missing method).
#
# Reopening String (rather than a wrapper type) covers every String-
# valued template variable crystal-play ever hands to Crinja in one
# place, matching crinja_hash_ext.cr's own .keys()/.values()/.items()
# precedent for Hash.
class String
  def crinja_call(method : String) : Crinja::Callable::Proc?
    case method
    when "split"
      ->(arguments : Crinja::Arguments) do
        sep = arguments.varargs[0]?.try(&.raw.try(&.to_s))
        parts = sep.nil? || sep.empty? ? self.split : self.split(sep)
        Crinja::Value.new(parts.map { |part| Crinja::Value.new(part) })
      end
    when "startswith"
      # Real Python `str.startswith(prefix)` as a plain method call -
      # found (alongside this same missing-method failure mode as
      # `.split` above) via prometheus.prometheus._common's own
      # node_exporter.service.j2: `{% for m in ansible_facts['mounts']
      # if m.mount.startswith('/home') %}` (the `namespace()` template,
      # see crinja_namespace_ext.cr) - real Ansible authors reach for
      # Python string methods directly rather than Jinja2 filters
      # fairly often, same as `.split`/`.join` elsewhere in this file's
      # sibling patches.
      ->(arguments : Crinja::Arguments) do
        prefix = arguments.varargs[0]?.try(&.raw.try(&.to_s)) || ""
        Crinja::Value.new(self.starts_with?(prefix))
      end
    when "join"
      # Real Python `str.join(iterable)` as a plain method call - the
      # SEPARATOR is the receiver (`' '.join(['a','b'])` -> `"a b"`),
      # reverse argument order from Jinja2's own `| join(sep)` FILTER.
      # Found chained with `.split()` (`' '.join(deps).split()`,
      # Oefenweb.fail2ban's own per-element list rendering) - `.join`
      # itself was never implemented as a method call at all (only the
      # filter form was), so the whole chain failed before `.split()`
      # ever got a chance to run.
      ->(arguments : Crinja::Arguments) do
        iterable = arguments.varargs[0]? || Crinja::Value.new([] of Crinja::Value)
        Crinja::Value.new(iterable.each.map(&.to_s).to_a.join(self))
      end
    when "endswith"
      # Same as `startswith` above, the natural pair - not found in a
      # real template yet, added alongside for completeness rather than
      # waiting for a second live symptom of the identical gap.
      ->(arguments : Crinja::Arguments) do
        suffix = arguments.varargs[0]?.try(&.raw.try(&.to_s)) || ""
        Crinja::Value.new(self.ends_with?(suffix))
      end
    else
      nil
    end
  end
end
