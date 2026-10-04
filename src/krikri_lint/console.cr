module Krikri
  module Lint
    # Byte-level mirror of upstream's ansiblelint/output.py console: the
    # same ANSI constants, the same OSC 8 hyperlink shape, and the same
    # "colored or plain" switch, so krikri-lint's output can be compared
    # byte for byte with ansible-lint's.
    module Console
      RESET   = "\e[0m"
      BOLD    = "\e[1m"
      DIM     = "\e[2m"
      RED     = "\e[31m"
      GREEN   = "\e[32m"
      YELLOW  = "\e[33m"
      BLUE    = "\e[34m"
      MAGENTA = "\e[35m"

      # OSC 8 ; params ; URI ST label OSC 8 ;; ST
      private def self.osc(uri : String, label : String) : String
        "\e]8;;#{uri}\e\\#{label}\e]8;;\e\\"
      end

      # Hyperlink with a blue label, as upstream's AnsiStyle.render_link.
      def self.link(url : String, label : String) : String
        BLUE + osc(url, label) + RESET
      end

      # Upstream's plain theme drops the escape codes and keeps the
      # label only.
      def self.link(url : String, label : String, colored : Bool) : String
        colored ? link(url, label) : label
      end

      # Upstream's should_do_markup(): explicit environment first, then
      # TERM heuristics, then isatty as the last resort.
      def self.color_enabled?(force : Bool = false, disabled : Bool = false,
                              stream : IO = STDOUT) : Bool
        return false if disabled
        return false if ENV["NO_COLOR"]? && !ENV["NO_COLOR"].empty?

        forced = {"PY_COLORS", "CLICOLOR", "FORCE_COLOR", "ANSIBLE_FORCE_COLOR"}
          .each do |name|
            value = ENV[name]?
            break to_bool(value) unless value.nil?
          end
        return forced unless forced.nil?
        return true if force

        term = ENV["TERM"]? || ""
        return true if term.includes?("xterm")
        return false if term == "dumb"
        stream.tty?
      end

      private def self.to_bool(value : String) : Bool
        {"yes", "on", "1", "true"}.includes?(value.downcase)
      end
    end
  end
end
