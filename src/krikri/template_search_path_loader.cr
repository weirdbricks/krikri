require "krikri_jinja"

module Krikri
  # Real Ansible searches a role's template includes across the template's own
  # directory, its `templates/` ancestors, and the role root (a template can
  # `{% include 'templates/other.j2' %}` by a role-root-relative path), while
  # krikri-jinja's FileSystemLoader is rooted at a single directory.
  class TemplateSearchPathLoader < KrikriJinja::Loader
    getter paths : Array(String)

    def initialize(paths : Array(String))
      @paths = paths.map { |path| File.expand_path(path) }
    end

    def get_source(name : String) : String?
      @paths.each do |root|
        path = File.expand_path(name, root)
        next unless path == root || path.starts_with?(root + File::SEPARATOR)
        return File.read(path) if File.file?(path)
      end
      nil
    end
  end
end
