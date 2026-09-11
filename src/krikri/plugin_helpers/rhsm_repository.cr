require "json"

module Krikri
  module PluginHelpers
    # RhsmRepository - pure logic for the rhsm_repository plugin: parsing
    # `subscription-manager repos --list` output, fnmatch-style glob
    # matching, and deciding which repos need enabling/disabling. Split
    # out of plugins/rhsm_repository.cr so the argv/planning logic is
    # unit-spec-able (the execution path needs a real registered RHEL
    # system, which no spec environment has).
    module RhsmRepository
      struct Repo
        getter id : String
        getter name : String
        getter url : String
        getter enabled : Bool

        def initialize(id : String, name : String, url : String, enabled : Bool)
          @id = id
          @name = name
          @url = url
          @enabled = enabled
        end
      end

      # Mirrors the real module's Rhsm.list_repositories line walk: skip
      # empty/header/indented lines, start a repo at "Repo ID: ", close it
      # at the "Enabled: 1|0" line that follows its block.
      def self.parse_list(output : String) : Array(Repo)
        repos = [] of Repo
        repo_id = ""
        repo_name = ""
        repo_url = ""

        output.each_line do |line|
          next if line.empty? || line[0] == '+' || line[0] == ' '

          if line.starts_with?("Repo ID: ")
            repo_id = line[9..].lstrip
          elsif line.starts_with?("Repo Name: ")
            repo_name = line[11..].lstrip
          elsif line.starts_with?("Repo URL: ")
            repo_url = line[10..].lstrip
          elsif line.starts_with?("Enabled: ")
            repos << Repo.new(repo_id, repo_name, repo_url, line[9..].lstrip == "1")
          end
        end
        repos
      end

      # Python's fnmatch on repo IDs: '*' any run, '?' any one char,
      # everything else literal (fnmatch is case-insensitive on some
      # platforms but repo IDs are lowercase hex/alnum anyway, so the
      # case handling never decides a match here).
      def self.glob_match?(repo_id : String, pattern : String) : Bool
        regex = String.build do |str|
          pattern.each_char do |char|
            case char
            when '*' then str << ".*"
            when '?' then str << '.'
            else
              str << Regex.escape(char.to_s)
            end
          end
        end
        Regex.new("^#{regex}$").matches?(repo_id)
      rescue
        false
      end

      # The whole decision the real module's repository_modify() makes:
      # which repo IDs to enable/disable for the requested state, whether
      # anything changes, the updated (post-decision) repo list, and the
      # "not a valid repository ID" failure the real module raises when a
      # pattern matches nothing.
      struct Plan
        getter enable : Array(String)
        getter disable : Array(String)
        getter changed : Bool
        getter updated : Array(Repo)
        getter invalid_pattern : String?

        def initialize(enable, disable, changed, updated, invalid_pattern)
          @enable = enable
          @disable = disable
          @changed = changed
          @updated = updated
          @invalid_pattern = invalid_pattern
        end
      end

      # state here is already normalized to "enabled"/"disabled" (the
      # plugin maps the removed present/absent spellings onto these).
      def self.plan(repos : Array(Repo), names : Array(String), state : String, purge : Bool) : Plan
        changed = false
        enable = [] of String
        disable = [] of String
        invalid_pattern = nil

        matched_ids = Set(String).new
        matched_repos = [] of Repo

        names.each do |pattern|
          matched = repos.select { |repo| glob_match?(repo.id, pattern) }
          if matched.empty?
            invalid_pattern = pattern
            break
          end
          matched.each { |repo| matched_ids << repo.id }
          matched_repos.concat(matched)
        end
        return Plan.new(enable, disable, false, repos, invalid_pattern) if invalid_pattern

        want_enabled = state == "enabled"
        matched_repos.each do |repo|
          if !want_enabled && repo.enabled
            changed = true
            disable << repo.id
          elsif want_enabled && !repo.enabled
            changed = true
            enable << repo.id
          end
        end

        updated = repos.map do |repo|
          if matched_ids.includes?(repo.id) && repo.enabled != want_enabled
            Repo.new(repo.id, repo.name, repo.url, want_enabled)
          else
            repo
          end
        end

        if purge
          repos.each do |repo|
            next if matched_ids.includes?(repo.id)
            next unless repo.enabled
            changed = true
            disable << repo.id
          end
          updated = updated.map do |repo|
            next repo if matched_ids.includes?(repo.id) || !repo.enabled
            Repo.new(repo.id, repo.name, repo.url, false)
          end
        end

        Plan.new(enable, disable, changed, updated, nil)
      end
    end
  end
end
