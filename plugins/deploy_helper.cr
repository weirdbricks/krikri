#!/usr/bin/env crystal

require "json"
require "../src/krikri/base_plugin"

module Krikri
  # deploy_helper plugin - manages the release-directory layout used
  # by the "capistrano-style" deploy pattern, a native reimplementation of
  # community.general.deploy_helper.
  #
  # Implemented against real deploy_helper.py's control flow:
  #   - directory layout: <path>/releases, <path>/shared, <path>/current
  #     (created for state=present/finalize when missing)
  #   - state=present: creates the project/releases/shared dirs only
  #     (real main()'s three create_path calls - NOT the new release dir
  #     and NOT current: the release dir is the caller's build step's
  #     job and `current` only comes into existence at finalize), and
  #     generates a release name YYYYmmddHHMMSS like real's own default
  #     when none is given, stored in the result's
  #     `release`/`new_release` return values so follow-up tasks can
  #     reference it via the registered variable
  #   - state=clean: real main()'s three-step flow: remove_unfinished_link
  #     (<path>/<release>.<unfinished_filename>), remove_unfinished_builds
  #     (a bare os.listdir on releases_path - it CRASHES with the raw
  #     OSError when the tree was never created by state=present, the
  #     kpg35 #30 divergence), then cleanup (ctime-descending, the
  #     `release` param reserved, and NO protection of the `current`
  #     target - live-verified: real happily deletes the release
  #     `current` points at and leaves the symlink dangling)
  #   - state=finalize: remove_unfinished_file (drop the marker inside
  #     the release dir), create_link (points `current` symlink at the
  #     release atomically via ln -sfn), then - when the `clean` param
  #     is set, its default - the full state=clean branch; the
  #     listdir-crash fires AFTER the symlink is created (live-verified:
  #     a fresh-tree finalize leaves the dangling `current` behind and
  #     then fails on the missing releases dir)
  #   - state=absent: removes the whole <path> tree, and publishes
  #     ansible_facts.deploy_helper as an empty LIST (real main()'s own
  #     "destroy the facts" sentinel - not a dict)
  #   - state=present/query: publishes ansible_facts.deploy_helper (real
  #     gather_facts()' dict; round900881
  #     mbaran0v.ansible_role_prometheus_rabbitmq_exporter's follow-up
  #     tasks read deploy_helper.new_release_path, which failed with
  #     "undefined variable" before this published anything)
  #   - state=finalize/clean: publish NO ansible_facts (real main() sets
  #     none for these states)
  #   - check mode: discovery runs for real, mutations are not run
  #
  # `new_release_state` (deprecated upstream arg) is accepted and
  # ignored, matching real's behavior of treating it as always
  # "create".
  class DeployHelperPlugin < BasePlugin
    # Real argument_spec order (live-verified: "value of state must be
    # one of: present, absent, clean, finalize, query, got: X"). Real
    # has no "unfinished" state.
    private DEPLOY_STATES = %w[present absent clean finalize query]

    private def resolve_deploy_paths(path : String) : Tuple(String, String, String)
      {
        deploy_path_join(path, @params["releases_path"]? || "releases"),
        deploy_path_join(path, @params["shared_path"]? || "shared"),
        deploy_path_join(path, @params["current_path"]? || "current"),
      }
    end

    # os.path.join(path, sub): a relative sub hangs off the project
    # path (real gather_facts() joins every one of the three paths onto
    # it), an absolute one is used verbatim.
    private def deploy_path_join(path : String, sub : String) : String
      return sub if sub.starts_with?('/')
      "#{path.rstrip('/')}/#{sub}"
    end

    def execute : PluginResult
      path = @params["path"]?
      unless path
        return PluginResult.new(changed: false, failed: true,
          msg: "missing required arguments: path")
      end

      state = @params["state"]? || "present"
      unless DEPLOY_STATES.includes?(state)
        return PluginResult.new(changed: false, failed: true,
          msg: "value of state must be one of: #{DEPLOY_STATES.join(", ")}, got: #{state}")
      end

      releases_path, shared_path, current_path = resolve_deploy_paths(path)
      keep_releases = @params["keep_releases"]?.try(&.to_i?) || 5
      release = @params["release"]?
      check_mode = true?(@params["_ansible_check_mode"]?)
      clean_param = true?(@params["clean"]?, default: true)

      # Real required_if=[("state", "finalize", ["release"])].
      if state == "finalize" && !release
        return PluginResult.new(changed: false, failed: true,
          msg: "state is finalize but all of the following are missing: release")
      end

      case state
      when "absent"
        absent_path(path, check_mode)
      when "present"
        present(path, releases_path, shared_path, current_path, release, check_mode)
      when "clean"
        clean(path, releases_path, release, keep_releases, check_mode)
      when "finalize"
        do_finalize(path, current_path, release, shared_path, releases_path, clean_param,
          keep_releases, check_mode)
      else # query
        query(path, releases_path, shared_path, current_path, release)
      end
    end

    private def absent_path(path : String, check_mode : Bool) : PluginResult
      exists = remote_exec("test -e #{Shell.single_quote(path)}")
      # Real main() publishes {"deploy_helper": []} for state=absent -
      # an empty list, its deliberate "destroy the facts" sentinel - on
      # every non-failed exit, including the nothing-to-remove no-op.
      # Real's result dict is {state, ansible_facts} + changed - no msg
      # (round 994002 kop_misc2: registered state, ansible_facts,
      # changed, failed).
      return deploy_helper_result("absent", absent_facts, changed: false) unless exists[:exit_code] == 0
      return deploy_helper_result("absent", absent_facts, changed: true) if check_mode

      result = remote_exec("rm -rf #{Shell.single_quote(path)}")
      unless result[:exit_code] == 0
        return PluginResult.new(changed: false, failed: true,
          msg: "failed to remove #{path}: #{result[:stderr].strip}")
      end
      deploy_helper_result("absent", absent_facts, changed: true)
    end

    private def absent_facts : JSON::Any
      JSON::Any.new({"deploy_helper" => JSON::Any.new([] of JSON::Any)})
    end

    # Creates the directory layout. Real main() runs create_path exactly
    # three times - project_path, releases_path, shared_path - so the new
    # release dir and `current` are NOT created here: the release dir is
    # the caller's build step's job (real's docs clone/copy into
    # new_release_path themselves) and `current` only comes into
    # existence at state=finalize. mkdir'ing current_path here as a real
    # directory made finalize's `ln -sfn` land INSIDE it
    # (current/<release>) and left current a directory forever.
    # changed mirrors real's create_path counting: true only when at
    # least one of the three dirs was actually missing.
    private def present(path : String, releases_path : String, shared_path : String,
                        current_path : String, release : String?, check_mode : Bool) : PluginResult
      release ||= Time.utc.to_s("%Y%m%d%H%M%S")
      facts = gather_facts(path, releases_path, shared_path, current_path, release)

      link_check = remote_exec("if [ -e #{Shell.single_quote(current_path)} ] && [ ! -L #{Shell.single_quote(current_path)} ]; then echo not-a-link; fi")
      if link_check[:stdout].includes?("not-a-link")
        return PluginResult.new(changed: false, failed: true,
          msg: "#{current_path} exists but is not a symbolic link")
      end

      dirs = [path, releases_path, shared_path]
      missing = dirs.reject do |dir|
        remote_exec("test -d #{Shell.single_quote(dir)}")[:exit_code] == 0
      end
      changed = !missing.empty?

      if check_mode
        return deploy_helper_result("present", facts_any(facts), changed: changed)
      end

      unless missing.empty?
        mk = remote_exec("mkdir -p #{missing.map { |dir| Shell.single_quote(dir) }.join(' ')}")
        unless mk[:exit_code] == 0
          return PluginResult.new(changed: false, failed: true,
            msg: "failed to create deploy layout: #{mk[:stderr].strip}")
        end
      end

      # Real main()'s result dict for state=present is exactly
      # {state, ansible_facts} + changed - no msg, and no top-level
      # release/new_release echo (they live only inside the facts;
      # round 994002 kop_misc2: registered state, ansible_facts,
      # changed, failed).
      deploy_helper_result("present", facts_any(facts), changed: changed)
    end

    private def facts_any(facts : Hash(String, String?)) : JSON::Any
      JSON::Any.new({"deploy_helper" => JSON.parse(facts.to_json)})
    end

    # Real main()'s exit shape for every non-failed state: the result
    # dict starts with `state`, carries ansible_facts for
    # present/query/absent only, then changed - failed is backfilled by
    # the task executor.
    private def deploy_helper_result(state : String, facts : JSON::Any?, changed : Bool) : PluginResult
      result = PluginResult.new(changed: changed, failed: false,
        key_order: ["state", "ansible_facts", "changed"])
      result.extra["state"] = JSON::Any.new(state)
      result.extra["ansible_facts"] = facts if facts
      result
    end

    # Real remove_unfinished_link(path): deletes the
    # <path>/<release>.<unfinished_filename> file when it exists. Real's
    # own guard (`if not check_mode and os.path.exists`) skips the whole
    # step in check mode, so a check-mode clean/finalize never counts it.
    private def remove_unfinished_link(path : String, release : String?,
                                       unfinished_filename : String, check_mode : Bool) : Int32
      return 0 unless release && !release.empty? && !check_mode
      tmp_link = "#{path}/#{release}.#{unfinished_filename}"
      if remote_exec("test -e #{Shell.single_quote(tmp_link)}")[:exit_code] == 0
        remote_exec("rm -f #{Shell.single_quote(tmp_link)}")
        1
      else
        0
      end
    end

    # Real remove_unfinished_builds(releases_path): a bare os.listdir -
    # it raises the raw OSError when releases_path doesn't exist or
    # isn't a directory (live-verified against 2.19.11: state=clean on a
    # tree never created by state=present crashes the module with
    # "[Errno 2] No such file or directory: '<releases_path>'"; a FILE
    # at releases_path gives "[Errno 20] Not a directory"). Release dirs
    # containing the unfinished marker file are removed wholesale.
    private def remove_unfinished_builds(releases_path : String, unfinished_filename : String,
                                         check_mode : Bool) : {changes: Int32, failure: PluginResult?}
      found = listdir_entries(releases_path)
      return {changes: 0, failure: found} if found.is_a?(PluginResult)

      changes = 0
      found.each do |entry|
        marker = "#{releases_path}/#{entry}/#{unfinished_filename}"
        next unless remote_exec("test -f #{Shell.single_quote(marker)}")[:exit_code] == 0
        if check_mode
          changes += 1
        else
          result = delete_path("#{releases_path}/#{entry}")
          return {changes: 0, failure: result} if result.is_a?(PluginResult)
          changes += result
        end
      end
      {changes: changes, failure: nil}
    end

    # Real cleanup(releases_path, reserve_version): releases are
    # re-listed as directories only, the `release` param (new_release)
    # is reserved out of the candidates, and the remainder is sorted by
    # ctime DESCENDING with everything past keep_releases deleted - NO
    # protection of the `current` symlink's target (live-verified: real
    # deletes the release `current` points at and leaves the symlink
    # dangling). Check mode counts without deleting.
    private def cleanup_releases(releases_path : String, release : String?,
                                 keep_releases : Int32, check_mode : Bool) : {changes: Int32, failure: PluginResult?}
      unless remote_exec("test -e #{Shell.single_quote(releases_path)} || test -L #{Shell.single_quote(releases_path)}")[:exit_code] == 0
        return {changes: 0, failure: nil}
      end

      probe = remote_exec("find #{Shell.single_quote(releases_path)} -mindepth 1 -maxdepth 1 " \
                          "\\( -type d -o \\( -type l -xtype d \\) \\) -printf '%C@\\t%f\\n' 2>/dev/null")
      dirs = probe[:stdout].strip.empty? ? [] of Tuple(Int64, String) : probe[:stdout].strip.lines.compact_map do |line|
        parts = line.split("\t", 2)
        next nil unless parts.size == 2 && (t = parts[0].to_f?)
        {t.to_i64, parts[1]}
      end
      dirs.reject! { |dir| dir[1] == release } if release
      return {changes: 0, failure: nil} if dirs.size <= keep_releases
      return {changes: dirs.size - keep_releases, failure: nil} if check_mode

      # Newest first. Crystal's sort is not stable, but real's Python
      # sort on equal ctimes is listdir-order-dependent anyway, so ties
      # are unmatchable by construction.
      newest_first = dirs.sort { |a, b| b[0] <=> a[0] }
      changes = 0
      newest_first[keep_releases..].each do |(_, name)|
        result = delete_path("#{releases_path}/#{name}")
        return {changes: 0, failure: result} if result.is_a?(PluginResult)
        changes += result
      end
      {changes: changes, failure: nil}
    end

    # os.listdir's raw OSError shapes, surfaced through the module-crash
    # wrapper exactly like an uncaught module exception (the live-verified
    # wording: both the [ERROR] block and the fatal dump carry the full
    # "Task failed: Module failed: <OSError>" chain).
    private def listdir_entries(dir : String) : Array(String) | PluginResult
      unless remote_exec("test -e #{Shell.single_quote(dir)}")[:exit_code] == 0
        return os_crash("[Errno 2] No such file or directory: '#{dir}'")
      end
      unless remote_exec("test -d #{Shell.single_quote(dir)}")[:exit_code] == 0
        return os_crash("[Errno 20] Not a directory: '#{dir}'")
      end
      listing = remote_exec("ls -1A #{Shell.single_quote(dir)} 2>/dev/null")
      listing[:exit_code] == 0 ? listing[:stdout].lines.map(&.strip).reject(&.empty?) : [] of String
    end

    # The full chain goes into the fatal dump's msg; the [ERROR] block
    # gets the bare OSError via the detail key (the block builder wraps
    # it with the same "Task failed: Module failed: " chain, producing
    # the live-verified #30 shape in both places).
    private def os_crash(detail : String) : PluginResult
      PluginResult.new(changed: false, failed: true,
        msg: "Task failed: Module failed: #{detail}", _ansible_error_detail: detail)
    end

    # Real delete_path(): 0 when the path is already gone (lexists),
    # fail_json when it exists but is not a directory, else rmtree (1).
    private def delete_path(path : String) : Int32 | PluginResult
      unless remote_exec("test -e #{Shell.single_quote(path)} || test -L #{Shell.single_quote(path)}")[:exit_code] == 0
        return 0
      end
      unless remote_exec("test -d #{Shell.single_quote(path)}")[:exit_code] == 0
        return PluginResult.new(changed: false, failed: true,
          msg: "#{path} exists but is not a directory")
      end
      result = remote_exec("rm -rf #{Shell.single_quote(path)}")
      unless result[:exit_code] == 0
        return PluginResult.new(changed: false, failed: true,
          msg: "rmtree failed: #{result[:stderr].strip}")
      end
      1
    end

    # Real main()'s state=clean flow, in order: remove_unfinished_link
    # (the <path>/<release>.<unfinished_filename> file),
    # remove_unfinished_builds (release dirs carrying the unfinished
    # marker - and the bare-os.listdir crash when releases_path is
    # missing), then cleanup (ctime-descending deletion past
    # keep_releases with the `release` param reserved).
    private def clean(path : String, releases_path : String, release : String?,
                      keep_releases : Int32, check_mode : Bool) : PluginResult
      unfinished_filename = @params["unfinished_filename"]? || "DEPLOY_UNFINISHED"

      step = run_clean_branch(path, releases_path, release, keep_releases,
        unfinished_filename, check_mode)
      if failure = step[:failure]
        return failure
      end

      PluginResult.new(changed: step[:changes] > 0, failed: false, msg: "", key_order: ["state", "changed"],
        state: "clean")
    end

    # The state=clean branch real main() runs for BOTH state=clean and
    # (when the `clean` param is set) state=finalize, in order:
    # remove_unfinished_link, remove_unfinished_builds, cleanup.
    private def run_clean_branch(path : String, releases_path : String, release : String?,
                                 keep_releases : Int32, unfinished_filename : String,
                                 check_mode : Bool) : {changes: Int32, failure: PluginResult?}
      changes = remove_unfinished_link(path, release, unfinished_filename, check_mode)

      step = remove_unfinished_builds(releases_path, unfinished_filename, check_mode)
      return step if step[:failure]

      step = cleanup_releases(releases_path, release, keep_releases, check_mode)
      return step if step[:failure]

      {changes: changes + step[:changes], failure: nil}
    end

    # Real main()'s state=finalize flow, in order: the keep_releases>0
    # guard, remove_unfinished_file (drop the DEPLOY_UNFINISHED marker
    # inside the release dir; the lexists probe runs before the
    # check-mode branch, so it counts as a change even in check mode),
    # create_link (point `current` at the release - or at shared when
    # release is empty, real's documented no-release behavior), then -
    # when the `clean` param is set, its default - the full state=clean
    # branch. The listdir crash fires AFTER the symlink is created
    # (live-verified: a fresh-tree finalize leaves the dangling `current`
    # symlink behind and then fails on the missing releases dir).
    private def do_finalize(path : String, current_path : String, release : String?,
                            shared_path : String, releases_path : String, clean_param : Bool,
                            keep_releases : Int32, check_mode : Bool) : PluginResult
      if keep_releases <= 0
        return PluginResult.new(changed: false, failed: true,
          msg: "'keep_releases' should be at least 1")
      end

      unfinished_filename = @params["unfinished_filename"]? || "DEPLOY_UNFINISHED"
      changes = remove_unfinished_file(releases_path, release, unfinished_filename, check_mode)

      target = release && !release.empty? ? "#{releases_path}/#{release}" : shared_path

      # Real create_link(): a `current` that is a symlink is compared by
      # normalized realpath against the source's; anything else is
      # created fresh with os.symlink. Real never pre-checks that the
      # release exists - a missing release dir only surfaces when the
      # symlink itself can't be created, i.e. when the link's parent
      # directory is missing too, as the raw OSError text of that
      # os.symlink (live-captured: "[Errno 2] No such file or directory:
      # '<new_release_path>' -> '<current_path>'"). This plugin used to
      # pre-check `test -d` on the release and fail its own "release
      # path ... does not exist" instead.
      link = create_link(target, current_path, check_mode)
      if failure = link[:failure]
        return failure
      end

      changes += 1 if link[:changed]

      if clean_param
        step = run_clean_branch(path, releases_path, release, keep_releases,
          unfinished_filename, check_mode)
        if failure = step[:failure]
          return failure
        end
        changes += step[:changes]
      end

      # Real main()'s state=finalize result: {state, changed} - no msg
      # (round 994002 kop_misc2: registered state, changed, failed).
      PluginResult.new(changed: changes > 0, failed: false, key_order: ["state", "changed"],
        state: "finalize")
    end

    # Real remove_unfinished_file(new_release_path): drops the
    # DEPLOY_UNFINISHED marker inside the release dir when present. The
    # lexists probe runs before the check-mode branch, so the marker
    # counts as a change even in check mode.
    private def remove_unfinished_file(releases_path : String, release : String?,
                                       unfinished_filename : String, check_mode : Bool) : Int32
      return 0 unless release && !release.empty?
      marker = "#{releases_path}/#{release}/#{unfinished_filename}"
      if remote_exec("test -e #{Shell.single_quote(marker)}")[:exit_code] == 0
        remote_exec("rm -f #{Shell.single_quote(marker)}") unless check_mode
        1
      else
        0
      end
    end

    # Real create_link(source, link_name), split out of do_finalize for
    # readability. Returns {changed, already, failure}: `changed` when a
    # fresh symlink was (or, in check mode, would be) created,
    # `already` when current already points at the target (real counts
    # no change and CONTINUES into the clean branch - old releases can
    # still be removed, making the task changed=true), `failure` when
    # real's own raises fire (a dangling source on the re-link path, or
    # the raw os.symlink OSError when the link's parent dir is missing).
    private def create_link(target : String, current_path : String,
                            check_mode : Bool) : {changed: Bool, already: Bool, failure: PluginResult?}
      is_link = remote_exec("test -L #{Shell.single_quote(current_path)}")[:exit_code] == 0
      if is_link
        norm_link = remote_exec("readlink -f #{Shell.single_quote(current_path)} 2>/dev/null")[:stdout].strip
        norm_source = remote_exec("readlink -f #{Shell.single_quote(target)} 2>/dev/null")[:stdout].strip
        return {changed: false, already: true, failure: nil} if !norm_link.empty? && norm_link == norm_source
        return {changed: true, already: false, failure: nil} if check_mode

        # Real: a lexists check on the source before the atomic
        # tmp-symlink + rename (the previous krikri flow never failed
        # for a dangling source).
        unless remote_exec("test -e #{Shell.single_quote(target)} || test -L #{Shell.single_quote(target)}")[:exit_code] == 0
          return {changed: false, already: false, failure: PluginResult.new(changed: false, failed: true,
            msg: "the symlink target #{target} doesn't exists")}
        end
      elsif check_mode
        return {changed: true, already: false, failure: nil}
      else
        unless remote_exec("test -d #{Shell.single_quote(File.dirname(current_path))}")[:exit_code] == 0
          # Real's module never fail_json's here - the os.symlink raises
          # straight through to the module-crash wrapper: the wire msg
          # is the full "Task failed: Module failed: <OSError>" chain
          # (live-verified) while the [ERROR] block shows the bare
          # OSError - the replace.cr module-crash shape.
          detail = "[Errno 2] No such file or directory: '#{target}' -> '#{current_path}'"
          return {changed: false, already: false, failure: PluginResult.new(changed: false, failed: true,
            msg: "Task failed: Module failed: #{detail}", _ansible_error_detail: detail)}
        end
      end

      result = remote_exec("ln -sfn #{Shell.single_quote(target)} #{Shell.single_quote(current_path)}")
      unless result[:exit_code] == 0
        return {changed: false, already: false, failure: PluginResult.new(changed: false, failed: true,
          msg: "failed to update current symlink: #{result[:stderr].strip}")}
      end
      {changed: true, already: false, failure: nil}
    end

    # Mirrors real gather_facts(): publishes the fact dict that real
    # main() attaches to result["ansible_facts"] for state present/query
    # (round900881 mbaran0v.ansible_role_prometheus_rabbitmq_exporter:
    # its follow-up "create release directory" task reads
    # deploy_helper.new_release_path, which was undefined before this
    # dict existed). previous_release/previous_release_path come from
    # the `current` symlink's realpath (nil when there is no symlink
    # yet); a falsy shared_path param publishes null, matching real's
    # `if self.shared_path` guard.
    private def gather_facts(path : String, releases_path : String, shared_path : String,
                             current_path : String, release : String?) : Hash(String, String?)
      # Real _get_last_release(): realpath/basename only when the
      # current path lexists at all; GNU readlink -f on a missing path
      # still exits 0 printing the would-be path, which would invent a
      # previous_release of "current" out of thin air.
      previous_release = nil
      previous_release_path = nil
      exists = remote_exec("test -e #{Shell.single_quote(current_path)}")
      if exists[:exit_code] == 0
        probe = remote_exec("readlink -f #{Shell.single_quote(current_path)} 2>/dev/null")
        if probe[:exit_code] == 0 && !(out = probe[:stdout].strip).empty?
          previous_release_path = out
          previous_release = out.split("/").last
        end
      end

      shared_param = @params["shared_path"]?
      shared_fact = shared_param && shared_param.empty? ? nil : shared_path

      {
        "project_path"          => path,
        "current_path"          => current_path,
        "releases_path"         => releases_path,
        "shared_path"           => shared_fact,
        "previous_release"      => previous_release,
        "previous_release_path" => previous_release_path,
        "new_release"           => release,
        "new_release_path"      => release ? "#{releases_path}/#{release}" : nil,
        "unfinished_filename"   => @params["unfinished_filename"]? || "DEPLOY_UNFINISHED",
      }
    end

    private def query(path : String, releases_path : String, shared_path : String,
                      current_path : String, release : String?) : PluginResult
      # Real gather_facts() generates a fresh YYYYmmddHHMMSS new_release
      # for state=query too when release: is omitted, so query's facts
      # carry the same prospective release a follow-up present would use.
      release ||= Time.utc.to_s("%Y%m%d%H%M%S")
      facts = gather_facts(path, releases_path, shared_path, current_path, release)
      # Real query's result carries only state/ansible_facts/changed -
      # no top-level releases list (the releases are only ever visible
      # as a directory listing, not published).
      deploy_helper_result("query", facts_any(facts), changed: false)
    end
  end
end

input = STDIN.gets_to_end
config = JSON.parse(input)
plugin = Krikri::DeployHelperPlugin.new(config)
plugin.run
