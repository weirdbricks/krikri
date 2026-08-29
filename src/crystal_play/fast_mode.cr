module CrystalPlay
  # The `crystal-ansible-fast` binary.
  #
  # `OPUS_PERFORMANCE_IMPROVEMENTS.md`'s Tier 2 is the set of
  # optimizations that genuinely change what a playbook observes. Tier 1
  # is all parity-preserving and ships on by default; Tier 2 must not,
  # because "faster but sometimes wrong" is not what this project is
  # for - the whole point is behaving like `ansible-playbook`.
  #
  # These live behind a separate COMMAND NAME rather than a flag. The
  # binary is one build hardlinked to two names (exactly the trick
  # `build.sh`'s `build_fat_plugin` already uses for the 94 module names
  # on the fat plugin binary), and it decides from `PROGRAM_NAME` which
  # it was invoked as:
  #
  #   crystal-ansible        parity. Tier 2 off. The default everywhere.
  #   crystal-ansible-fast   Tier 2 on, all of it, with a banner.
  #
  # A name rather than a flag because the separation people actually
  # want is "this must never happen on a normal run" - a name cannot be
  # switched on by a stray flag inherited from a wrapper script or a CI
  # variable, and it is visible in `ps` and in shell history.
  #
  # All-or-nothing rather than one toggle per item, deliberately: four
  # independent toggles is sixteen combinations, and the benchmark
  # rounds would validate none of them. One extra mode is one extra
  # thing to test.
  module FastMode
    BINARY_NAME = "crystal-ansible-fast"

    @@enabled : Bool? = nil

    # True when this process was invoked through the fast hardlink.
    def self.enabled? : Bool
      cached = @@enabled
      return cached unless cached.nil?
      @@enabled = File.basename(PROGRAM_NAME) == BINARY_NAME
    end

    # Spec seam - there is no supported way to turn this on at runtime,
    # which is the point.
    def self.enabled=(value : Bool)
      @@enabled = value
    end

    # Printed once at startup so nobody is left wondering why a recap
    # differs from what real ansible-playbook would produce. Deliberately
    # loud, and it names the specific behaviours rather than saying
    # "fast mode" and leaving the reader to guess.
    def self.banner : String
      String.build do |io|
        io << "crystal-ansible-fast: parity-BREAKING optimizations are ENABLED.\n"
        io << "  - facts: only the families this play textually references are gathered\n"
        io << "    (a fact reached via a computed name, hostvars, or a .j2 file this\n"
        io << "     scan cannot see will be UNDEFINED rather than slow)\n"
        io << "  Use `crystal-ansible` for behaviour matching ansible-playbook.\n"
      end
    end
  end
end
