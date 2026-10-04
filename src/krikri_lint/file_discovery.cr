module Krikri
  module Lint
    module FileDiscovery
      EXTENSIONS = %w[.yml .yaml]
      SKIP_DIRS  = %w[.git .hg .svn node_modules files templates library module_defaults]

      extend self

      # Given user-supplied targets (files or directories), return the list
      # of YAML files to lint. A file target is kept as-is; a directory is
      # searched recursively for *.yml/*.yaml, skipping VCS and non-lintable
      # role directories (files/templates hold no YAML lint targets).
      def discover(targets : Array(String)) : Array(String)
        files = [] of String
        targets.each do |target|
          if File.directory?(target)
            files.concat(search_dir(target))
          elsif File.file?(target)
            files << target
          end
        end
        files.uniq!
        files.sort!
      end

      # Targets that were directories rather than files. Upstream keeps a
      # walked directory in its lintable set (with no kind, so no rules
      # run on it), which makes it count towards the "on N files" total.
      def directory_targets(targets : Array(String)) : Array(String)
        targets.select { |target| File.directory?(target) }
      end

      # Targets that are neither files nor directories. Upstream lints
      # these instead of erroring: each yields load-failure matches.
      def missing_targets(targets : Array(String)) : Array(String)
        targets.reject { |target| File.file?(target) || File.directory?(target) }
      end

      # Upstream classifies files under roles/<name>/ by the role's
      # well-known subdirectories; anything else inside a role (scripts
      # dirs, distribution data, etc.) is not a lintable lintable.
      private def lintable_role_file?(path : String) : Bool
        parts = path.split('/')
        roles_idx = parts.index("roles") || return true
        role_and_rest = parts[roles_idx + 2..]
        return true if role_and_rest.nil? || role_and_rest.empty?
        %w[tasks handlers defaults vars meta].includes?(role_and_rest.first)
      end

      private def search_dir(dir : String) : Array(String)
        found = [] of String
        Dir.each_child(dir) do |child|
          full = File.join(dir, child)
          if File.directory?(full)
            next if SKIP_DIRS.includes?(child)
            found.concat(search_dir(full))
          elsif EXTENSIONS.includes?(File.extname(child)) &&
                lintable_role_file?(full)
            found << full
          end
        end
        found
      end
    end
  end
end
