require "crinja"

# Real Jinja2 (via Python's `str()`) renders a bare boolean as "True"/
# "False" (capitalized) - Crinja's own Finalizer (lib/crinja/src/
# runtime/finalizer.cr) has no Bool-specific stringify overload, so it
# fell through to the generic `raw.to_s(@io)` case, which is Crystal's
# own lowercase Bool#to_s ("true"/"false"). Found via geerlingguy.
# supervisor's own supervisord.conf.j2: `nodaemon = {{
# supervisor_nodaemon }}` (default `false`) rendered "nodaemon = false"
# instead of real Ansible's own "nodaemon = False" - reopening
# Crinja::Finalizer (the sanctioned way to extend vendored Crinja
# behavior in this codebase - see crinja_hash_ext.cr's own doc comment)
# rather than editing the vendored lib/crinja file directly.
struct Crinja::Finalizer
  protected def stringify(raw : Bool)
    @io << (raw ? "True" : "False")
  end
end
