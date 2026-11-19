require "krikri-jinja/krikri_jinja"

module Krikri
  # Ansible searches a role's template includes across the template's own
  # directory, its `templates/` ancestors, and the role root (a template can
  # `{% include 'templates/other.j2' %}` by a role-root-relative path), while
  # krikri-jinja's FileSystemLoader is rooted at a single directory.
  class TemplateSearchPathLoader < KrikriJinja::Loader
    getter paths : Array(String)

    # Every include/import/extends this loader RESOLVED, in load order,
    # as absolute paths. The template action plugin walks these to find a
    # fact read that only an included file makes: real runs the includes
    # inside the outer template's templating operation, so their reads
    # warn with the outer file's Origin (issue #1603).
    getter resolved_templates = [] of String

    def initialize(paths : Array(String))
      @paths = paths.map { |path| File.expand_path(path) }
    end

    def get_source(name : String) : String?
      @paths.each do |root|
        path = File.expand_path(name, root)
        next unless path == root || path.starts_with?(root + File::SEPARATOR)
        next unless File.file?(path)
        @resolved_templates << path unless @resolved_templates.includes?(path)
        return File.read(path)
      end
      nil
    end
  end
end
