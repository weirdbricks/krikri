require "base64"
require "json"

module Krikri
  module PluginHelpers
    # Issue #1020 (archf.packages, round29903334, Rocky 9): a failed
    # install whose unresolvable specs land in `failures` still reports
    # the transaction the survivors WOULD run - Ansible's
    # "Failed to install some of the specified packages" fail_json
    # carries `results` with one "Installed: <nevra>" per package the
    # resolved transaction installs (dependency closure included) and
    # "Removed: <nevra>" per package it replaces, while this engine
    # reported results []. The entries come from
    # base.transaction.install_set / .remove_set - Python SETS of the
    # libdnf packages - so their order is CPython's set-slot iteration
    # over the packages' sack ids (verified live in a rockylinux:9
    # container: the order is deterministic per host state but
    # unreproducible from any CLI output - `dnf install --assumeno`'s
    # table sorts by name, `dnf repoquery` cannot even see the
    # module-hidden solvables that occupy ids in the middle of the
    # range). Byte-parity with ansible on the same host therefore needs
    # the same computation in the same runtime, so the dnf bindings'
    # own marking + resolution is replayed here by a small python
    # program run ON THE TARGET - a faithful port of the parts of
    # ansible-core 2.21's module_utils/_embed/dnf.py that build
    # `results` (_ensure_impl, _mark_package_install,
    # _is_newer_version_installed, _parse_spec_group_file,
    # _install_remote_rpms_helper; GPL-3.0+, same license as this
    # repo). It only ever READS the host - it marks and resolves, never
    # downloads or runs the transaction (exactly where ansible's own
    # fail_json returns), so a failing task mutates nothing under it.
    #
    # python3-dnf is the same requirement ansible's own dnf module has
    # (its _ensure_dnf respawns the interpreter until `import dnf`
    # works); when no interpreter on the target can import it the probe
    # answers nil and the caller keeps its historical results [] shape.
    module DnfTransactionProbe
      # Ansible's own module-respawn probe order
      # (dnf.py _ensure_dnf's system_interpreters) - `python3` first so
      # the spec suite's PATH shims can stand in for the probe, then
      # the platform-python RHEL 8 ships the dnf bindings under.
      PROBE_INTERPRETERS = ["python3", "/usr/libexec/platform-python", "/usr/bin/python3"]

      # The transaction computation itself: config in, the
      # failure-shape `results` entries out. Mirrors the embedded
      # script's response['results'] composition up to its
      # "Failed to install some of the specified packages" raises -
      # the pre-transaction entries (fetched filenames, groups,
      # update_only's skip messages, a glob miss's own msg) followed,
      # when the goal resolved to a real transaction, by the
      # install_set/remove_set entries. Any error after the imports
      # prints {"error": ...} so the caller can tell "the bindings
      # loaded but this goal is not answerable" (stop) from "this
      # interpreter cannot run the probe" (try the next one) - a dnf
      # import failure dies before that and leaves no JSON at all.
      PROBE_PROGRAM = <<-PYTHON
        import json

        import dnf
        import dnf.const
        import dnf.exceptions
        import dnf.package
        import dnf.subject
        import dnf.util


        def _is_package_installed(base, package_spec):
            return bool(dnf.subject.Subject(package_spec).get_best_query(sack=base.sack).installed())


        def _is_newer_version_installed(base, pkg_spec):
            try:
                if isinstance(pkg_spec, dnf.package.Package):
                    installed = sorted(base.sack.query().installed().filter(name=pkg_spec.name, arch=pkg_spec.arch))[-1]
                    return installed.evr_gt(pkg_spec)
                solution = dnf.subject.Subject(pkg_spec).get_best_solution(base.sack)
                query = solution['query']
                nevra = solution['nevra']
                if not query or not nevra or nevra.has_just_name() or not nevra.version:
                    return False
                filter_kwargs = {'name': nevra.name}
                if nevra.arch:
                    filter_kwargs['arch'] = nevra.arch
                installed = base.sack.query().installed().filter(**filter_kwargs)
                if not installed:
                    return False
                return installed[0].evr_gt(query[0])
            except IndexError:
                return False


        def _mark_package_install(base, pkg_spec, upgrade, allow_downgrade):
            msg = ''
            strict = base.conf.strict
            try:
                if dnf.util.is_glob_pattern(pkg_spec):
                    if upgrade:
                        try:
                            base.upgrade(pkg_spec)
                        except dnf.exceptions.PackagesNotInstalledError:
                            pass
                    try:
                        base.install(pkg_spec, strict=strict)
                    except dnf.exceptions.MarkingError:
                        msg = 'No package %s available.' % pkg_spec
                        if strict:
                            return {'failed': True, 'msg': msg}
                    except dnf.exceptions.DepsolveError:
                        return {'failed': True, 'msg': 'Depsolve Error occurred for package %s.' % pkg_spec}
                    except dnf.exceptions.Error:
                        return {'failed': True, 'msg': 'Unknown Error occurred for package %s.' % pkg_spec}
                elif _is_newer_version_installed(base, pkg_spec):
                    if allow_downgrade:
                        try:
                            base.install(pkg_spec, strict=strict)
                        except dnf.exceptions.MarkingError:
                            msg = 'No package %s available.' % pkg_spec
                            if strict:
                                return {'failed': True, 'msg': msg}
                elif _is_package_installed(base, pkg_spec):
                    if upgrade:
                        try:
                            base.upgrade(pkg_spec)
                        except dnf.exceptions.PackagesNotInstalledError:
                            pass
                else:
                    try:
                        base.install(pkg_spec, strict=strict)
                    except dnf.exceptions.MarkingError:
                        msg = 'No package %s available.' % pkg_spec
                        if strict:
                            return {'failed': True, 'msg': msg}
                    except dnf.exceptions.DepsolveError:
                        return {'failed': True, 'msg': 'Depsolve Error occurred for package %s.' % pkg_spec}
                    except dnf.exceptions.Error:
                        return {'failed': True, 'msg': 'Unknown Error occurred for package %s.' % pkg_spec}
            except Exception:
                return {'failed': True, 'msg': 'Unknown Error occurred for package %s.' % pkg_spec}
            return {'failed': False, 'msg': msg}


        def _parse_spec_group_file(base, names, update_only):
            pkg_specs, grp_specs, filenames = [], [], []
            already_loaded_comps = False
            for name in names:
                if '://' in name:
                    filenames.append(name)
                elif name.endswith('.rpm'):
                    filenames.append(name)
                elif name.startswith('/'):
                    installed = base.sack.query().filter(provides=name, file=name).installed().run()
                    if installed:
                        pkg_specs.append(installed[0].name)
                    elif not update_only:
                        pkg_specs.append(name)
                elif name.startswith('@') or ('/' in name):
                    if not already_loaded_comps:
                        base.read_comps()
                        already_loaded_comps = True
                    grp_specs.append(name[1:].strip())
                else:
                    pkg_specs.append(name)
            return pkg_specs, grp_specs, filenames


        def _update_only_helper(base, pkgs):
            not_installed = []
            for pkg in pkgs:
                pkg_nevra = str(pkg) if isinstance(pkg, dnf.package.Package) else pkg
                if _is_package_installed(base, pkg_nevra):
                    if isinstance(pkg, dnf.package.Package):
                        base.package_upgrade(pkg)
                    else:
                        base.upgrade(pkg)
                else:
                    not_installed.append(pkg)
            return not_installed


        def _install_remote_rpms_helper(base, filenames, update_only, allow_downgrade):
            pkgs = base.add_remote_rpms(filenames)
            if update_only:
                _update_only_helper(base, pkgs)
            else:
                for pkg in pkgs:
                    if not (_is_newer_version_installed(base, pkg) and not allow_downgrade):
                        base.package_install(pkg, strict=base.conf.strict)


        def _configure_base(base, cfg):
            conf = base.conf
            if cfg.get('conf_file'):
                conf.config_file_path = cfg['conf_file']
            conf.read()
            conf.gpgcheck = not cfg.get('disable_gpg_check', False)
            conf.localpkg_gpgcheck = not cfg.get('disable_gpg_check', False)
            conf.assumeyes = True
            conf.sslverify = cfg.get('sslverify', True)
            conf.installroot = cfg.get('installroot', '/')
            conf.substitutions.update_from_etc(cfg.get('installroot', '/'))
            if cfg.get('exclude'):
                excludes = list(conf.exclude)
                excludes.extend(cfg['exclude'])
                conf.exclude = excludes
            if cfg.get('disable_excludes'):
                disable_excludes = list(conf.disable_excludes)
                if cfg['disable_excludes'] not in disable_excludes:
                    disable_excludes.append(cfg['disable_excludes'])
                conf.disable_excludes = disable_excludes
            if cfg.get('releasever') is not None:
                conf.substitutions['releasever'] = cfg['releasever']
            for opt in ('cachedir', 'logdir', 'persistdir'):
                conf.prepend_installroot(opt)
            if cfg.get('skip_broken'):
                conf.strict = 0
            if cfg.get('nobest') is not None:
                conf.best = not cfg['nobest']
            elif cfg.get('best') is not None:
                conf.best = cfg['best']
            if cfg.get('download_only'):
                conf.downloadonly = True
                if cfg.get('download_dir'):
                    conf.destdir = cfg['download_dir']
            if cfg.get('cacheonly'):
                conf.cacheonly = True
            conf.clean_requirements_on_remove = cfg.get('autoremove', False)
            conf.install_weak_deps = cfg.get('install_weak_deps', True)


        def _transaction_results(base, response_results, has_changes, download_only):
            results = list(response_results)
            if has_changes:
                install_action = 'Downloaded' if download_only else 'Installed'
                for package in base.transaction.install_set:
                    results.append('%s: %s' % (install_action, package))
                for package in base.transaction.remove_set:
                    results.append('Removed: %s' % package)
            return results


        def main():
            base = dnf.Base()
            _configure_base(base, cfg)

            base.setup_loggers()
            base.init_plugins(set(cfg.get('disable_plugin', [])), set(cfg.get('enable_plugin', [])))
            base.pre_configure_plugins()
            base.read_all_repos()
            for repo_pattern in cfg.get('disablerepo', []):
                if repo_pattern:
                    for repo in base.repos.get_matching(repo_pattern):
                        repo.disable()
            for repo_pattern in cfg.get('enablerepo', []):
                if repo_pattern:
                    for repo in base.repos.get_matching(repo_pattern):
                        repo.enable()
            base.configure_plugins()
            base.fill_sack(load_system_repo='auto')

            add_security_filters = getattr(base, 'add_security_filters', None)
            if callable(add_security_filters):
                filters = {}
                if cfg.get('bugfix'):
                    filters.setdefault('types', []).append('bugfix')
                if cfg.get('security'):
                    filters.setdefault('types', []).append('security')
                if filters:
                    add_security_filters('eq', **filters)
            else:
                filters = []
                if cfg.get('bugfix'):
                    filters.append(base.sack.query().upgrades().filter(advisory_type__eq='bugfix'))
                if cfg.get('security'):
                    filters.append(base.sack.query().upgrades().filter(advisory_type__eq='security'))
                if filters:
                    base._update_security_filters = filters

            state = cfg.get('state') or 'installed'
            update_only = cfg.get('update_only', False)
            allow_downgrade = cfg.get('allow_downgrade', False)
            download_only = cfg.get('download_only', False)
            names = cfg.get('names', [])
            response_results = []

            if names == ['*'] and state == 'latest':
                base.upgrade_all()
                return _transaction_results(base, response_results, base.resolve(allow_erasing=False), download_only)

            pkg_specs, grp_specs, filenames = _parse_spec_group_file(base, names, update_only)
            pkg_specs = [p.strip() for p in pkg_specs]
            filenames = [f.strip() for f in filenames]
            groups = []
            environments = []
            for group_spec in (g.strip() for g in grp_specs):
                group = base.comps.group_by_pattern(group_spec)
                if group:
                    groups.append(group.id)
                else:
                    environment = base.comps.environment_by_pattern(group_spec)
                    if environment:
                        environments.append(environment.id)
                    else:
                        raise RuntimeError('No group %s available.' % group_spec)

            if state in ('installed', 'present'):
                if filenames:
                    _install_remote_rpms_helper(base, filenames, update_only, allow_downgrade)
                    for filename in filenames:
                        response_results.append('Installed %s' % filename)
                for group in groups:
                    count = base.group_install(group, dnf.const.GROUP_PACKAGE_TYPES)
                    if count == 0:
                        response_results.append('Group %s already installed.' % group)
                    else:
                        response_results.append('Group %s installed.' % group)
                for environment in environments:
                    base.environment_install(environment, dnf.const.GROUP_PACKAGE_TYPES)
                if update_only:
                    for pkg in _update_only_helper(base, pkg_specs):
                        response_results.append('Packages providing %s not installed due to update_only specified' % pkg)
                else:
                    for pkg_spec in pkg_specs:
                        install_result = _mark_package_install(base, pkg_spec, False, allow_downgrade)
                        if not install_result['failed'] and install_result['msg']:
                            response_results.append(install_result['msg'])
            elif state == 'latest':
                if filenames:
                    _install_remote_rpms_helper(base, filenames, update_only, allow_downgrade)
                    for filename in filenames:
                        response_results.append('Installed %s' % filename)
                for group in groups:
                    try:
                        base.group_upgrade(group)
                        response_results.append('Group %s upgraded.' % group)
                    except dnf.exceptions.CompsError:
                        count = base.group_install(group, dnf.const.GROUP_PACKAGE_TYPES)
                        if count == 0:
                            response_results.append('Group %s already installed.' % group)
                        else:
                            response_results.append('Group %s installed.' % group)
                for environment in environments:
                    try:
                        base.environment_upgrade(environment)
                    except dnf.exceptions.CompsError:
                        base.environment_install(environment, dnf.const.GROUP_PACKAGE_TYPES)
                if update_only:
                    for pkg in _update_only_helper(base, pkg_specs):
                        response_results.append('Packages providing %s not installed due to update_only specified' % pkg)
                else:
                    for pkg_spec in pkg_specs:
                        install_result = _mark_package_install(base, pkg_spec, True, allow_downgrade)
                        if not install_result['failed'] and install_result['msg']:
                            response_results.append(install_result['msg'])
            else:
                raise RuntimeError('state %s has no install transaction' % state)

            return _transaction_results(base, response_results, base.resolve(allow_erasing=False), download_only)

        try:
            print(json.dumps({'results': main()}))
        except Exception as exc:
            print(json.dumps({'error': str(exc)}))
        PYTHON

      # The `results` entries Ansible's dnf module would carry on its
      # "Failed to install some of the specified packages" fail_json for
      # THIS request - empty when the probe cannot answer (no python
      # dnf bindings on the target, a goal this port cannot mirror),
      # which keeps the caller's historical results [] shape.
      def dnf_transaction_probe_results(names : Array(String)) : Array(String)
        return [] of String unless transaction_probe_dnf4?
        config = dnf_transaction_probe_config(names)
        payload = Base64.strict_encode(config.to_json)
        program = "import base64,json\ncfg=json.loads(base64.b64decode('#{payload}').decode())\n" + PROBE_PROGRAM
        # base64 keeps the -c script free of quotes/metacharacters of its
        # own: it rides through remote_exec's shell path untouched.
        wrapped = "import base64;exec(base64.b64decode(\"#{Base64.strict_encode(program)}\"))"
        PROBE_INTERPRETERS.each do |interpreter|
          result = remote_exec("#{interpreter} -c '#{wrapped}'")
          parsed = parse_probe_output(result[:stdout])
          return parsed if parsed
        end
        [] of String
      end

      # dnf5's module resolves through libdnf5 and reports ITS OWN
      # results shapes (plugins/dnf5.cr), so the dnf4 replay above must
      # not answer for that backend even on a host where the dnf4
      # bindings happen to be importable too. Overridden in
      # plugins/dnf5.cr.
      private def transaction_probe_dnf4? : Bool
        true
      end

      # The module's own request/options as the embedded script sees
      # them - state defaults to "installed" exactly like dnf.py's run()
      # does when the task omits it.
      private def dnf_transaction_probe_config(names : Array(String)) : Hash(String, JSON::Any)
        config = {
          "names"             => JSON::Any.new(names.map { |name| JSON::Any.new(name) }),
          "state"             => JSON::Any.new(@params["state"]? || "installed"),
          "update_only"       => JSON::Any.new(true?(@params["update_only"]?)),
          "allow_downgrade"   => JSON::Any.new(true?(@params["allow_downgrade"]?)),
          "download_only"     => JSON::Any.new(true?(@params["download_only"]?)),
          "download_dir"      => JSON::Any.new(@params["download_dir"]?),
          "conf_file"         => JSON::Any.new(@params["conf_file"]?),
          "installroot"       => JSON::Any.new(@params["installroot"]? || "/"),
          "releasever"        => JSON::Any.new(@params["releasever"]?),
          "disable_gpg_check" => JSON::Any.new(true?(@params["disable_gpg_check"]?)),
          "sslverify"         => JSON::Any.new(!false?(@params["sslverify"]?)),
          "enablerepo"        => param_list("enablerepo"),
          "disablerepo"       => param_list("disablerepo"),
          "exclude"           => param_list("exclude"),
          "disable_excludes"  => JSON::Any.new(@params["disable_excludes"]?),
          "skip_broken"       => JSON::Any.new(true?(@params["skip_broken"]?)),
          "nobest"            => tri_state_param("nobest"),
          "best"              => tri_state_param("best"),
          "cacheonly"         => JSON::Any.new(true?(@params["cacheonly"]?)),
          "install_weak_deps" => JSON::Any.new(!false?(@params["install_weak_deps"]?)),
          "autoremove"        => JSON::Any.new(true?(@params["autoremove"]?)),
          "security"          => JSON::Any.new(true?(@params["security"]?)),
          "bugfix"            => JSON::Any.new(true?(@params["bugfix"]?)),
          "disable_plugin"    => param_list("disable_plugin"),
          "enable_plugin"     => param_list("enable_plugin"),
        } of String => JSON::Any
        config
      end

      # A list-shaped option as yumdnf's argument spec accepts it: a
      # JSON array or a comma-separated string (build_dnf_options'
      # enablerepo parsing), else empty.
      private def param_list(key : String) : JSON::Any
        raw = @params[key]?
        return JSON::Any.new([] of JSON::Any) unless raw
        begin
          if parsed = JSON.parse(raw).as_a?
            return JSON::Any.new(parsed)
          end
        rescue
        end
        JSON::Any.new(raw.split(",").reject(&.strip.empty?).map { |entry| JSON::Any.new(entry.strip) })
      end

      # nobest/best are tri-state in the module (unset keeps the distro
      # default; only an explicit value forces conf.best) - absent is
      # Python None, never False.
      private def tri_state_param(key : String) : JSON::Any
        raw = @params[key]?
        return JSON::Any.new(nil) unless raw
        JSON::Any.new(true?(raw))
      end

      # A probe that ran prints exactly one JSON object: {"results": [...]}
      # on an answer, {"error": ...} when the goal is not answerable.
      # Anything else (no output at all, a traceback) means THIS
      # interpreter could not run the probe - try the next one.
      private def parse_probe_output(stdout : String) : Array(String)?
        parsed = JSON.parse(stdout.strip.lines.last? || "")
        return nil unless parsed.as_h?
        if error = parsed["error"]?
          return nil unless error.as_s?
          return [] of String
        end
        results = parsed["results"]?.try(&.as_a?) || return nil
        results.map(&.as_s)
      rescue JSON::ParseException
        nil
      end
    end
  end
end
