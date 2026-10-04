module Krikri
  class PlaybookParser
    # Legacy action-directive keywords (`action:`/`local_action:` and
    # their FQCN spellings) - parsed as free-form module directives, not
    # module names (see parse_task). Deliberately NOT in SPECIAL_KEYS:
    # they have to be captured as the task's module key to be rewritten.
    ACTION_DIRECTIVE_KEYS = Set{
      "action", "ansible.builtin.action", "ansible.legacy.action",
      "local_action", "ansible.builtin.local_action", "ansible.legacy.local_action",
    }

    # List of available (implemented) plugins - using FQCN. Almost all of
    # these are ansible.builtin.* (bundled with ansible-core); two
    # exceptions verified against a real ansible-core install (not
    # assumed): authorized_key lives in the separate ansible.posix
    # collection, and archive/unarchive live in community.general - neither
    # ships with ansible-core itself.
    # A Set, not an Array: this is membership-tested once per task in
    # parse_task and again per task in validate, and a linear scan of 44
    # entries is the wrong shape for a lookup table even where the cost
    # is unmeasurable.
    AVAILABLE_PLUGINS = Set{
      "ansible.builtin.copy",
      "ansible.builtin.template",
      "ansible.builtin.file",
      "ansible.builtin.lineinfile",
      "ansible.builtin.replace",
      "ansible.builtin.service",
      "ansible.builtin.systemd",
      "ansible.builtin.hostname",
      "ansible.builtin.shell",
      "ansible.builtin.apt",
      "ansible.builtin.dnf",
      # dnf5 (0.9.1279): the libdnf5-backed successor to dnf, added as a
      # distinct ansible.builtin module in ansible-core 2.19. Shares
      # yumdnf_argument_spec with dnf but no backend-selection option, so
      # it gets its own plugin rather than a use_backend branch (see
      # plugins/dnf5.cr).
      "ansible.builtin.dnf5",
      "ansible.builtin.yum",
      "ansible.builtin.package",
      "ansible.builtin.debug",
      "ansible.builtin.command",
      "ansible.builtin.setup",
      # gather_facts (0.9.1351): real Ansible also lets `gather_facts`
      # be invoked as an ordinary task action (it delegates to setup
      # with the task's gather_subset/gather_timeout/fact_path/filter)
      # - useful for re-gathering mid-play or gathering with different
      # subsets than the play-level keyword used. krikri only ever
      # implemented the play-level `gather_facts:` setting, so a direct
      # task was skipped and the run exited rc=4 with "unavailable
      # modules" (found by krikri-playbook-generator, seed 42).
      # Registered as its own FQCN with its own plugin binary (same
      # FactsGatherer body as setup) rather than a MODULE_ALIASES entry,
      # so the task's _module_name echoes the invoked spelling and the
      # registry cross-check spec's binary pairing stays uniform. See
      # plugins/gather_facts.cr.
      "ansible.builtin.gather_facts",
      # facts: - the binary exists (plugins/facts.cr, built and uploaded
      # by plugin_manager's own facts-gathering path) but had no entry
      # here, so a role writing `facts:` directly was silently dropped
      # as "Plugin not available" even though setup: worked (real
      # Ansible treats facts as setup's alias). Found by the registry
      # cross-check spec, not a live round.
      "ansible.builtin.facts",
      "ansible.builtin.package_facts",
      # mount_facts (0.9.1279): the ansible-core 2.18 successor to setup's
      # ansible_mounts, returning mount_points/aggregate_mounts from a
      # configurable source list. A distinct callable module from setup,
      # so it needs its own registration (see plugins/mount_facts.cr).
      "ansible.builtin.mount_facts",
      "ansible.posix.selinux",
      # synchronize (0.9.916): rsync-wrapper module, real Ansible's most
      # common way to move files between hosts. Controller-side by nature
      # (see SynchronizeActionPlugin's own comment) - listed here plus
      # plugins/synchronize.cr/binary so the task isn't dropped at parse
      # time and the registry cross-check spec stays consistent.
      "ansible.posix.synchronize",
      "community.general.pam_limits",
      "community.general.apache2_module",
      "community.general.capabilities",
      "community.general.make",
      "ansible.builtin.user",
      "ansible.builtin.group",
      "ansible.builtin.git",
      "ansible.builtin.pip",
      # community.general, not ansible.builtin - real Ansible's own gem
      # module has always lived in that collection, never ansible-core.
      # Registered under the wrong namespace before, so a role writing
      # the (correct, and far more common in practice) fully-qualified
      # `community.general.gem:` form - as opposed to the bare `gem:`
      # short name, which happened to still resolve via
      # MODULE_SEARCH_COLLECTIONS regardless of which FQCN this was
      # registered under - got "Plugin not available" and the whole
      # task silently dropped, even though plugins/gem.cr is a real,
      # working plugin. Found via robertdebock.travis's own "install
      # travis" task (`community.general.gem: {name: travis, ...}`).
      "community.general.gem",
      "ansible.builtin.cron",
      # cronvar lives in community.general, not ansible-core - real
      # ansible-core's own ansible_builtin_runtime.yml redirects the
      # legacy `ansible.builtin.cronvar` spelling to it (so the built-in
      # spelling below stays registered), but the CANONICAL FQCN every
      # role and generator writes is community.general.cronvar. That was
      # missing here, so every such task was dropped as "Plugin not
      # available" and reported as a silent `skipping:` (kpg32 seed-32:
      # 15/15 cronvar playbooks, 0/15 matching, because the task never
      # ran at all). Both spellings resolve to the same cronvar binary.
      "community.general.cronvar",
      "ansible.builtin.cronvar",
      "ansible.posix.acl",
      # ansible.builtin.acl (0.9.1119): same legacy-redirect shape as
      # ansible.builtin.mount below - acl lives in ansible.posix, and
      # real ansible-core's own ansible_builtin_runtime.yml transparently
      # redirects the ansible.builtin. spelling, so a task written with
      # the builtin FQCN must reach the same plugin instead of being
      # dropped as "Plugin not available". Both spellings registered;
      # get_local_plugin_path strips both prefixes to the same binary.
      "ansible.builtin.acl",
      "ansible.posix.authorized_key",
      # ansible.builtin.authorized_key (0.9.941): real ansible-core ships a
      # legacy redirect so the historically-core `authorized_key` module
      # still resolves under `ansible.builtin.` even though the actual
      # implementation moved to ansible.posix years ago - the
      # ome.local_accounts round (400072) hard-stopped on the builtin
      # spelling while real ansible-playbook ran it fine. Both spellings
      # are registered; simple_plugin_name strips both prefixes to the
      # same `authorized_key` plugin binary.
      "ansible.builtin.authorized_key",
      "ansible.builtin.stat",
      "ansible.builtin.find",
      "ansible.builtin.getent",
      "community.general.archive",
      "ansible.builtin.unarchive",
      "ansible.builtin.yum_repository",
      "ansible.builtin.apt_repository",
      "ansible.builtin.apt_key",
      "ansible.builtin.rpm_key",
      "ansible.posix.seboolean",
      "community.general.seport",
      # sefcontext (0.9.955): persistent SELinux file-context mapping via
      # `semanage fcontext` (ansible-lockdown rhel8_stig round 410191
      # hard-stopped on the FQCN spelling). See plugins/sefcontext.cr.
      "community.general.sefcontext",
      # community.general.xml (0.9.958): xpath-based XML file editor
      # (alvistack/buluma Atlassian-stack roles hard-stopped on the FQCN
      # spelling - 6 distinct roles in the tested corpus, and public
      # GitHub code search shows ~4.5x the usage of ini_file). Bare `xml:`
      # resolves via MODULE_SEARCH_COLLECTIONS. See plugins/xml.cr.
      "community.general.xml",
      "ansible.builtin.deb822_repository",
      "ansible.posix.mount",
      # ansible.builtin.mount (round 601105, Appsilon.mount_efs): mount
      # moved out of ansible-core into ansible.posix years ago, and real
      # ansible-core's own ansible_builtin_runtime.yml transparently
      # redirects the old core FQCN to ansible.posix.mount on every
      # current controller - krikri had no equivalent alias, so a task
      # spelling out the legacy name hard-stopped even though the
      # plugin (mount.cr) is fully implemented under the other FQCN.
      # Same fix shape as ansible.builtin.authorized_key above.
      "ansible.builtin.mount",
      "ansible.posix.sysctl",
      "community.general.ufw",
      "ansible.posix.firewalld",
      "ansible.builtin.iptables",
      "ansible.builtin.debconf",
      "ansible.builtin.async_status",
      "community.docker.docker_image",
      "community.docker.docker_network",
      "community.docker.docker_network_info",
      "community.docker.docker_container",
      # KNOWN_MISSING's former "unimplemented collection modules" entry
      # (mrlesmithjr.blocky): docker_compose_v2 drives the `docker
      # compose` v2 CLI - see plugins/docker_compose_v2.cr.
      "community.docker.docker_compose_v2",
      "community.mysql.mysql_db",
      "community.mysql.mysql_user",
      "community.mysql.mysql_info",
      "community.mysql.mysql_query",
      # dev-sec's own mysql_hardening role writes every mysql module
      # under this FQCN instead of community.mysql.* - a real, distinct
      # collection namespace (not a typo in this repo), so both need
      # their own AVAILABLE_PLUGINS entries; get_local_plugin_path's own
      # FQCN-stripping regex strips both prefixes down to the same
      # plugin binary names.
      "ansible.mysql.mysql_db",
      "ansible.mysql.mysql_user",
      "ansible.mysql.mysql_info",
      "ansible.mysql.mysql_query",
      "community.postgresql.postgresql_db",
      "community.postgresql.postgresql_user",
      "community.postgresql.postgresql_privs",
      # postgresql_query (0.9.956): arbitrary SQL over the same
      # crystal-pg wire-protocol connection as the rest of the
      # collection (consensys.web3signer round 400078 hard-stopped on
      # the bare `postgresql_query:` spelling). See
      # plugins/postgresql_query.cr.
      "community.postgresql.postgresql_query",
      "community.crypto.openssl_dhparam",
      "community.crypto.openssl_privatekey",
      "community.crypto.openssl_csr",
      "community.crypto.x509_certificate",
      "community.crypto.openssl_pkcs12",
      "community.crypto.openssh_keypair",
      # The read-only/generator half of the collection - the *_info
      # modules and get_certificate were called out as "cheap if a role
      # ever needs them" in KNOWN_MISSING.md; openssl_publickey is the
      # one generator module that completes the key-generation family.
      "community.crypto.openssl_privatekey_info",
      "community.crypto.x509_certificate_info",
      "community.crypto.openssl_publickey_info",
      "community.crypto.openssl_csr_info",
      "community.crypto.openssl_publickey",
      "community.crypto.get_certificate",
      "community.general.modprobe",
      # kernel_blacklist (0.9.951): `blacklist <module>` entry management
      # in /etc/modprobe.d/ (grycap.im round 410111 hard-stopped on it
      # where real ansible-playbook ran 844s of the role cleanly). Pure
      # file editing - see plugins/kernel_blacklist.cr.
      "community.general.kernel_blacklist",
      "community.general.pamd",
      "community.general.htpasswd",
      "community.general.ini_file",
      "community.general.timezone",
      # ansible.builtin.timezone (round 601463, jtprogru.configure_timesyncd):
      # same legacy-core-FQCN redirect story as ansible.builtin.mount
      # above - timezone moved to community.general years ago and real
      # ansible-core still redirects the old core spelling to it.
      "ansible.builtin.timezone",
      "community.general.npm",
      "community.general.alternatives",
      # ansible.builtin.alternatives (round 601430, T2L.php): same
      # legacy-core-FQCN redirect story as ansible.builtin.mount above -
      # alternatives moved to community.general years ago and real
      # ansible-core still redirects the old core spelling to it.
      "ansible.builtin.alternatives",
      "community.general.filesystem",
      # zfs (0.9.952): ZFS dataset/volume/snapshot management via the
      # `zfs` CLI (micxer.zfs round 400133 hard-stopped on the bare
      # `zfs:` spelling). See plugins/zfs.cr.
      "community.general.zfs",
      # lvol (0.9.929): LVM logical volume management, one native port
      # registered under both FQCNs seen in the wild - real roles write
      # both spellings (ansible.builtin.lvol in ome.lvm_partition,
      # community.general.lvol in ome.docker, same module either way),
      # and simple_plugin_name strips both namespaces to the same
      # `lvol` plugin binary.
      "ansible.builtin.lvol",
      "community.general.lvol",
      # parted/lvg (0.9.1151): disk partition and LVM volume-group
      # management from the round-811000 open-gaps list (liksi.
      # mount_data_disk wrote bare `parted:`/`lvg:`; community.general
      # is already in MODULE_SEARCH_COLLECTIONS so the bare spellings
      # resolve). See plugins/parted.cr and plugins/lvg.cr.
      "community.general.parted",
      "community.general.lvg",
      # snap/deploy_helper (0.9.1151): snap package management
      # (mircomasa.microk8s, racqspace.microk8s) and the
      # capistrano-style release-directory module (f500.project_deploy).
      # See plugins/snap.cr and plugins/deploy_helper.cr.
      "community.general.snap",
      "community.general.deploy_helper",
      # dpkg_divert (0.9.929): Debian file-diversion management
      # (ansible-lockdown ubuntu24 CIS and MindPointGroup debian11 CIS
      # rounds both hard-stopped on it). Debian-family only by nature -
      # the plugin's dpkg-divert --version probe fails cleanly elsewhere.
      "community.general.dpkg_divert",
      # locale_gen (0.9.931): Debian/Ubuntu locale generation
      # (Oefenweb.locales round 210720 hard-stopped on it). Drives
      # /etc/locale.gen + locale-gen on the target.
      "community.general.locale_gen",
      # java_cert (0.9.931): Java keystore certificate management via
      # keytool (no live round found - implemented from the real
      # module's semantics, digest-compare import included).
      "community.general.java_cert",
      # virt_net (0.9.954): libvirt network management via the virsh CLI
      # (mattgeddes.libvirt_kvm round 410102 and ovirt.hosted_engine_setup
      # round 410038 both hard-stopped on the bare `virt_net:` spelling).
      # Registered bare - community.libvirt is not in simple_plugin_name's
      # strip list - with the FQCN spelling mapped through MODULE_ALIASES.
      "virt_net",
      # maven_artifact (0.9.934): Maven artifact download
      # (lean_delivery.jmeter round 210778 hard-stopped on it).
      "community.general.maven_artifact",
      # nsupdate (0.9.936): RFC2136 dynamic-DNS record management -
      # native wire-format + TSIG port (no dnspython); talks to a real
      # DNS server, so only the parameter-validation failures are
      # unit-spec'd.
      "community.general.nsupdate",
      # easy_install (0.9.941): legacy Python library installs via
      # easy_install, virtualenv support included (cchurch.virtualenv
      # round 300033 calls it). install-only by nature - the real module
      # has no absent state either.
      "community.general.easy_install",
      # mysql_variables (0.9.942): MySQL/MariaDB global variable query/
      # set over the wire protocol, same shared connection path as the
      # other community.mysql plugins (Oefenweb.percona_server round
      # 310090 calls it). The FQCN-stripping regex already maps both
      # community.mysql. and ansible.mysql. spellings to the binary.
      "community.mysql.mysql_variables",
      # docker_login (0.9.943): registry authentication stored in the
      # docker CLI config file (oasis_roles.molecule_docker_ci round
      # 300108 calls it). Credential validation/storage goes through the
      # docker CLI's own login; the idempotent no-op and state=absent
      # erase are pure config.json handling.
      "community.docker.docker_login",
      # current_container_facts (0.9.945): in-container detection fact
      # module (collivier.xtesting round 300010 calls it) - reads
      # /proc/self/cpuset + /proc/self/mountinfo wherever the plugin
      # process runs and sets the ansible_module_container_* facts.
      "community.docker.current_container_facts",
      # podman_image (0.9.946): podman image pull/remove (ikke_t
      # .podman_container_systemd round 300134 pulls through it).
      # containers.podman needed its own prefix strip in
      # PluginManager.simple_plugin_name - it's not one of the
      # collection-search namespaces below.
      "containers.podman.podman_image",
      # iam_user_info (0.9.947): IAM user lookup over the signed Query
      # API (deekayen.iam_access_simulation round 300141 calls it) - the
      # same direct-API contract as the ec2_* cluster, via its own
      # plugin_helpers/iam_api.cr (iam.amazonaws.com, Version
      # 2010-05-08, service "iam" - not EC2's host/version). No plugins/
      # EC2-API-compatible region logic: IAM is a global service.
      "amazon.aws.iam_user_info",
      "iam_user_info",
      "ansible.builtin.service_facts",
      "ansible.builtin.slurp",
      # No plugins/reboot.cr - handled entirely on the controller by
      # TaskExecutor#execute_reboot (see that method's own comment for
      # why: unlike every other module, its process can't run ON the
      # target, since the target is about to reboot out from under it).
      # Listed here only so a reboot: task isn't silently dropped at
      # parse time as "Plugin not available".
      "ansible.builtin.reboot",
      "ansible.builtin.set_fact",
      # add_host (0.9.960): controller-only action plugin that mutates the
      # run's shared in-memory inventory (like group_by:/set_stats: below,
      # there is NO plugins/add_host.cr - real Ansible's own add_host has
      # no target-side module either, so there is nothing to execute on a
      # target). Listed here so the task isn't silently dropped at parse
      # time as "Plugin not available"; see AddHostActionPlugin.
      "ansible.builtin.add_host",
      "ansible.builtin.get_url",
      "ansible.builtin.blockinfile",
      "ansible.builtin.uri",
      "ansible.builtin.assert",
      "ansible.builtin.fail",
      "ansible.builtin.wait_for",
      "ansible.builtin.wait_for_connection",
      "ansible.builtin.ping",
      "ansible.builtin.fetch",
      "ansible.builtin.pause",
      "ansible.builtin.script",
      "ansible.builtin.assemble",
      "ansible.builtin.tempfile",
      "ansible.builtin.known_hosts",
      # group_by:/set_stats: - no plugins/*.cr binary at all, same as
      # ansible.builtin.reboot above (see TaskExecutor#execute_group_by/
      # #execute_set_stats's own comments for why - both are handled
      # entirely controller-side). Listed here only so the task isn't
      # silently dropped at parse time as "Plugin not available".
      "ansible.builtin.group_by",
      "ansible.builtin.set_stats",
      "ansible.builtin.dpkg_selections",
      "ansible.builtin.subversion",
      "ansible.builtin.expect",
      "community.general.git_config",
      # gantsign.git_credential_manager calls it with the ansible.builtin.
      # prefix (round 191: rc=4 "unavailable modules" despite the plugin
      # existing since 0.9.489 under its community.general name) -
      # simple_plugin_name strips both namespaces to the same binary.
      "ansible.builtin.git_config",
      "community.general.sudoers",
      "community.general.dnf_versionlock",
      # yum_versionlock (the yum-era sibling of dnf_versionlock above):
      # add/delete package locks via the yum-plugin-versionlock package.
      # Registered bare alongside the FQCN - simple_plugin_name strips
      # both spellings to the same `yum_versionlock` binary (and the bare
      # spelling would also resolve through MODULE_SEARCH_COLLECTIONS'
      # community.general entry, as dnf_versionlock's does).
      "yum_versionlock",
      "community.general.yum_versionlock",
      "community.docker.docker_image_build",
      "amazon.aws.ec2_metadata_facts",
      # amazon.aws EC2 management modules (the signed-Query-API cluster
      # sharing src/krikri/plugin_helpers/ec2_api.cr): ec2_key,
      # ec2_security_group, the lifecycle module ec2_instance (via
      # plugin_helpers/ec2_instance.cr), and the three read-only lookups
      # (ec2_vpc_subnet_info/ec2_vpc_net_info/ec2_ami_info via
      # plugin_helpers/ec2_info.cr) - the whole cluster is now in.
      # Bare short names are listed alongside the FQCNs because
      # roles write `ec2_key:` unqualified far more often than fully
      # qualified, and amazon.aws is not in MODULE_SEARCH_COLLECTIONS
      # (real Ansible resolves bare AWS module names through its own
      # auto-aliasing, not collection search).
      "amazon.aws.ec2_key",
      "amazon.aws.ec2_security_group",
      "amazon.aws.ec2_instance",
      "amazon.aws.ec2_vpc_subnet_info",
      "amazon.aws.ec2_vpc_net_info",
      "amazon.aws.ec2_ami_info",
      "ec2_key",
      "ec2_security_group",
      "ec2_instance",
      "ec2_vpc_subnet_info",
      "ec2_vpc_net_info",
      "ec2_ami_info",
      # round 196: native ports of the collection modules the corpus
      # actually calls (previously rc=4 "unavailable modules" where real
      # ansible ran them - mrlesmithjr.rabbitmq and linux-system-roles.rhc).
      "community.rabbitmq.rabbitmq_plugin",
      "community.rabbitmq.rabbitmq_user",
      # The arbitrary-Python-module runner's internal dispatch name -
      # NOT a module real playbooks call. A task whose module resolves
      # to nothing keeps the graceful unavailable_module path (since
      # 0.9.1050 - see the parse_task call site); when the executor's
      # PythonModuleRunner.find_source finds a role-private
      # `library/<name>.py` source for it, TaskExecutor dispatches it
      # to the py_module plugin with the source embedded, running it
      # on the target with the target's own python3 - see
      # PythonModuleRunner's own comment.
      "ansible.builtin.py_module",
    }

    # The collections a bare (non-FQCN) module name resolves against, in
    # real Ansible's own default search order - `getent:` (no `ansible.
    # builtin.` prefix) is extremely common in real-world playbooks/roles
    # (dev-sec's own molecule test fixtures use it, unlike the role's own
    # tasks, which are always fully qualified) and previously only ever
    # matched AVAILABLE_PLUGINS verbatim, so any bare name failed outright
    # ("Plugin not available: getent") even though the qualified form
    # works fine. None of AVAILABLE_PLUGINS' short names collide across
    # collections, so the search order only matters for documentation
    # purposes here, not correctness.
    MODULE_SEARCH_COLLECTIONS = [
      "ansible.builtin", "ansible.legacy", "ansible.posix",
      "community.general", "community.docker", "community.mysql", "community.postgresql",
      # community.crypto (round 188): openssl_privatekey, openssl_csr,
      # x509_certificate, openssl_pkcs12, openssh_keypair. Roles write
      # the bare short names (`openssl_privatekey:`, `openssl_csr:`, ...),
      # and real Ansible auto-resolves them to `community.crypto.<name>`
      # via the collection aliasing mechanism. Without this entry, the
      # `MODULE_SEARCH_COLLECTIONS` loop in #resolve_module_name never
      # tries the `community.crypto.` prefix, the bare name is
      # unresolvable, and the task is dropped with a
      # "uses unimplemented plugin" warning (the plugin source and
      # binary both exist - the lookup just didn't find them).
      # Verified against weareinteractive.openssl's own `openssl_privatekey:`
      # / `openssl_csr:` / `openssl_certificate:` task names: real
      # ansible-core 2.19.4 resolves them; crystal 0.9.622 warned and
      # skipped.
      # community.rabbitmq (0.9.944): rabbitmq_plugin/rabbitmq_user are
      # registered only under their FQCN, but real roles write the bare
      # short names (SimpliField.rabbitmq and rockandska.rabbitmq rounds
      # both write `rabbitmq_plugin:` unqualified) - without this entry
      # the bare name is unresolvable and the task is dropped as
      # "unavailable module" where real ansible resolves it through
      # collection search.
      "community.rabbitmq",
      "community.crypto",
    ]

    # Modules whose bare-string task arg is a raw command line, not
    # free-form key=value params - see the yaml.as_s? branch of
    # #parse_module_params. Bare "command"/"shell" is included
    # defensively alongside the resolved FQCN forms, in case this is
    # ever reached before module_name resolution.
    RAW_COMMAND_MODULES = {
      "command", "shell", "script", "raw",
      "ansible.builtin.command", "ansible.builtin.shell",
      "ansible.legacy.command", "ansible.legacy.shell",
      "ansible.builtin.script", "ansible.legacy.script",
      "ansible.builtin.raw", "ansible.legacy.raw",
    }

    # Real Ansible module aliases - a second FQCN (or bare name) that
    # resolves to the exact same module, not merely a similarly-named
    # one. `systemd_service` was added in ansible-core 2.12 as the
    # "correct" name (`systemd` was ambiguous with `systemd_service`/
    # `systemd_socket`... at the time only one of each ever shipped);
    # `systemd` is still kept as a working alias, and real-world roles
    # use both spellings interchangeably (konstruktoid/ansible-role-
    # hardening's own tasks write `ansible.builtin.systemd_service` 19
    # times across 14 files, never the bare `ansible.builtin.systemd`
    # this codebase's plugin is actually named after). Checked before
    # the AVAILABLE_PLUGINS/MODULE_SEARCH_COLLECTIONS lookups below, so
    # both spellings resolve to the one real plugin binary.
    MODULE_ALIASES = {
      "systemd_service"                 => "ansible.builtin.systemd",
      "ansible.builtin.systemd_service" => "ansible.builtin.systemd",
      "ansible.legacy.systemd_service"  => "ansible.builtin.systemd",
      # raw: has no real Ansible-module counterpart of its own in this
      # codebase - unlike real Ansible (whose raw: exists specifically to
      # run on hosts with no Python interpreter at all, executed straight
      # over the connection plugin with zero module machinery),
      # krikri-playbook never ships Python modules to begin with, so
      # raw:'s only real distinguishing behavior (module-arg-free command
      # text, same free-form parsing as shell:/command:, already covered
      # by RAW_COMMAND_MODULES) is already identical to shell:'s. Aliased
      # straight to the existing shell plugin binary rather than shipping
      # a near-duplicate one.
      "raw"                 => "ansible.builtin.shell",
      "ansible.builtin.raw" => "ansible.builtin.shell",
      "ansible.legacy.raw"  => "ansible.builtin.shell",
      # ansible.mariadb's mariadb_db/mariadb_user are functionally
      # byte-identical forks of community.mysql's mysql_db/mysql_user
      # (same argument spec, same defaults, same wire-protocol
      # implementation, same CLI dump/import flags - verified against
      # both collections' actual sources), so - same call as raw: above -
      # they alias straight onto the existing plugin binaries rather
      # than shipping near-duplicates. fauust.mariadb (round 6002) calls
      # the FQCN forms; the bare spellings resolve the same way when the
      # collection is installed.
      "mariadb_db"                   => "community.mysql.mysql_db",
      "mariadb_user"                 => "community.mysql.mysql_user",
      "ansible.mariadb.mariadb_db"   => "community.mysql.mysql_db",
      "ansible.mariadb.mariadb_user" => "community.mysql.mysql_user",
      # openssl_certificate is x509_certificate's old name: the module
      # shipped in ansible-core <= 2.9 as `openssl_certificate`, moved to
      # community.crypto as `x509_certificate` (1.0.0, with the old name
      # as a deprecated redirect), and community.crypto 2.0.0 removed
      # that FQCN redirect - but ansible-core's own builtin runtime
      # (ansible_builtin_runtime.yml) still redirects the bare and
      # ansible.builtin./ansible.legacy. spellings to
      # community.crypto.x509_certificate on every current controller,
      # and community.general redirected its pre-2.0 copy to the same
      # place. Real roles use every one of these spellings
      # (weareinteractive.openssl writes the bare form; round-85002-class
      # trellis/nginx roles write the FQCNs), so all of them resolve
      # onto the existing x509_certificate plugin binary rather than
      # shipping a near-duplicate of it. Deliberately permissive on the
      # community.crypto FQCN, which a current community.crypto
      # tombstones (2.0.0+): the engine would otherwise hard-stop a role
      # real Ansible 2.10-2.11 ran fine, and the module behind it is
      # fully implemented either way.
      "openssl_certificate"                   => "community.crypto.x509_certificate",
      "ansible.builtin.openssl_certificate"   => "community.crypto.x509_certificate",
      "ansible.legacy.openssl_certificate"    => "community.crypto.x509_certificate",
      "community.crypto.openssl_certificate"  => "community.crypto.x509_certificate",
      "community.general.openssl_certificate" => "community.crypto.x509_certificate",
      # openssl_certificate_info is x509_certificate_info's old name,
      # the exact same rename story as openssl_certificate above (shipped
      # pre-collection as openssl_certificate_info, renamed to
      # x509_certificate_info in community.crypto 1.0.0 with the old name
      # as a deprecated redirect). All five spellings resolve onto the
      # existing x509_certificate_info plugin binary. ufz.zammad (round
      # 410129) hard-stopped on the bare spelling.
      "openssl_certificate_info"                   => "community.crypto.x509_certificate_info",
      "ansible.builtin.openssl_certificate_info"   => "community.crypto.x509_certificate_info",
      "ansible.legacy.openssl_certificate_info"    => "community.crypto.x509_certificate_info",
      "community.crypto.openssl_certificate_info"  => "community.crypto.x509_certificate_info",
      "community.general.openssl_certificate_info" => "community.crypto.x509_certificate_info",
      # virt_net's collection namespace (see its AVAILABLE_PLUGINS entry).
      "community.libvirt.virt_net" => "virt_net",
    }

    # community.docker's own removal text for docker_compose v1
    # (End-of-Life since July 2022; removed from community.docker in
    # v4.0.0, docker_compose_v2 is the replacement) - real
    # ansible-playbook's exact hard-stop wording, verified live against
    # ansible-core 2.19.11. Shared verbatim by all three tombstone
    # spellings (bare, community.general.- and community.docker.-
    # qualified): real Ansible echoes the RESOLVED module name, never
    # the as-written spelling, for this one.
    DOCKER_COMPOSE_REMOVAL_MESSAGE = "The 'community.docker.docker_compose' module has been removed. " \
                                     "This module uses docker-compose v1, which is End of Life since July 2022. " \
                                     "Please migrate to community.docker.docker_compose_v2. " \
                                     "This feature was removed from collection 'community.docker' version 4.0.0."

    # community.mysql 5.x's own meta/runtime.yml plugin_routing redirects
    # these module FQCNs to their ansible.mysql.* homes with a deprecation
    # (removal_version 6.0.0, warning_text "Use ansible.mysql.<module>
    # instead.") - live-verified against the installed community.mysql
    # 5.0.2's meta/runtime.yml and real ansible-core 2.19.11's console
    # output (mysql_replication/mysql_role redirect the same way but are
    # not krikri-supported modules, so they are deliberately absent: an
    # unsupported module's divergence is out of scope per the coverage
    # bar). Real resolves a task's module at task-load time and
    # record_deprecation warns there - once per distinct message per run
    # (the Display dedups), with the one-time
    # "Deprecation warnings can be disabled" hint before the first - and
    # every task result the module actually produced carries the
    # `deprecations` entry (TaskExecutor's DeferredWarningContext). The
    # bare (non-FQCN) spellings resolve through MODULE_SEARCH_COLLECTIONS
    # to the community.mysql FQCN and warn identically.
    COMMUNITY_MYSQL_REDIRECT_DEPRECATIONS = {
      "community.mysql.mysql_db"        => "ansible.mysql.mysql_db",
      "community.mysql.mysql_info"      => "ansible.mysql.mysql_info",
      "community.mysql.mysql_query"     => "ansible.mysql.mysql_query",
      "community.mysql.mysql_user"      => "ansible.mysql.mysql_user",
      "community.mysql.mysql_variables" => "ansible.mysql.mysql_variables",
    }

    # The exact console [DEPRECATION WARNING] text real ansible-core
    # 2.19.11 prints for one of the redirects above (live-verified: the
    # loader's warning_text joined onto the "has been deprecated." stem,
    # followed by Display's removal-version tail naming the collection and
    # version). nil for every name that is not one of the redirects.
    def self.redirect_deprecation_text(fqcn : String) : String?
      target = COMMUNITY_MYSQL_REDIRECT_DEPRECATIONS[fqcn]? || return nil
      "#{fqcn} has been deprecated. Use #{target} instead. " \
      "This feature will be removed from collection 'community.mysql' version 6.0.0."
    end

    # The `deprecations` result entry real attaches to every executed
    # task result for a redirected module (live-verified via register:
    # r.deprecations == [{"msg": "community.mysql.mysql_info has been
    # deprecated. Use ansible.mysql.mysql_info instead.",
    # "collection_name": "community.mysql", "version": "6.0.0",
    # "deprecator": {"resolved_name": "community.mysql", "type": null}}]
    # - note the msg carries NO removal tail; only the console line
    # does). nil for every name that is not one of the redirects.
    def self.redirect_deprecation_result_entry(fqcn : String) : JSON::Any?
      target = COMMUNITY_MYSQL_REDIRECT_DEPRECATIONS[fqcn]? || return nil
      JSON.parse({
        "msg"             => "#{fqcn} has been deprecated. Use #{target} instead.",
        "collection_name" => "community.mysql",
        "version"         => "6.0.0",
        "deprecator"      => {
          "resolved_name" => "community.mysql",
          "type"          => nil,
        },
      }.to_json)
    end

    # Bare module names real ansible-core can no longer resolve in ANY
    # collection (removed from ansible-core years ago and from the
    # collections that absorbed them), so every real ansible-playbook
    # install hard-stops on them. Deliberately minimal: an entry here
    # hard-stops the whole run at parse time, so a name belongs here
    # only when it is unresolvable on EVERY real controller - never a
    # module that a current collection still ships. Widening = adding
    # entries here. Value is real Ansible's own hard-stop error text for
    # that name: nil means the generic couldn't-resolve wording (what
    # ansible-core prints when nothing anywhere resolves the name),
    # while some removed names have real Ansible print its own specific
    # removal message instead - verified live against ansible-core
    # 2.19.11, including which names get which wording.
    REMOVED_MODULE_TOMBSTONES = {
      "ec2_remote_facts"                 => nil,
      "ansible.builtin.ec2_remote_facts" => nil,
      "ansible.legacy.ec2_remote_facts"  => nil,
      "amazon.aws.ec2_remote_facts"      => nil,
      # Removed from community.general in v10.0.0 (its own runtime.yml
      # tombstones the FQCN), so every controller on a current
      # collection hard-fails on it (idealista.consul-role, round 033).
      # Both spellings: a task can reference it bare when `collections:`
      # is set on the play (or historically, before FQCNs were the
      # convention) - only the FQCN was tombstoned initially, so a
      # bare-name task (like idealista.consul-role's own sibling roles
      # might write) slipped through ungracefully-skipped instead of
      # hard-stopped, same bug class as docker_service below.
      "community.general.consul_acl" => nil,
      "consul_acl"                   => nil,
      # Removed from community.general in v2.0.0 (superseded by
      # `docker_compose`), so every controller on a current collection
      # hard-fails on it. krzysztof-magosa.docker writes the BARE name
      # (`docker_service:`, no FQCN) - the exact-string match against
      # `as_written` (raise_unresolvable_module_error, no bare/FQCN
      # normalization there) meant only the FQCN spelling was ever
      # caught; confirmed live against the rebuilt 0.9.891 binary still
      # gracefully skipping the bare form instead of hard-stopping.
      "community.general.docker_service" => nil,
      "docker_service"                   => nil,
      # docker_compose (the compose v1 module) - community.docker
      # removed it in v4.0.0 (docker-compose v1 is End-of-Life since
      # July 2022; community.docker.docker_compose_v2 is the
      # replacement) and community.general's own redirect now lands on
      # that tombstone, so every current controller hard-stops. The
      # message is the collection's own removal text, NOT the generic
      # couldn't-resolve wording, and it names the RESOLVED
      # community.docker.docker_compose spelling, never the as-written
      # one - identical for all three spellings (bare,
      # community.general.- and community.docker.-qualified; verified
      # live against ansible-core 2.19.11 with a minimal repro).
      # lucasmaurice.awx (round 900444) writes the bare name; this
      # engine previously fell through to the unavailable-module path
      # and failed at RUN time with a misleading "docker: No such file
      # or directory" instead of matching real Ansible's own
      # removed-module hard stop. docker_compose_v2 itself is a
      # separate, fully-implemented plugin (plugins/docker_compose_v2.cr)
      # - this tombstones only the removed v1 module.
      "community.docker.docker_compose"  => DOCKER_COMPOSE_REMOVAL_MESSAGE,
      "community.general.docker_compose" => DOCKER_COMPOSE_REMOVAL_MESSAGE,
      "docker_compose"                   => DOCKER_COMPOSE_REMOVAL_MESSAGE,
    }
  end
end
