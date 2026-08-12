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
    else
      nil
    end
  end
end
