{% if flag?(:linux) || flag?(:darwin) %}
  lib LibCExt
    struct Winsize
      ws_row : UInt16
      ws_col : UInt16
      ws_xpixel : UInt16
      ws_ypixel : UInt16
    end
  end

  # Same signature as every other ioctl binding in this tree
  # (plugins/expect.cr, plugin_helpers/controlling_tty.cr) - fun
  # declarations unify by C symbol name, so the signatures must match
  # exactly inside one compilation unit.
  lib LibC
    fun ioctl(fd : Int, request : ULong, arg : Int) : Int
  end
{% end %}

module Krikri
  # ansible-playbook's `Display.banner` shape: a blank line, then
  # `<msg> ` followed by `*` padding out to the display width (79 when
  # stdout is not a tty, `tty_width - 1` when it is, minimum 3 stars).
  # Banners are never colorized, even on a tty (Ansible's default callback
  # passes no color to banner).
  module OutputBanner
    {% if flag?(:linux) %}
      TIOCGWINSZ = 0x5413u64
    {% elsif flag?(:darwin) %}
      TIOCGWINSZ = 0x40087468u64
    {% else %}
      TIOCGWINSZ = 0u64
    {% end %}

    def self.banner(msg : String) : Nil
      puts ""
      puts "#{msg} #{stars(msg)}"
    end

    def self.stars(msg : String) : String
      star_len = Math.max(3, columns - msg.size)
      "*" * star_len
    end

    # Ansible's `max(79, tty_size - 1)`: a tty reports its ioctl width; any
    # non-tty stdout (pipe, file) reports 0 and lands on the 79 floor.
    def self.columns : Int32
      return 79 unless STDOUT.tty?

      {% if flag?(:linux) || flag?(:darwin) %}
        ws = uninitialized LibCExt::Winsize
        rc = LibC.ioctl(1, TIOCGWINSZ, pointerof(ws).address.to_i)
        if rc == 0 && ws.ws_col != 0
          return Math.max(79, ws.ws_col.to_i - 1)
        end
      {% end %}
      79
    end
  end
end
