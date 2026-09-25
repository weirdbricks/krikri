require "json"
require "krikri_jinja"

module Krikri
  # Controller-side state handed to the krikri-jinja registrations that need
  # Krikri's own variable scope, which the engine cannot know about on its
  # own. Passed through the shard's host-context hook so a registration can
  # resolve `{{ some_registered_var is failed }}`-style tests (and lookups)
  # against the same scope the rest of the engine uses.
  class JinjaHostContext < KrikriJinja::HostContext
    getter vars : Hash(String, JSON::Any)

    def initialize(@vars : Hash(String, JSON::Any))
    end

    # The registered result named by a test's first argument, or nil when the
    # name is missing or does not hold a module result.
    def registered(name : String) : JSON::Any?
      entry = @vars[name]?
      return nil unless entry
      if hash = entry.as_h?
        JSON::Any.new(hash)
      else
        entry
      end
    end
  end
end
