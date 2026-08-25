require "json"
require "./playbook_parser"

module CrystalPlay
  # `vars_prompt:` - questions asked once, before the play runs, whose
  # answers become play variables.
  #
  # Real Ansible only actually PROMPTS on a terminal. With stdin piped or
  # closed it does not read the input at all: it falls back to the
  # entry's `default:`, or to None when there is none (verified against
  # ansible-core 2.19.4 - piping "bob" to a prompt with
  # `default: admin` still yields admin). That is what makes the keyword
  # safe in automation, and it is reproduced here.
  module VarsPrompt
    # Resolves *prompts* into variables, asking on a TTY and falling back
    # to defaults otherwise.
    def self.resolve(prompts : Array(Hash(String, String))) : Hash(String, JSON::Any)
      answers = Hash(String, JSON::Any).new
      return answers if prompts.empty?

      interactive = STDIN.tty?

      prompts.each do |entry|
        name = entry["name"]?
        next unless name

        default = entry["default"]?
        answer =
          if interactive
            ask(entry, default)
          else
            default
          end

        # With no answer and no default, real Ansible leaves the variable
        # as the literal STRING "None" - not a null. Verified against
        # ansible-core 2.19.4: `{{ x | type_debug }}` reports `str` and
        # `x is none` is False, i.e. Python's str(None) has leaked into
        # the value. Quirk or not, that is the observable behavior, and
        # a null here would render as empty instead.
        answers[name] = JSON::Any.new(answer || "None")
      end

      answers
    end

    private def self.ask(entry : Hash(String, String), default : String?) : String?
      label = entry["prompt"]? || entry["name"]
      suffix = default ? " [#{default}]" : ""
      print "#{label}#{suffix}: "

      # private: defaults to TRUE in real Ansible - a vars_prompt is
      # assumed to be a secret unless it says otherwise.
      hidden = (entry["private"]? || "true").downcase
      typed =
        if ["false", "no", "0"].includes?(hidden)
          STDIN.gets.try(&.chomp)
        else
          read_hidden
        end

      typed.nil? || typed.empty? ? default : typed
    end

    # Reads without echoing, restoring the terminal afterwards. Falls
    # back to a plain read if `stty` is unavailable.
    private def self.read_hidden : String?
      unless Process.run("stty", ["-echo"], input: Process::Redirect::Inherit,
               output: Process::Redirect::Close, error: Process::Redirect::Close).success?
        return STDIN.gets.try(&.chomp)
      end

      begin
        STDIN.gets.try(&.chomp)
      ensure
        Process.run("stty", ["echo"], input: Process::Redirect::Inherit,
          output: Process::Redirect::Close, error: Process::Redirect::Close)
        puts ""
      end
    end
  end
end
