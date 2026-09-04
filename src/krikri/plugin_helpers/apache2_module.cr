module Krikri
  module PluginHelpers
    # Apache2Module - pure logic shared by the apache2_module plugin,
    # unit-testable without I/O.
    module Apache2Module
      # Mirrors real community.general.apache2_module's
      # create_apache_identifier: by convention an a2enmod name shows up
      # in `apache2ctl -M` output as "<name>_module", but a few modules
      # don't follow it. Order matters (text workarounds all run before
      # the regex ones, and "shib" precedes "shib2", so "shib2" maps to
      # mod_shib too).
      def self.create_identifier(name : String) : String
        # a2enmod name replacement to apache2ctl -M names
        return "mod_shib" if name.includes?("shib") || name.includes?("shib2")
        return "evasive20_module" if name.includes?("evasive")

        if name.includes?("php8")
          if match = name.match(/^(php)[\d\.]+/)
            return "#{match[1]}_module"
          end
        end

        if name.includes?("php")
          if match = name.match(/^(php\d)\./)
            return "#{match[1]}_module"
          end
        end

        "#{name}_module"
      end
    end
  end
end
