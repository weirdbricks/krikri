require "json"

module Krikri
  module PluginHelpers
    # Homebrew - pure logic for the homebrew plugin: package-name
    # validation, `brew info --json=v2` parsing (installed/outdated sets
    # with the real module's name-matching rules), and brew command
    # construction. Split out of plugins/homebrew.cr so this logic is
    # unit-spec-able (execution needs a real macOS/Linuxbrew host, which
    # no spec environment has).
    module Homebrew
      # The real module's HomebrewValidate.valid_package: a package name
      # is a formula name (optionally tap-prefixed, e.g. homebrew/cask/foo).
      def self.valid_package?(package : String) : Bool
        /^[A-Za-z0-9_][A-Za-z0-9_+@.\/-]*$/.matches?(package) ||
          /^[A-Za-z0-9_][A-Za-z0-9_+@.\/-]*\/[A-Za-z0-9_+@.\/-]*$/.matches?(package)
      end

      # brew info --json=v2 output -> per-requested-name {installed,
      # outdated} map, mirroring the real module's _get_packages_info:
      # a formula is installed when its `installed` array is non-empty,
      # outdated when its `outdated` flag is set. The user-supplied name
      # is matched against name/full_name/aliases/oldnames (plus the
      # tap-prefixed spellings) like the real _extract_package_name.
      def self.parse_info(json_output : String, packages : Array(String)) : Hash(String, NamedTuple(installed: Bool, outdated: Bool))?
        data = JSON.parse(json_output) rescue nil
        return nil unless data && data.as_h?

        result = {} of String => NamedTuple(installed: Bool, outdated: Bool)
        packages.each { |pkg| result[pkg] = {installed: false, outdated: false} }

        %w[formulae casks].each do |kind|
          next unless (entries = data[kind]?) && entries.as_a?
          entries.as_a.each do |entry|
            next unless entry.as_h?
            names = candidate_names(entry)
            packages.each do |pkg|
              next unless names.includes?(pkg)
              installed = (entry["installed"]?.try(&.as_a?.try(&.size)) || 0) > 0
              outdated = entry["outdated"]?.try(&.as_bool?) || false
              result[pkg] = {installed: installed, outdated: outdated}
            end
          end
        end
        result
      end

      private def self.candidate_names(entry : JSON::Any) : Set(String)
        names = Set(String).new
        {% for key in ["name", "full_name", "token"] %}
          if value = entry[{{ key }}]?
            names << value.as_s if value.as_s?
          end
        {% end %}
        {% for key in ["aliases", "oldnames"] %}
          if list = entry[{{ key }}]?
            list.as_a?.try(&.each { |item| names << item.as_s if item.as_s? })
          end
        {% end %}
        tap = entry["tap"]?.try(&.as_s?)
        unless tap.nil? || tap.empty?
          names.each { |n| names << "#{tap}/#{n}" }
        end
        names
      end

      def self.info_command(brew_path : String, packages : Array(String)) : String
        "#{brew_path} info --json=v2 #{packages.join(" ")}"
      end

      def self.install_command(brew_path : String, packages : Array(String), install_options : Array(String), head : Bool, force_formula : Bool) : String
        cmd = [brew_path, "install"]
        cmd += install_options.map { |opt| opt.starts_with?("--") ? opt : "--#{opt}" }
        cmd += packages
        cmd << "--HEAD" if head
        cmd << "--formula" if force_formula
        cmd.join(" ")
      end

      def self.upgrade_command(brew_path : String, packages : Array(String), install_options : Array(String)) : String
        ([brew_path, "upgrade"] + install_options.map { |opt| opt.starts_with?("--") ? opt : "--#{opt}" } + packages).join(" ")
      end

      def self.uninstall_command(brew_path : String, packages : Array(String), install_options : Array(String)) : String
        ([brew_path, "uninstall", "--force"] + install_options.map { |opt| opt.starts_with?("--") ? opt : "--#{opt}" } + packages).join(" ")
      end

      def self.link_command(brew_path : String, packages : Array(String), install_options : Array(String), unlink : Bool) : String
        ([brew_path, unlink ? "unlink" : "link"] + install_options.map { |opt| opt.starts_with?("--") ? opt : "--#{opt}" } + packages).join(" ")
      end

      def self.update_changed?(update_output : String) : Bool
        !update_output.split("\n").any? { |line| line.strip.downcase =~ /already up-to-date/ }
      end
    end
  end
end
