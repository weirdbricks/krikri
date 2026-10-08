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
    fun ioctl(fd : Int, request : ULong, arg : ULong) : Int
  end
{% end %}

require "./oneline_output"

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
      # The oneline stdout callback replaces the default callback's whole
      # output surface - banners included (no PLAY/TASK/PLAY RECAP lines
      # at all, live-verified). The profile_tasks TASKS RECAP banner is
      # NOT routed through here (it must survive oneline), so nothing
      # else needs an exception.
      return if Krikri::Oneline.enabled?
      puts ""
      puts "#{msg} #{stars(msg)}"
    end

    def self.stars(msg : String) : String
      star_len = Math.max(3, columns - display_width(msg))
      "*" * star_len
    end

    # Ansible pads banners by DISPLAY width, not codepoint count - its
    # `_textlen` treats each East Asian Wide/Fullwidth character as two
    # columns (live-verified vs 2.19.11: `TASK [Téλ-日本 ...]` pads two
    # stars shorter than a codepoint count would give). Mirrors
    # unicodedata.east_asian_width(c) in ("W", "F") for the ranges that
    # matter; every other character counts one column.
    def self.display_width(msg : String) : Int32
      width = 0
      msg.each_char do |char|
        cp = char.ord
        width += WIDE_RANGES.any? { |range| range.includes?(cp) } ? 2 : 1
      end
      width
    end

    private WIDE_RANGES = [
      0x1100..0x115F, 0x231A..0x231B, 0x2329..0x232A, 0x23E9..0x23EC,
      0x23F0..0x23F0, 0x23F3..0x23F3, 0x25FD..0x25FE, 0x2614..0x2615,
      0x2648..0x2653, 0x267F..0x267F, 0x2693..0x2693, 0x26A1..0x26A1,
      0x26AA..0x26AB, 0x26BD..0x26BE, 0x26C4..0x26C5, 0x26CE..0x26CE,
      0x26D4..0x26D4, 0x26EA..0x26EA, 0x26F2..0x26F3, 0x26F5..0x26F5,
      0x26FA..0x26FA, 0x26FD..0x26FD, 0x2705..0x2705, 0x270A..0x270B,
      0x2728..0x2728, 0x274C..0x274C, 0x274E..0x274E, 0x2753..0x2755,
      0x2757..0x2757, 0x2795..0x2797, 0x27B0..0x27B0, 0x27BF..0x27BF,
      0x2B1B..0x2B1C, 0x2B50..0x2B50, 0x2B55..0x2B55, 0x2E80..0x303E,
      0x3041..0x33FF, 0x3400..0x4DBF, 0x4E00..0xA4CF, 0xA960..0xA97F,
      0xAC00..0xD7A3, 0xF900..0xFAFF, 0xFE10..0xFE19, 0xFE30..0xFE6F,
      0xFF00..0xFF60, 0xFF62..0xFFA0, 0x16FE0..0x16FE4, 0x17000..0x18AFF,
      0x1B000..0x1B152, 0x1F004..0x1F004, 0x1F0CF..0x1F0CF,
      0x1F18E..0x1F18E, 0x1F191..0x1F19A, 0x1F200..0x1F320,
      0x1F32D..0x1F335, 0x1F337..0x1F37C, 0x1F37E..0x1F393,
      0x1F3A0..0x1F3CA, 0x1F3CF..0x1F3D3, 0x1F3E0..0x1F3F0,
      0x1F3F4..0x1F3F4, 0x1F3F8..0x1F43E, 0x1F440..0x1F440,
      0x1F442..0x1F4FC, 0x1F4FF..0x1F53D, 0x1F54B..0x1F54E,
      0x1F550..0x1F567, 0x1F57A..0x1F57A, 0x1F595..0x1F596,
      0x1F5A4..0x1F5A4, 0x1F5FB..0x1F64F, 0x1F680..0x1F6C5,
      0x1F6CC..0x1F6CC, 0x1F6D0..0x1F6D2, 0x1F6D5..0x1F6D7,
      0x1F6EB..0x1F6EC, 0x1F6F4..0x1F6FC, 0x1F7E0..0x1F7EB,
      0x1F90C..0x1F93A, 0x1F93C..0x1F945, 0x1F947..0x1F9FF,
      0x1FA70..0x1FAFF, 0x20000..0x2FFFD, 0x30000..0x3FFFD,
    ]

    # Ansible's `max(79, tty_size - 1)`: a tty reports its ioctl width; any
    # non-tty stdout (pipe, file) reports 0 and lands on the 79 floor.
    def self.columns : Int32
      return 79 unless STDOUT.tty?

      {% if flag?(:linux) || flag?(:darwin) %}
        ws = uninitialized LibCExt::Winsize
        rc = LibC.ioctl(1, TIOCGWINSZ, pointerof(ws).address)
        if rc == 0 && ws.ws_col != 0
          return Math.max(79, ws.ws_col.to_i - 1)
        end
      {% end %}
      79
    end
  end
end
