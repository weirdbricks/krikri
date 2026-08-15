module CrystalPlay
  module PluginHelpers
    # FindModeFilter - pure logic for find:'s mode:/exact_mode: filter.
    # Verified against real ansible/modules/find.py's own `mode_filter`
    # source directly, not assumed from ansible-doc's prose:
    #
    #   try:
    #       mode = int(mode, 8)
    #   except ValueError:
    #       mode = module._symbolic_mode_to_octal(_Object(st_mode=0), mode)
    #   mode = stat.S_IMODE(mode)
    #   if exact:
    #       return st_mode == mode
    #   return bool(st_mode & mode)
    #
    # Two things worth calling out since they're easy to get wrong by
    # going from the docs' prose instead of the source: (1) the
    # non-exact ("minimum set") case is a bitwise AND-is-nonzero test,
    # true the moment ANY requested bit is present in the file's actual
    # mode - not "every requested bit is present" the way "minimum set
    # to match" reads in English; (2) symbolic mode is resolved against
    # a st_mode of 0 (an all-zero base), so `u=rw,g=r,o=r` is a pure
    # absolute assignment, not relative to the file's own existing mode.
    #
    # Only the `=` (absolute assignment) operator and `ugo` targets with
    # `rwx` permission letters are implemented for the symbolic form -
    # real Ansible's fuller grammar (`+`/`-` relative operators, `X`
    # conditional-execute, `s`/`t` setuid/setgid/sticky, umask-relative
    # empty-target clauses) is NOT - octal is the overwhelmingly common
    # real-world form for a find: filter (ansible-doc's own only example
    # of the symbolic form is exactly the `u=rw,g=r,o=r` shape this
    # covers), and the fuller chmod(1) symbolic grammar is real
    # complexity better scoped for the file: plugin's own OWNERSHIP-
    # setting use case, not a read-only search filter.
    module FindModeFilter
      def self.matches?(actual_octal_mode : Int32, wanted : String, exact : Bool) : Bool
        wanted_octal = parse_mode(wanted)
        return false unless wanted_octal

        exact ? actual_octal_mode == wanted_octal : (actual_octal_mode & wanted_octal) != 0
      end

      # Returns the 12-bit (S_IMODE) octal value of *mode_str*, or nil if
      # it's neither valid octal nor a supported `u=`/`g=`/`o=`/`a=`
      # symbolic assignment.
      def self.parse_mode(mode_str : String) : Int32?
        return mode_str.to_i(8) if mode_str =~ /\A[0-7]+\z/

        parse_symbolic(mode_str)
      end

      private def self.parse_symbolic(mode_str : String) : Int32?
        result = 0
        mode_str.split(',').each do |clause|
          match = clause.match(/\A([ugoa]*)=([rwx]*)\z/)
          return nil unless match

          targets = match[1].empty? ? "ugo" : match[1]
          targets = "ugo" if targets == "a"
          perm_bits = 0
          perm_bits |= 0o4 if match[2].includes?('r')
          perm_bits |= 0o2 if match[2].includes?('w')
          perm_bits |= 0o1 if match[2].includes?('x')

          targets.each_char do |target|
            shift = case target
                    when 'u' then 6
                    when 'g' then 3
                    else          0
                    end
            result |= perm_bits << shift
          end
        end
        result
      end
    end
  end
end
