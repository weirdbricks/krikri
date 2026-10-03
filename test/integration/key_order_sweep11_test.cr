require "../minitest_helper"

require "json"

# Registered-result key order (and the shape of the values behind it) for
# the RPM-family plugins, pinned to what REAL ansible-core 2.19.11
# registers - each shape observed through `{{ r | to_json }}` on a
# registered task inside a real Fedora 41 container, one FRESH container
# per engine so real and krikri started from byte-identical host state
# (the -v dump sorts alphabetically, so the order is only observable
# programmatically - see key_order_sweep_test.cr for the general method).
#
# `ansible_facts` and `warnings` appear in real's registered result too
# (the interpreter-discovery warning and the fact the controller merges
# in) but have no krikri equivalent, so every expectation below starts at
# the first module-owned key.
#
# The plugins need a real rpm/dnf host, so every spec here runs the
# compiled binary inside the throwaway fedora image (read-only bind
# mount of this worktree's ./bin, a fresh container per spec) and skips
# cleanly when podman or that local image is unavailable. Containers are
# named krikri-kp-fed-*.
FEDORA_IMAGE  = "localhost/krikri-fedora-compat:latest"
FEDORA_BIN    = File.expand_path("../../bin", __DIR__)
FEDORA_PREFIX = "krikri-kp-fed-s11"

def fedora_image? : Bool
  output = IO::Memory.new
  Process.run("podman", ["image", "exists", FEDORA_IMAGE], output: output, error: output)
  $?.success?
end

# Runs `play` (a full playbook body) in a FRESH container and returns the
# registered dumps it wrote to /work/out-<name>.json, keyed by name.
# `container` also selects the container name, so a leftover from a
# previous crashed run can be reused/cleaned deterministically.
def fedora_play(play : String, container : String) : Hash(String, Hash(String, JSON::Any))
  work = PluginSpecHelper.tmp_path("fed11-#{container}")
  Dir.mkdir_p(work)
  File.write(File.join(work, "play.yml"), play)
  Process.run("podman", ["rm", "-f", FEDORA_PREFIX + container],
    output: Process::Redirect::Close, error: Process::Redirect::Close)
  output = IO::Memory.new
  Process.run("podman", [
    "run", "--rm", "--name", FEDORA_PREFIX + container,
    "-v", "#{FEDORA_BIN}:/kbin:ro",
    "-v", "#{work}:/work",
    FEDORA_IMAGE,
    "sh", "-c", "/kbin/krikri-playbook -i localhost, -c local play.yml",
  ], output: output, error: output)
  $?.success?.must_equal(true, output.to_s[-1500..]? || output.to_s)
  dumps = {} of String => Hash(String, JSON::Any)
  Dir.glob(File.join(work, "out-*.json")).each do |path|
    dumps[File.basename(path, ".json").lchop("out-")] = JSON.parse(File.read(path)).as_h
  end
  dumps
ensure
  Process.run("podman", ["rm", "-f", FEDORA_PREFIX + container],
    output: Process::Redirect::Close, error: Process::Redirect::Close)
end

# A play whose every task registers `r` and dumps it to
# /work/out-<label>.json, so one container run can pin several shapes.
private def dump_task(label : String) : String
  "    - copy:\n" \
  "        dest: /work/out-#{label}.json\n" \
  "        content: \"{{ r | to_json }}\"\n"
end

