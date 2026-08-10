require "crinja"

# Real Jinja2 dicts support the Python dict methods .keys()/.values()/
# .items() (linux-system-roles/kernel_settings' own kernel_settings.j2
# macro: `{% for key in settings.keys() | sort %}`) - Crinja's method
# dispatch (Resolver#resolve_getattr/resolve_method, see lib/crinja/src/
# runtime/resolver.cr) only calls through to crinja_attribute/crinja_call
# for types that implement them (lib/crinja/src/object.cr's
# Crinja::Object::Auto pattern); a plain Hash doesn't, so `.keys()`
# resolved as "settings.keys is undefined" instead of ever running.
# Reopening Hash (rather than a wrapper type) covers every Hash-valued
# template variable crystal-play ever hands to Crinja in one place -
# crinja_renderer.cr always converts a JSON object into a real
# Hash(String, Crinja::Value), so this activates for every dict any
# template renders, not just this one role's.
class Hash(K, V)
  def crinja_call(method : String) : Crinja::Callable::Proc?
    case method
    when "keys"
      ->(_arguments : Crinja::Arguments) { Crinja::Value.new(self.keys.map { |key| Crinja::Value.new(key) }) }
    when "values"
      ->(_arguments : Crinja::Arguments) { Crinja::Value.new(self.values.map { |value| Crinja::Value.new(value) }) }
    when "items"
      ->(_arguments : Crinja::Arguments) do
        Crinja::Value.new(self.map { |key, value| Crinja::Value.new([Crinja::Value.new(key), Crinja::Value.new(value)]) })
      end
    else
      nil
    end
  end
end
