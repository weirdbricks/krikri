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
          else
            STDERR.puts "krikri-lint: target not found: #{target}"
            exit 2
          end
        end
        files.uniq!
        files.sort!
      end

      private def search_dir(dir : String) : Array(String)
        found = [] of String
        Dir.each_child(dir) do |child|
          full = File.join(dir, child)
          if File.directory?(full)
            next if SKIP_DIRS.includes?(child)
            found.concat(search_dir(full))
          elsif EXTENSIONS.includes?(File.extname(child))
            found << full
          end
        end
        found
      end
    end
  end
end