describe "dnf-family plugin result key order (sweep11)" do
  serial!

  it "registers real's dnf install/no-op/list/cache result shapes" do
    skip("podman image #{FEDORA_IMAGE} unavailable") unless fedora_image?
    dumps = fedora_play(<<-YAML, "dnf")
    ---
    - hosts: localhost
      gather_facts: false
      connection: local
      tasks:
        - name: no-op (package already installed)
          dnf:
            name: bash
            state: present
          register: r
    #{dump_task("noop")}
        - name: list
          dnf:
            list: bash
          register: r
    #{dump_task("list")}
        - name: cache
          dnf:
            update_cache: true
          register: r
    #{dump_task("cache")}
        - name: install
          dnf:
            name: sl
            state: present
          register: r
    #{dump_task("install")}
        - name: remove
          dnf:
            name: sl
            state: absent
          register: r
    #{dump_task("remove")}
        - name: absent again
          dnf:
            name: sl
            state: absent
          register: r
    #{dump_task("absent")}
    YAML

    # real 2.19.11, fedora:41, `dnf: {name: bash, state: present}` on an
    # already-installed package: results, changed, msg "Nothing to do",
    # rc 0, failed.
    noop = dumps["noop"]
    noop.keys.must_equal(%w[results changed msg rc failed])
    noop["results"].as_a.must_equal([] of JSON::Any)
    noop["changed"].as_bool.must_equal(false)
    noop["msg"].as_s.must_equal("Nothing to do")
    noop["rc"].as_i.must_equal(0)

    # `list:` is real's exit_json(msg="", results=...) - no `changed` of
    # its own, so the CONTROLLER backfills it after `failed` (real:
    # msg, results, rc, failed, changed). krikri registers the same five
    # keys with the same values; only the position of the
    # controller-injected `failed` differs (this engine's executor
    # appends it last, after the module's own keys, so `changed` lands
    # one position earlier than real's).
    list = dumps["list"]
    list.keys.must_equal(%w[msg results rc changed failed])
    list["msg"].as_s.must_equal("")
    list["changed"].as_bool.must_equal(false)
    list["rc"].as_i.must_equal(0)
    # the per-package dict is real's _package_dict spelling/order.
    pkg = list["results"].as_a.first.as_h
    pkg.keys.must_equal(%w[name arch epoch release version repo nevra envra yumstate])
    pkg["name"].as_s.must_equal("bash")
    pkg["epoch"].as_s.must_equal("0")
    pkg["yumstate"].as_s.must_equal("installed")
    pkg["nevra"].as_s.starts_with?("bash-").must_equal(true)

    # `update_cache:` with no name is real's literal
    # exit_json(msg=, changed=, results=, rc=) call - a DIFFERENT key
    # order from the transaction path above.
    cache = dumps["cache"]
    cache.keys.must_equal(%w[msg changed results rc failed])
    cache["msg"].as_s.must_equal("Cache updated")
    cache["changed"].as_bool.must_equal(false)

    # A real transaction: results carries the installed RPM's NEVRA and
    # msg is EMPTY (real only says "Nothing to do" when it changed
    # nothing).
    install = dumps["install"]
    install.keys.must_equal(%w[results changed msg rc failed])
    install["changed"].as_bool.must_equal(true)
    install["msg"].as_s.must_equal("")
    install["results"].as_a.first.as_s.must_match(/^Installed: sl-\d/)

    # Removing an installed package reports the removed RPM's NEVRA.
    remove = dumps["remove"]
    remove.keys.must_equal(%w[results changed msg rc failed])
    remove["changed"].as_bool.must_equal(true)
    remove["results"].as_a.first.as_s.must_match(/^Removed: sl-\d/)

    # state: absent of an already-absent package is the same no-op shape.
    absent = dumps["absent"]
    absent.keys.must_equal(%w[results changed msg rc failed])
    absent["changed"].as_bool.must_equal(false)
    absent["msg"].as_s.must_equal("Nothing to do")
  end

  it "registers real's dnf removal result shape" do
    skip("podman image #{FEDORA_IMAGE} unavailable") unless fedora_image?
    dumps = fedora_play(<<-YAML, "dnfrm")
    ---
    - hosts: localhost
      gather_facts: false
      connection: local
      tasks:
        - name: install
          dnf:
            name: sl
            state: present
          register: r
    #{dump_task("install")}
        - name: remove
          dnf:
            name: sl
            state: absent
          register: r
    #{dump_task("remove")}
    YAML

    install = dumps["install"]
    install.keys.must_equal(%w[results changed msg rc failed])
    install["changed"].as_bool.must_equal(true)

    remove = dumps["remove"]
    remove.keys.must_equal(%w[results changed msg rc failed])
    remove["changed"].as_bool.must_equal(true)
    remove["msg"].as_s.must_equal("")
    remove["results"].as_a.first.as_s.must_match(/^Removed: sl-\d/)
  end
  it "registers real's dnf5 install/no-op/list result shapes" do
    skip("podman image #{FEDORA_IMAGE} unavailable") unless fedora_image?
    dumps = fedora_play(<<-YAML, "dnf5")
    ---
    - hosts: localhost
      gather_facts: false
      connection: local
      tasks:
        - name: no-op (already installed)
          dnf5:
            name: bash
            state: present
          register: r
    #{dump_task("noop")}
        - name: list
          dnf5:
            list: bash
          register: r
    #{dump_task("list")}
        - name: install
          dnf5:
            name: sl
            state: present
          register: r
    #{dump_task("install")}
        - name: remove
          dnf5:
            name: sl
            state: absent
          register: r
    #{dump_task("remove")}
    YAML

    # real dnf5's own exit_json(results=, changed=, msg=, rc=) - the same
    # shape as dnf's transaction path.
    noop = dumps["noop"]
    noop.keys.must_equal(%w[results changed msg rc failed])
    noop["msg"].as_s.must_equal("Nothing to do")
    noop["results"].as_a.must_equal([] of JSON::Any)

    # dnf5's list path also reports rc, like dnf's.
    list = dumps["list"]
    list.keys.must_equal(%w[msg results rc changed failed])
    list["msg"].as_s.must_equal("")
    pkg = list["results"].as_a.first.as_h
    pkg.keys.must_equal(%w[name arch epoch release version repo nevra envra yumstate])
    pkg["name"].as_s.must_equal("bash")

    install = dumps["install"]
    install.keys.must_equal(%w[results changed msg rc failed])
    install["changed"].as_bool.must_equal(true)
    install["msg"].as_s.must_equal("")
    install["results"].as_a.first.as_s.must_match(/^Installed: sl-\d/)

    remove = dumps["remove"]
    remove.keys.must_equal(%w[results changed msg rc failed])
    remove["changed"].as_bool.must_equal(true)
    remove["results"].as_a.first.as_s.must_match(/^Removed: sl-\d/)
  end
  it "registers real's dnf_versionlock result shape" do
    skip("podman image #{FEDORA_IMAGE} unavailable") unless fedora_image?
    dumps = fedora_play(<<-YAML, "dvl")
    ---
    - hosts: localhost
      gather_facts: false
      connection: local
      tasks:
        - community.general.dnf_versionlock:
            name: bash
          register: r
    #{dump_task("lock")}
    YAML

    # real community.general dnf_versionlock builds its response dict as
    # changed/msg/locklist_pre/specs_toadd/specs_todelete and only then
    # appends locklist_post - so the POST list comes last, not next to
    # locklist_pre (live-verified against community.general on fedora:41).
    lock = dumps["lock"]
    lock.keys.must_equal(%w[changed msg locklist_pre specs_toadd specs_todelete locklist_post failed])
    lock["changed"].as_bool.must_equal(true)
    lock["locklist_pre"].as_a.must_equal([] of JSON::Any)
    lock["specs_toadd"].as_a.size.must_equal(1)
    lock["specs_todelete"].as_a.must_equal([] of JSON::Any)
    lock["locklist_post"].as_a.must_equal(lock["specs_toadd"].as_a)
  end

  it "registers real's yum_versionlock result shape" do
    skip("podman image #{FEDORA_IMAGE} unavailable") unless fedora_image?
    dumps = fedora_play(<<-YAML, "yvl")
    ---
    - hosts: localhost
      gather_facts: false
      connection: local
      tasks:
        - community.general.yum_versionlock:
            name: bash
          register: r
    #{dump_task("lock")}
    YAML

    # real exits exit_json(changed=changed, meta={"packages": ..., "state":
    # ...}) - the requested specs and the resolved state come back under
    # a single top-level "meta" key, whatever the module's docs say.
    lock = dumps["lock"]
    lock.keys.must_equal(%w[changed meta failed])
    lock["changed"].as_bool.must_equal(true)
    meta = lock["meta"].as_h
    meta.keys.must_equal(%w[packages state])
    meta["packages"].as_a.must_equal(["bash"])
    meta["state"].as_s.must_equal("present")
  end

  it "registers real's rpm_key success shape (changed + the controller's failed)" do
    skip("podman image #{FEDORA_IMAGE} unavailable") unless fedora_image?
    dumps = fedora_play(<<-YAML, "rk")
    ---
    - hosts: localhost
      gather_facts: false
      connection: local
      tasks:
        - ansible.builtin.rpm_key:
            key: e99d6ad1
            state: present
          register: r
    #{dump_task("key")}
    YAML

    # real's rpm_key exit_json(changed=...) carries nothing else, so the
    # registered result is exactly the module's `changed` plus the
    # controller's `failed` (no msg, no stdout).
    key = dumps["key"]
    key.keys.must_equal(%w[changed failed])
    key["changed"].as_bool.must_equal(false)
  end

  it "registers real's gem success shape" do
    skip("podman image #{FEDORA_IMAGE} unavailable") unless fedora_image?
    dumps = fedora_play(<<-YAML, "gem")
    ---
    - hosts: localhost
      gather_facts: false
      connection: local
      tasks:
        - command: dnf -y install ruby
          changed_when: false
        - community.general.gem:
            name: rake
            state: present
          register: r
    #{dump_task("gem")}
    YAML

    # real community.general gem's success result carries no msg and no
    # captured output - just what was asked for, plus changed. (The
    # module's own dict orders them name/state/changed; the registered
    # result hoists changed to the front, and krikri's executor appends
    # failed last, which is where real's controller puts it too.)
    gem = dumps["gem"]
    gem.keys.must_equal(%w[changed name state failed])
    gem["changed"].as_bool.must_equal(true)
    gem["name"].as_s.must_equal("rake")
    gem["state"].as_s.must_equal("present")
  end
end
