module Krikri
  # Ansible's controller-side relative-src lookup (`ActionBase
  # ._find_needle` -> `DataLoader.path_dwim_relative_stack`): the ordered
  # candidate list a missing file's "Could not find or access" error
  # reports, and the same list resolution searches. Behavior matched to
  # ansible-core's dataloader.py, live-verified against ansible-playbook
  # for template:/copy:/script:/unarchive: with a missing relative src
  # (playbook-dir task and in-role task):
  #
  #   for each path in the task's search stack:
  #     <path>/<dirname>/<src>      (only when src's first path component
  #                                 is not <dirname> itself - `copy: src=
  #                                 files/x` searches <role>/files/x, never
  #                                 <role>/files/files/x)
  #     <path>/<src>
  #   then the loader basedir as last resort:
  #     <basedir>/<dirname>/<src>   (same dirname-skip condition)
  #     <basedir>/<src>
  #
  # The message shape comes from AnsibleFileNotFound.__init__: with a
  # non-empty path list the " on the Ansible Controller." tail lands
  # after the LAST searched path (no list at all for an absolute src,
  # whose lookup never populates one). Since 2.21 the "If you are using
  # a module ... remote_src option" sentence is the exception's help
  # text (_default_help_text), not part of the raised message - the
  # message ends at " on the Ansible Controller." in the fatal result,
  # and for script:/template: the console caused-by segment carries no
  # hint at all (live-verified vs 2.21.6).
  module NeedleLookup
    # The task's search stack: Ansible's `Task.get_search_path()` - the
    # role dependency chain, current role first, then the directory of
    # the file the task lives in (deduplicated against the role paths).
    # The basedir is NOT part of this - path_dwim_relative_stack appends
    # it unconditionally in #candidates.
    def self.search_stack(role_path : String?, role_parent_paths : Array(String)?, task_file_dir : String?) : Array(String)
      stack = [] of String
      stack << File.expand_path(role_path) if role_path
      # role_parent_paths is root-first (outermost .. parent); Ansible's
      # reversed dep chain runs current-role first.
      role_parent_paths.try(&.reverse.each { |path| stack << File.expand_path(path) })
      if task_file_dir
        dir = File.expand_path(task_file_dir)
        stack << dir unless stack.includes?(dir)
      end
      stack
    end

    def self.candidates(stack : Array(String), basedir : String, dirname : String, src : String) : Array(String)
      search = [] of String
      # path_dwim_relative_stack compares src's first path component
      # against dirname and skips the <dirname>/<src> form when they
      # match, so a src that already carries its subdir prefix cannot
      # produce <role>/files/files/<src> candidates (#1197).
      add_dirname = src.split('/')[0] != dirname
      stack.each do |path|
        upath = File.expand_path(path)
        role_base = File.dirname(upath)
        # Ansible's in-role branch: the search path points at a role's
        # tasks/ directory - look in the role root's dirname/ dir and
        # the tasks dir itself before the generic candidates
        if role_base.ends_with?("/tasks") && role_path?(upath)
          search << File.join(File.dirname(role_base), dirname, src)
          search << File.join(role_base, src)
        end
        search << File.join(upath, dirname, src) if add_dirname
        search << File.join(upath, src)
      end
      search << File.join(basedir, dirname, src) if add_dirname
      search << File.join(basedir, src)
      search
    end

    def self.not_found_message(src : String, candidates : Array(String)) : String
      if candidates.empty?
        "Could not find or access '#{src}' on the Ansible Controller."
      else
        "Could not find or access '#{src}'\nSearched in:\n\t#{candidates.join("\n\t")} on the Ansible Controller."
      end
    end

    # Matches DataLoader._is_role's shape: a directory that looks like a
    # role because it (or its parent) holds a main.yml/meta/tasks entry.
    def self.role_path?(path : String) : Bool
      untasked = ["main.yml", "main.yaml", "main"].any? { |entry| File.file?(File.join(path, entry)) }
      tasked = ["tasks/main.yml", "tasks/main.yaml", "tasks/main", "meta/main.yml", "meta/main.yaml", "meta/main"].any? do |entry|
        File.file?(File.join(path, entry)) || File.file?(File.join(File.dirname(path), entry))
      end
      (path.matches?(/\/tasks\//) && untasked) || tasked
    end
  end
end
