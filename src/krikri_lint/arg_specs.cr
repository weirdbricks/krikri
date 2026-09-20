require "json"

module Krikri
  module Lint
    # Upstream parity: ansible-lint's args[module] (severity VERY_LOW,
    # tags core/warning in practice; reports as warning). Validates task
    # params against per-module argument specs, mirroring Ansible's
    # argspec validation messages. Only core (ansible.builtin) modules
    # get specs here - community modules are outside krikri's coverage
    # bar (see CLAUDE.md), and upstream's choices ordering is unstable
    # between runs anyway (Python hash randomization).
    module ArgSpecs
      record Spec,
        params : Array(String),
        aliases : Hash(String, Array(String)),
        required : Array(String),
        required_one_of : Array(Array(String)),
        required_together : Array(Array(String)),
        required_by : Hash(String, Array(String)),
        choices : Hash(String, Array(String)),
        list_choices : Hash(String, Array(String)),
        booleans : Array(String),
        # required_if entries: (param, value) => need any/all of `needed`.
        required_if : Array(RequiredIf),
        # Module-init-time defaults applied by AnsibleModule before
        # validation (only the ones required_if depends on).
        defaults : Hash(String, String)

      record RequiredIf,
        param : String,
        value : String,
        needed : Array(String),
        any : Bool

      private def self.spec(params, aliases = {} of String => Array(String),
                            required = [] of String,
                            required_one_of = [] of Array(String),
                            required_by = {} of String => Array(String),
                            choices = {} of String => Array(String),
                            list_choices = {} of String => Array(String),
                            booleans = [] of String,
                            required_together = [] of Array(String),
                            required_if = [] of RequiredIf,
                            defaults = {} of String => String)
        Spec.new(params, aliases, required, required_one_of,
          required_together, required_by, choices, list_choices, booleans,
          required_if, defaults)
      end

      DB = {
        "apt" => spec(
          params: %w[allow_change_held_packages allow_downgrade allow_unauthenticated auto_install_module_deps autoclean autoremove cache_valid_time clean deb default_release dpkg_options fail_on_autoremove force force_apt_get install_recommends lock_timeout only_upgrade package policy_rc_d purge state update_cache update_cache_retries update_cache_retry_max_delay upgrade],
          aliases: {"package" => ["name", "pkg"], "default_release" => ["default-release"], "install_recommends" => ["install-recommends"], "allow_downgrade" => ["allow-downgrade", "allow_downgrades", "allow-downgrades"], "allow_unauthenticated" => ["allow-unauthenticated"], "update_cache" => ["update-cache"]},
          choices: {"state" => %w[absent build-dep fixed latest present], "upgrade" => %w[dist full no safe yes]},
          booleans: %w[allow_change_held_packages allow_downgrade allow_unauthenticated auto_install_module_deps autoclean autoremove clean fail_on_autoremove force force_apt_get install_recommends only_upgrade purge update_cache],
        ),
        "apt_key" => spec(
          params: %w[data file id key keyring keyserver state url validate_certs],
          choices: {"state" => %w[absent present]},
          booleans: %w[validate_certs],
        ),
        "cron" => spec(
          params: %w[backup cron_file day disabled env hour insertafter insertbefore job minute month name special_time state user weekday],
          required: %w[name],
          choices: {"special_time" => %w[annually daily hourly monthly reboot weekly yearly], "state" => %w[present absent]},
          booleans: %w[backup disabled env],
          aliases: {"day" => ["dom"], "job" => ["value"], "weekday" => ["dow"]},
        ),
        "cronvar" => spec(
          params: %w[backup cron_file insertafter insertbefore name state user value],
          required: %w[name],
          choices: {"state" => %w[absent present]},
          booleans: %w[backup],
        ),
        "deb822_repository" => spec(
          params: %w[allow_downgrade_to_insecure allow_insecure allow_weak architectures by_hash check_date check_valid_until components date_max_future enabled inrelease_path languages mode name pdiffs signed_by state suites targets trusted types uris],
          required: %w[name],
          choices: {"state" => %w[absent present]},
          list_choices: {"types" => %w[deb deb-src]},
          booleans: %w[allow_downgrade_to_insecure allow_insecure allow_weak by_hash check_date check_valid_until enabled pdiffs trusted],
        ),
        "debconf" => spec(
          params: %w[name question unseen value vtype],
          required: %w[name],
          required_together: [%w[question vtype value]],
          choices: {"vtype" => %w[boolean error multiselect note password seen select string text title]},
          booleans: %w[unseen],
          aliases: {"name" => ["pkg"], "question" => ["selection", "setting"], "value" => ["answer"]},
        ),
        "dpkg_selections" => spec(
          params: %w[name selection],
          required: %w[name selection],
          choices: {"selection" => %w[install hold deinstall purge]},
        ),
        "expect" => spec(
          params: %w[chdir command creates echo removes responses timeout],
          required: %w[command responses],
          booleans: %w[echo],
        ),
        "getent" => spec(
          params: %w[database fail_key key service split],
          required: %w[database],
          booleans: %w[fail_key],
        ),
        "git" => spec(
          params: %w[accept_hostkey accept_newhostkey archive archive_prefix bare clone depth dest executable force gpg_allowlist key_file recursive reference refspec remote repo separate_git_dir single_branch ssh_opts track_submodules umask update verify_commit version],
          aliases: {"gpg_allowlist" => ["gpg_whitelist"], "repo" => ["name"]},
          required: %w[dest repo],
          booleans: %w[accept_hostkey accept_newhostkey bare clone force recursive single_branch track_submodules update verify_commit],
        ),
        "known_hosts" => spec(
          params: %w[hash_host key name path state],
          required: %w[name],
          choices: {"state" => %w[absent present]},
          booleans: %w[hash_host],
          aliases: {"name" => ["host"]},
        ),
        "package_facts" => spec(
          # manager is not validated by upstream (its choices check never
          # runs through the mocked AnsibleModule init), so no choices here.
          params: %w[manager strategy],
          choices: {"strategy" => %w[first all]},
        ),
        "pip" => spec(
          params: %w[break_system_packages chdir editable executable extra_args name requirements state umask version virtualenv virtualenv_command virtualenv_python virtualenv_site_packages],
          required_one_of: [%w[name requirements]],
          choices: {"state" => %w[absent forcereinstall latest present]},
          booleans: %w[break_system_packages editable virtualenv_site_packages],
        ),
        "replace" => spec(
          params: %w[after attributes backup before encoding group mode owner path regexp replace selevel serole setype seuser unsafe_writes validate],
          aliases: {"path" => ["dest", "destfile", "name"], "attributes" => ["attr"]},
          required: %w[path regexp],
          booleans: %w[backup unsafe_writes],
        ),
        "rpm_key" => spec(
          params: %w[fingerprint key state validate_certs],
          required: %w[key],
          choices: {"state" => %w[absent present]},
          booleans: %w[validate_certs],
        ),
        "subversion" => spec(
          params: %w[checkout dest executable export force in_place password repo revision switch update username validate_certs],
          aliases: {"repo" => ["name", "repository"], "revision" => ["rev", "version"]},
          required: %w[repo],
          booleans: %w[checkout export force in_place switch update validate_certs],
        ),
        "systemd" => spec(
          params: %w[daemon_reexec daemon_reload enabled force masked name no_block scope state],
          required_by: {"state" => %w[name], "enabled" => %w[name], "masked" => %w[name]},
          choices: {"scope" => %w[system user global], "state" => %w[reloaded restarted started stopped]},
          booleans: %w[daemon_reexec daemon_reload enabled force masked no_block],
          aliases: {"daemon_reexec" => ["daemon-reexec"], "daemon_reload" => ["daemon-reload"], "name" => ["service", "unit"]},
        ),
        "tempfile" => spec(
          params: %w[path prefix state suffix],
          choices: {"state" => %w[file directory]},
        ),
        "yum_repository" => spec(
          params: %w[async attributes bandwidth baseurl cost countme deltarpm_metadata_percentage deltarpm_percentage description enabled enablegroups exclude failovermethod file gpgcakey gpgcheck gpgkey group http_caching include includepkgs ip_resolve keepalive keepcache metadata_expire metadata_expire_filter metalink mirrorlist mirrorlist_expire mode module_hotfixes name owner password priority protect proxy proxy_password proxy_username repo_gpgcheck reposdir retries s3_enabled selevel serole setype seuser skip_if_unavailable ssl_check_cert_permissions sslcacert sslclientcert sslclientkey sslverify state throttle timeout ui_repoid_vars unsafe_writes username],
          aliases: {"attributes" => ["attr"], "sslcacert" => ["ca_cert"], "sslclientcert" => ["client_cert"], "sslclientkey" => ["client_key"], "exclude" => ["excludepkgs"], "sslverify" => ["validate_certs"]},
          required: %w[name],
          required_if: [
            RequiredIf.new("state", "present", %w[baseurl mirrorlist metalink], true),
            RequiredIf.new("state", "present", %w[description], false),
          ],
          defaults: {"state" => "present"},
          choices: {"failovermethod" => %w[roundrobin priority], "http_caching" => %w[all packages none], "ip_resolve" => %w[4 6 IPv4 IPv6 whatever], "keepcache" => %w[0 1], "metadata_expire_filter" => %w[never read-only:past read-only:present read-only:future], "state" => %w[present absent]},
          booleans: %w[async countme enabled enablegroups gpgcheck keepalive module_hotfixes protect repo_gpgcheck s3_enabled skip_if_unavailable ssl_check_cert_permissions sslverify unsafe_writes],
        ),
      }

      # bare names for the same modules when written without FQCN
      def self.find(module_name : String) : Spec?
        bare = module_name.sub("ansible.builtin.", "").sub("ansible.legacy.", "")
        DB[bare]?
      end
    end
  end
end
