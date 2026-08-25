require "yaml"

module CrystalPlay
  # `module_defaults:` accepts an ACTION GROUP key (`group/aws`,
  # `group/consul`) standing for every module in that group, instead of
  # naming each one. Real Ansible learns group membership from each
  # installed collection's `meta/runtime.yml`:
  #
  #     action_groups:
  #       consul:
  #         - consul_kv
  #         - consul_token
  #       proxmox:
  #         - metadata:
  #             extend_group:
  #               - community.proxmox.proxmox
  #
  # This reads the same files rather than carrying a hardcoded table, so
  # a `group/` key resolves to whatever the collections on this machine
  # actually define - and keeps resolving correctly as they change.
  module ActionGroups
    # ansible-core's own action groups, mirrored from its
    # config/ansible_builtin_runtime.yml. Each maps to the collection
    # groups it extends; testgroup/testlegacy are ansible-core's own test
    # fixtures, included so the set matches exactly.
    BUILTIN_GROUPS = {
      "aws"    => ["amazon.aws.aws", "community.aws.aws"],
      "acme"   => ["community.crypto.acme"],
      "azure"  => ["azure.azcollection.azure"],
      "cpm"    => ["wti.remote.cpm"],
      "docker" => ["community.general.docker", "community.docker.docker"],
      "gcp"    => ["google.cloud.gcp"],
      "k8s"    => ["community.kubernetes.k8s", "community.general.k8s",
                "community.kubevirt.k8s", "community.okd.k8s", "kubernetes.core.k8s"],
      "os"        => ["openstack.cloud.os"],
      "ovirt"     => ["ovirt.ovirt.ovirt", "community.general.ovirt"],
      "vmware"    => ["community.vmware.vmware"],
      "testgroup" => ["testns.testcoll.testgroup", "testns.testcoll.anothergroup",
                      "testns.boguscoll.testgroup"],
      "testlegacy" => [] of String,
    }

    # Where collections live, in real Ansible's own search order.
    def self.collection_paths : Array(String)
      paths = [] of String
      if configured = ENV["ANSIBLE_COLLECTIONS_PATH"]? || ENV["ANSIBLE_COLLECTIONS_PATHS"]?
        configured.split(':').each { |entry| paths << entry unless entry.empty? }
      end
      if home = ENV["HOME"]?
        paths << File.join(home, ".ansible", "collections")
      end
      paths << "/usr/share/ansible/collections"
      paths
    end

    # Fully-qualified group name (`community.general.consul`) => module
    # short names.
    @@groups : Hash(String, Array(String))? = nil

    def self.groups : Hash(String, Array(String))
      cached = @@groups
      return cached if cached

      raw = Hash(String, Array(String)).new     # fq name => direct members
      extends = Hash(String, Array(String)).new # fq name => groups it extends

      # ansible.builtin defines action groups of its own, almost all of
      # them nothing but extend_group pointers into a collection. They
      # matter even when that collection is ABSENT: real Ansible accepts
      # `group/aws` with amazon.aws not installed (the group exists, it
      # just resolves to no modules) while rejecting `group/demo`
      # outright. Seeding them here reproduces that distinction without
      # needing a Python ansible install to read
      # ansible_builtin_runtime.yml from.
      BUILTIN_GROUPS.each do |name, targets|
        fq = "ansible.builtin.#{name}"
        raw[fq] ||= Array(String).new
        extends[fq] = targets.dup unless targets.empty?
      end

      collection_paths.each do |root|
        next unless Dir.exists?(root)

        Dir.glob(File.join(root, "ansible_collections", "*", "*", "meta", "runtime.yml")).each do |runtime|
          parts = runtime.split(File::SEPARATOR)
          collection = "#{parts[-4]}.#{parts[-3]}"
          load_runtime(runtime, collection, raw, extends)
        end
      end

      # Resolve extend_group transitively.
      resolved = Hash(String, Array(String)).new
      raw.each_key { |name| resolved[name] = resolve(name, raw, extends, Set(String).new) }

      # Keyed by FULLY-QUALIFIED name only. Real Ansible resolves a bare
      # `group/demo` against ansible.builtin (verified: it fails with
      # "could not resolve the module_defaults group ansible.builtin.demo"
      # even when another installed collection defines a `demo` group) -
      # so a bare name must NOT be allowed to match some collection's
      # group by accident.
      @@groups = resolved
      resolved
    end

    private def self.load_runtime(path : String, collection : String,
                                  raw : Hash(String, Array(String)),
                                  extends : Hash(String, Array(String))) : Nil
      parsed = YAML.parse(File.read(path))
      return unless action_groups = parsed["action_groups"]?.try(&.as_h?)

      action_groups.each do |group_name, entries|
        fq = "#{collection}.#{group_name}"
        members = raw[fq] ||= Array(String).new
        next unless list = entries.as_a?

        list.each do |entry|
          if name = entry.as_s?
            members << name
          elsif hash = entry.as_h?
            # `- metadata: {extend_group: [...]}` - not a module name.
            hash["metadata"]?.try(&.as_h?).try do |metadata|
              metadata["extend_group"]?.try(&.as_a?).try do |group_list|
                group_list.each do |other|
                  other.as_s?.try { |target| (extends[fq] ||= Array(String).new) << target }
                end
              end
            end
          end
        end
      end
    rescue
      # A collection with an unreadable or malformed runtime.yml simply
      # contributes no groups - it must not take the playbook down.
    end

    private def self.resolve(name : String, raw : Hash(String, Array(String)),
                             extends : Hash(String, Array(String)),
                             seen : Set(String)) : Array(String)
      return Array(String).new unless seen.add?(name)

      members = (raw[name]? || Array(String).new).dup
      extends[name]?.try &.each do |other|
        members.concat(resolve(other, raw, extends, seen))
      end
      members.uniq
    end

    # The modules named by a `group/<name>` key, or nil when nothing
    # defines it - the caller turns that into real Ansible's own error.
    # A bare name is qualified into ansible.builtin, exactly as real
    # Ansible does.
    def self.modules_for(group_key : String) : Array(String)?
      name = group_key.lchop("group/")
      qualified = name.includes?('.') ? name : "ansible.builtin.#{name}"
      groups[qualified]?
    end

    # The name real Ansible reports in its error for an unresolvable
    # group, so the message can match.
    def self.qualified_name(group_key : String) : String
      name = group_key.lchop("group/")
      name.includes?('.') ? name : "ansible.builtin.#{name}"
    end

    # Test seam: forget what was scanned, so a spec can point
    # ANSIBLE_COLLECTIONS_PATH at a fixture and rescan.
    def self.reset! : Nil
      @@groups = nil
    end
  end
end
