module CrystalPlay
  module PluginHelpers
    # ArchivePaths - pure logic for the `archive` plugin's arcroot
    # calculation. No I/O here - the plugin itself resolves which paths
    # actually exist.
    module ArchivePaths
      # dirname(commonprefix([dirname(p) + "/" for p in paths])) + "/" -
      # matches real Ansible's (community.general) archive module's
      # common_path() exactly, verified against real ansible-playbook's
      # actual `arcroot` output for single-file, single-directory, and
      # multi-path cases.
      def self.common_path(paths : Array(String)) : String
        dirs_with_slash = paths.map { |path| File.dirname(path) + "/" }
        prefix = string_common_prefix(dirs_with_slash)
        python_dirname(prefix) + "/"
      end

      def self.string_common_prefix(strings : Array(String)) : String
        return "" if strings.empty?
        return strings[0] if strings.size == 1

        sorted = strings.sort
        min, max = sorted.first, sorted.last
        i = 0
        while i < min.size && min[i] == max[i]
          i += 1
        end
        min[0, i]
      end

      # Python's os.path.dirname strips only the trailing slash from a
      # path already ending in "/" (returning everything before it),
      # unlike Crystal's File.dirname, which treats a trailing slash as
      # insignificant and returns the level ABOVE it - a real, verified
      # divergence that broke arcroot calculation until caught by
      # comparing actual output against real ansible-playbook.
      def self.python_dirname(path : String) : String
        idx = path.rindex('/')
        return "" unless idx
        return "/" if idx == 0
        path[0, idx]
      end
    end
  end
end
