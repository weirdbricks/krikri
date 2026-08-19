#!/bin/bash
# Crystal Play - Build Script
# Fast, Ansible-compatible automation tool

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
OUTPUT_DIR="bin"
PLUGINS_DIR="$OUTPUT_DIR/plugins"
BUILD_MODE="debug"

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --release)
            BUILD_MODE="release"
            shift
            ;;
        --debug)
            BUILD_MODE="debug"
            shift
            ;;
        --clean)
            echo -e "${YELLOW}🧹 Cleaning build artifacts...${NC}"
            rm -rf "$OUTPUT_DIR"
            echo -e "${GREEN}✅ Clean complete!${NC}"
            exit 0
            ;;
        --help)
            echo "Crystal Play - Build Script"
            echo ""
            echo "Usage: $0 [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --release  Build with optimizations (slower build, faster runtime)"
            echo "  --debug    Build with debug symbols (default, faster build)"
            echo "  --clean    Remove build artifacts"
            echo "  --help     Show this help message"
            echo ""
            echo "Examples:"
            echo "  $0              # Build in debug mode (default)"
            echo "  $0 --release    # Build in release mode"
            echo "  $0 --clean      # Clean build artifacts"
            exit 0
            ;;
        *)
            echo -e "${RED}Unknown option: $1${NC}"
            exit 1
            ;;
    esac
done

echo -e "${BLUE}╔════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║     Crystal Play - Build System        ║${NC}"
echo -e "${BLUE}╚════════════════════════════════════════╝${NC}"
echo ""

# Ensure we're in the project root directory
if [ ! -f "crystal-play.cr" ]; then
    echo -e "${RED}❌ Error: crystal-play.cr not found!${NC}"
    echo ""
    echo -e "${YELLOW}Please run this script from the project root directory:${NC}"
    echo -e "${BLUE}  cd /path/to/crystal-play${NC}"
    echo -e "${BLUE}  ./build.sh${NC}"
    echo ""
    exit 1
fi

# Check for Crystal
if ! command -v crystal &> /dev/null; then
    echo -e "${RED}❌ Crystal not found!${NC}"
    echo "Please install Crystal from: https://crystal-lang.org/install/"
    exit 1
fi

echo -e "${GREEN}✅ Crystal found: $(crystal --version | head -n1)${NC}"
echo ""

# Check for required shards/dependencies
echo -e "${YELLOW}🔍 Checking dependencies...${NC}"

MISSING_DEPS=()

# Check if lib directory exists (created by shards install)
if [ ! -d "lib" ]; then
    echo -e "${RED}❌ Dependencies not installed!${NC}"
    echo ""
    echo -e "${BLUE}To install dependencies, run:${NC}"
    echo -e "${GREEN}  shards install${NC}"
    echo ""
    echo -e "${YELLOW}Then run ./build.sh again${NC}"
    exit 1
fi

if [ ${#MISSING_DEPS[@]} -gt 0 ]; then
    echo -e "${RED}❌ Missing dependencies!${NC}"
    echo ""
    echo -e "${YELLOW}The following Crystal shards are required but not installed:${NC}"
    for dep in "${MISSING_DEPS[@]}"; do
        echo -e "  ${RED}✗${NC} $dep"
    done
    echo ""
    echo -e "${BLUE}To install dependencies, run:${NC}"
    echo -e "${GREEN}  shards install${NC}"
    echo ""
    echo -e "${YELLOW}Then run ./build.sh again${NC}"
    exit 1
fi

echo -e "${GREEN}✅ All dependencies found${NC}"
echo ""

# Create directories
echo -e "${YELLOW}📁 Creating build directories...${NC}"
mkdir -p "$OUTPUT_DIR"
mkdir -p "$PLUGINS_DIR"

# Build flags
if [ "$BUILD_MODE" = "release" ]; then
    BUILD_FLAGS="--release"
    echo -e "${BLUE}🏗️  Building in RELEASE mode${NC}"
else
    BUILD_FLAGS=""
    echo -e "${BLUE}🐛 Building in DEBUG mode${NC}"
fi
echo ""

# Build main executable
echo -e "${YELLOW}🔨 Building main executable...${NC}"

MAIN_BINARY="$OUTPUT_DIR/crystal-ansible"
MAIN_SOURCE="crystal-play.cr"

# Check if main executable needs rebuilding
NEEDS_BUILD=false

if [ ! -f "$MAIN_BINARY" ]; then
    NEEDS_BUILD=true
elif [ "$MAIN_SOURCE" -nt "$MAIN_BINARY" ]; then
    NEEDS_BUILD=true
elif find src -name '*.cr' -newer "$MAIN_BINARY" -print -quit | grep -q .; then
    # crystal-play.cr's own mtime doesn't change when only its src/ deps do
    NEEDS_BUILD=true
elif [ -d lib ] && find lib -name '*.cr' -newer "$MAIN_BINARY" -print -quit | grep -q .; then
    # A `shards update` (e.g. pulling in a Crinja fork fix) touches
    # lib/'s own mtimes but never crystal-play.cr's - without this
    # check the whole rebuild silently no-ops, compiling nothing, and
    # every subsequent "verify the fix" step re-tests the SAME stale
    # binary. Found live: round 116's wordwrap fix appeared to not
    # apply at all across two separate `./build.sh` runs, each
    # reporting success, until this was added.
    NEEDS_BUILD=true
fi

if [ "$NEEDS_BUILD" = true ]; then
    echo -n "   Building crystal-ansible... "
    if ! OUTPUT=$(crystal build crystal-play.cr -o "$MAIN_BINARY" $BUILD_FLAGS 2>&1); then
        echo -e "${RED}✗${NC}"
        echo ""
        echo -e "${RED}❌ Build failed for main executable${NC}"
        echo ""
        echo "$OUTPUT"
        echo ""
        exit 1
    fi
    echo -e "${GREEN}✓${NC}"
    echo -e "${GREEN}✅ Main executable built: $OUTPUT_DIR/crystal-ansible${NC}"
else
    echo -e "   ${BLUE}✓${NC} crystal-ansible (up to date)"
    echo -e "${GREEN}✅ Main executable up to date${NC}"
fi
echo ""

# Build ansible (ad-hoc CLI)
echo -e "${YELLOW}🔨 Building ansible (ad-hoc CLI)...${NC}"

ADHOC_BINARY="$OUTPUT_DIR/ansible"
ADHOC_SOURCE="ansible.cr"

NEEDS_BUILD=false

if [ ! -f "$ADHOC_BINARY" ]; then
    NEEDS_BUILD=true
elif [ "$ADHOC_SOURCE" -nt "$ADHOC_BINARY" ]; then
    NEEDS_BUILD=true
elif find src -name '*.cr' -newer "$ADHOC_BINARY" -print -quit | grep -q .; then
    NEEDS_BUILD=true
elif [ -d lib ] && find lib -name '*.cr' -newer "$ADHOC_BINARY" -print -quit | grep -q .; then
    NEEDS_BUILD=true
fi

if [ "$NEEDS_BUILD" = true ]; then
    echo -n "   Building ansible... "
    if ! OUTPUT=$(crystal build ansible.cr -o "$ADHOC_BINARY" $BUILD_FLAGS 2>&1); then
        echo -e "${RED}✗${NC}"
        echo ""
        echo -e "${RED}❌ Build failed for ansible${NC}"
        echo ""
        echo "$OUTPUT"
        echo ""
        exit 1
    fi
    echo -e "${GREEN}✓${NC}"
    echo -e "${GREEN}✅ ansible built: $OUTPUT_DIR/ansible${NC}"
else
    echo -e "   ${BLUE}✓${NC} ansible (up to date)"
    echo -e "${GREEN}✅ ansible up to date${NC}"
fi
echo ""

# Build plugins
echo -e "${YELLOW}🔌 Building plugins...${NC}"
PLUGINS=(
    "make"
    "copy"
    "template"
    "file"
    "lineinfile"
    "replace"
    "service"
    "systemd"
    "shell"
    "command"
    "apt"
    "dnf"
    "yum"
    "package"
    "debug"
    "facts"
    "setup"
    "package_facts"
    "selinux"
    "pam_limits"
    "capabilities"
    "set_fact"
    "get_url"
    "blockinfile"
    "uri"
    "assert"
    "fail"
    "wait_for"
    "wait_for_connection"
    "ping"
    "fetch"
    "pause"
    "user"
    "group"
    "git"
    "pip"
    "gem"
    "cron"
    "authorized_key"
    "stat"
    "find"
    "getent"
    "archive"
    "unarchive"
    "yum_repository"
    "apt_repository"
    "apt_key"
    "rpm_key"
    "seboolean"
    "deb822_repository"
    "mount"
    "sysctl"
    "ufw"
    "firewalld"
    "iptables"
    "debconf"
    "async_status"
    "docker_image"
    "docker_network"
    "docker_container"
    "mysql_db"
    "mysql_user"
    "mysql_info"
    "mysql_query"
    "openssl_dhparam"
    "openssh_keypair"
    "modprobe"
    "pamd"
    "htpasswd"
    "ini_file"
    "timezone"
    "npm"
    "alternatives"
    "filesystem"
    "service_facts"
    "slurp"
    "postgresql_db"
    "postgresql_user"
    "postgresql_privs"
    "hostname"
    "script"
    "assemble"
    "tempfile"
    "known_hosts"
    "dpkg_selections"
    "subversion"
    "expect"
    "git_config"
    "sudoers"
    "dnf_versionlock"
    "docker_image_build"
    "ec2_metadata_facts"
)

# These 6 stay real, independent binaries instead of joining the fat
# binary below:
#   - facts: gathers real facts from the target - its own driver has no
#     class/STDIN-config shape at all (top-level `gather_facts`, no
#     config parsing), unlike every other plugin's uniform
#     `*Plugin < BasePlugin` + `STDIN.gets_to_end` shape the fat-binary
#     generator below depends on.
#   - debug/assert/fail/set_fact/pause: controller-side action plugins
#     as of 0.9.482 (see action_plugin_manager.cr) - normal task
#     execution never dispatches these as a module at all anymore, so
#     they'd only ever be pulled in for `async:`/manual invocation.
#     Kept as their own binaries rather than folded in, so the fat
#     binary doesn't have to link the whole templating engine (these 2
#     - debug/assert - were the largest binaries in the tree) for a
#     path that's no longer the normal one.
STANDALONE_PLUGINS=("facts" "debug" "assert" "fail" "set_fact" "pause")

# Every other plugin: one binary (see build_fat_plugin below) instead of
# 81 separate ones. All 81 share the exact same shape - one
# `class XPlugin < BasePlugin` + a 4-line `STDIN.gets_to_end` driver
# trailer (verified: `grep -c 'plugin.run' plugins/*.cr` is 1 for every
# non-facts file) - so each one re-linking its own private copy of the
# Crystal runtime + json + base_plugin was pure waste. 372 MB -> ~15 MB
# measured on this tree at 0.9.480, before debug/assert (the 2 largest,
# ~27 MB combined) were pulled into STANDALONE_PLUGINS above.
FAT_PLUGINS=()
for plugin in "${PLUGINS[@]}"; do
    is_standalone=false
    for standalone in "${STANDALONE_PLUGINS[@]}"; do
        [ "$plugin" = "$standalone" ] && is_standalone=true && break
    done
    [ "$is_standalone" = false ] && FAT_PLUGINS+=("$plugin")
done

# Builds (only when actually stale) ONE binary covering every plugin in
# FAT_PLUGINS, dispatched at runtime by argv[0]'s basename (the same
# trick busybox uses for its own multi-call binary) - see the generated
# file's own trailer for the exact dispatch. Then hardlinks
# $PLUGINS_DIR/<name> for every FAT_PLUGINS name onto that one binary,
# so get_local_plugin_path/upload_plugins_to_host/remote_plugin_target
# in plugin_manager.cr need ZERO changes: each name still resolves to a
# real, independently-named, directly-executable file at exactly the
# path they already expect - it just happens to share one inode with 80
# others instead of being 80 separate copies of the runtime. Verified
# with a real hardlinked build: `du` on the directory reports the
# shared-inode size once, not once per name, and each hardlinked name
# dispatches correctly via `File.basename(PROGRAM_NAME)`.
build_fat_plugin() {
    local fat_binary="$PLUGINS_DIR/.fat-plugin"
    local generated="plugins/.fat_plugin_generated.cr"

    local needs_build=false
    if [ ! -f "$fat_binary" ]; then
        needs_build=true
    else
        for plugin in "${FAT_PLUGINS[@]}"; do
            if [ "plugins/$plugin.cr" -nt "$fat_binary" ]; then
                needs_build=true
                break
            fi
        done
        if [ "$needs_build" = false ] && find src -name '*.cr' -newer "$fat_binary" -print -quit | grep -q .; then
            needs_build=true
        fi
        if [ "$needs_build" = false ] && [ -d lib ] && find lib -name '*.cr' -newer "$fat_binary" -print -quit | grep -q .; then
            needs_build=true
        fi
    fi

    if [ "$needs_build" = true ]; then
        echo -e "   ${YELLOW}Building fat plugin binary (${#FAT_PLUGINS[@]} modules)...${NC}"

        {
            echo 'require "json"'
            echo 'require "../src/crystal_play/plugin_daemon"'
            for plugin in "${FAT_PLUGINS[@]}"; do
                # Requires stay relative to plugins/ (unchanged) since
                # the generated file lives there too. Strips the
                # shebang line and everything from the shared 4-line
                # driver trailer onward (`input = STDIN.gets_to_end` -
                # a plain grep for the exact line every plugin's
                # trailer starts with, see this array's own comment
                # above for why that's safe to assume uniformly).
                sed -e '/^#!\/usr\/bin\/env crystal/d' \
                    -e '/^input = STDIN.gets_to_end/,$d' \
                    "plugins/$plugin.cr"
            done
            echo ''
            echo '# Dispatch table shared by both entry paths below - the one-shot'
            echo '# path (argv[0]-basename-selected, busybox-style multi-call binary)'
            echo '# and the persistent --daemon path (SUGGESTED_PERFORMANCE_'
            echo '# IMPROVEMENTS.md item #15, plugin_daemon.cr) - a daemon request'
            echo '# carries its own module name in the wire protocol instead of'
            echo '# relying on argv[0], since one daemon process serves every module'
            echo '# a host needs, not just the one name it happened to be exec'"'"'d as.'
            echo '# #run_and_capture (not #run) so this returns the JSON String'
            echo '# instead of printing it - required for the daemon path, which'
            echo '# frames and writes the response itself; harmless for the one-shot'
            echo '# path below, which just puts() the returned string same as before.'
            echo '# Returns nil (not a JSON error) for an unrecognized name -'
            echo '# deliberately, so each entry path below can keep its own prior'
            echo '# "unknown module" behavior rather than this refactor silently'
            echo '# changing either one: the one-shot path'"'"'s STDERR+exit(1) (matches'
            echo '# every hardlinked name always being a real FAT_PLUGINS entry, so'
            echo '# this has always been unreachable in practice, not something worth'
            echo '# changing as a side effect of an unrelated refactor) versus the'
            echo '# daemon path, which must never exit the whole long-lived process'
            echo '# over one bad request - it turns a nil into a normal JSON failed'
            echo '# result instead, so an unknown module fails just that ONE task.'
            echo 'module CrystalPlay::FatPluginDispatch'
            echo '  def self.call(name : String, config : JSON::Any) : String?'
            echo '    case name'
            for plugin in "${FAT_PLUGINS[@]}"; do
                cls=$(grep -oP 'class \K\w+Plugin(?= < BasePlugin)' "plugins/$plugin.cr" | head -1)
                echo "    when \"$plugin\""
                echo "      CrystalPlay::$cls.new(config).run_and_capture"
            done
            echo '    else'
            echo '      nil'
            echo '    end'
            echo '  end'
            echo 'end'
            echo ''
            echo '# argv[0]'"'"'s basename picks the module for the one-shot path (the OS'
            echo '# sets PROGRAM_NAME to whichever hardlinked path was actually exec'"'"'d,'
            echo '# local or remote, batched or not - build_fat_plugin'"'"'s own comment in'
            echo '# build.sh has the full rationale); `--daemon` is a distinct,'
            echo '# additional invocation shape of this SAME binary (started via its'
            echo '# real `.fat-plugin` path, not a per-module hardlink, so PROGRAM_NAME'
            echo '# is irrelevant to it), not a new file to upload/dedupe.'
            echo 'if ARGV[0]? == "--daemon"'
            echo '  CrystalPlay::PluginDaemon.serve do |name, config|'
            echo '    CrystalPlay::FatPluginDispatch.call(name, config) ||'
            echo '      {"changed" => false, "failed" => true, "msg" => "unknown plugin: #{name}"}.to_json'
            echo '  end'
            echo 'else'
            echo '  name = File.basename(PROGRAM_NAME)'
            echo '  config = JSON.parse(STDIN.gets_to_end)'
            echo '  if result = CrystalPlay::FatPluginDispatch.call(name, config)'
            echo '    puts result'
            echo '  else'
            echo '    STDERR.puts "unknown plugin: #{name}"'
            echo '    exit 1'
            echo '  end'
            echo 'end'
        } > "$generated"

        # archive/mysql_db/postgresql_db (part of FAT_PLUGINS) need the
        # same static-bz2 link fix their own individual builds used to
        # apply separately (see BZ2_STATIC_PLUGINS's own comment below,
        # still used for the STANDALONE_PLUGINS loop) - applying it to
        # the whole fat binary is harmless for the other 78 modules and
        # keeps the same missing-libbz2.so.1.0-on-RHEL fix intact.
        if OUTPUT=$(crystal build "$generated" -o "$fat_binary" $BUILD_FLAGS --link-flags="-Wl,-Bstatic -lbz2 -Wl,-Bdynamic" 2>&1); then
            chmod +x "$fat_binary"
            echo -e "   ${GREEN}✓${NC} fat plugin binary"
        else
            echo -e "   ${RED}✗${NC} fat plugin binary"
            echo "$OUTPUT"
            exit 1
        fi
    else
        echo -e "   ${BLUE}✓${NC} fat plugin binary (up to date)"
    fi

    # Cheap regardless of whether a rebuild just happened - relink any
    # name that's missing or (rare: a previous non-fat build left a real
    # standalone file at this path) not already hardlinked to the
    # current fat binary.
    local fat_inode
    fat_inode=$(stat -c %i "$fat_binary")
    for plugin in "${FAT_PLUGINS[@]}"; do
        local target="$PLUGINS_DIR/$plugin"
        if [ ! -e "$target" ] || [ "$(stat -c %i "$target" 2>/dev/null)" != "$fat_inode" ]; then
            ln -f "$fat_binary" "$target"
        fi
    done
}

build_fat_plugin

PLUGIN_COUNT=0
TO_BUILD=()

# First pass: figure out which plugins need a rebuild (cheap mtime checks,
# no compilation) so the actual `crystal build` invocations below can run
# in parallel instead of one at a time.
for plugin in "${STANDALONE_PLUGINS[@]}"; do
    SOURCE="plugins/$plugin.cr"

    if [ -f "$SOURCE" ]; then
        BINARY="$PLUGINS_DIR/$plugin"

        # Check if rebuild is needed
        NEEDS_BUILD=false

        if [ ! -f "$BINARY" ]; then
            # Binary doesn't exist
            NEEDS_BUILD=true
        elif [ "$SOURCE" -nt "$BINARY" ]; then
            # Source is newer than binary
            NEEDS_BUILD=true
        elif find src -name '*.cr' -newer "$BINARY" -print -quit | grep -q .; then
            # Plugin's own mtime doesn't change when only a src/ dependency
            # (e.g. base_plugin.cr, local_executor.cr) does - same class of
            # gap the main executable's own check already accounts for
            # above; without this, `./build.sh` after a src/ change reports
            # every plugin "up to date" and silently ships stale binaries.
            NEEDS_BUILD=true
        elif [ -d lib ] && find lib -name '*.cr' -newer "$BINARY" -print -quit | grep -q .; then
            # Same gap as above, for a `shards update` touching lib/'s
            # own mtimes (e.g. a Crinja fork fix) - see the main
            # executable's own identical check for the story.
            NEEDS_BUILD=true
        fi

        if [ "$NEEDS_BUILD" = true ]; then
            TO_BUILD+=("$plugin")
        else
            echo -e "   ${BLUE}✓${NC} $plugin (up to date)"
        fi
        ((PLUGIN_COUNT++))
    else
        echo -e "   ${YELLOW}⚠  Skipping $plugin (not found)${NC}"
    fi
done

REBUILT_COUNT=${#TO_BUILD[@]}

if [ "$REBUILT_COUNT" -gt 0 ]; then
    JOBS=$(nproc 2>/dev/null || echo 4)
    echo -e "   ${YELLOW}Building $REBUILT_COUNT plugin(s) (up to $JOBS in parallel)...${NC}"

    STATUS_DIR=$(mktemp -d)
    trap 'rm -rf "$STATUS_DIR"' EXIT

    # archive/mysql_db/postgresql_db all use the bz2 shard's real
    # libbz2 C binding (Compress::BZ2::Writer/Reader), which links
    # -lbz2 dynamically by default. libbz2.so.1.0 ships in Ubuntu's
    # base image but NOT in a base/minimal RHEL-family (Rocky/CentOS/
    # Alma) one - found live benchmarking a Rocky 9.6 target (0.9.474):
    # all three crashed at plugin-execution time with "error while
    # loading shared libraries: libbz2.so.1.0: cannot open shared
    # object file", even for a task never touching a .bz2 path at all
    # (a shared-library load failure happens at process start, before
    # main() ever runs). `-Wl,-Bstatic -lbz2 -Wl,-Bdynamic` statically
    # links just libbz2 (confirmed via `ldd` - no libbz2.so entry
    # remains) while leaving every other dynamic dependency (openssl,
    # pcre2, glibc itself) untouched, matching this codebase's existing
    # "glibc is a non-issue, no full static/musl build needed" stance -
    # this fixes the one specific library that WAS missing rather than
    # switching the whole build to static linking.
    BZ2_STATIC_PLUGINS="archive mysql_db postgresql_db"

    build_one_plugin() {
        local plugin="$1"
        local source="plugins/$plugin.cr"
        local binary="$PLUGINS_DIR/$plugin"

        local link_flags=()
        if [[ " $BZ2_STATIC_PLUGINS " == *" $plugin "* ]]; then
            # Must stay one argument (crystal splits --link-flags' OWN
            # value on whitespace internally) - an unquoted expansion
            # here would let bash split it into three separate argv
            # entries first, breaking the build.
            link_flags=("--link-flags=-Wl,-Bstatic -lbz2 -Wl,-Bdynamic")
        fi

        # Each parallel job gets its own CRYSTAL_CACHE_DIR - concurrent
        # `crystal build` invocations sharing the default `~/.cache/crystal`
        # can race on the compiler's own temp/object files (seen as a
        # spurious "you've found a bug in the Crystal compiler" /
        # errno.cr "No such file or directory" mid-codegen under real
        # parallel load - not an actual bug in any of these plugins).
        if OUTPUT=$(CRYSTAL_CACHE_DIR="$STATUS_DIR/cache-$plugin" crystal build "$source" -o "$binary" $BUILD_FLAGS "${link_flags[@]}" 2>&1); then
            chmod +x "$binary"
            echo -e "   ${GREEN}✓${NC} $plugin"
        else
            echo -e "   ${RED}✗${NC} $plugin"
            printf '%s\n' "$OUTPUT" > "$STATUS_DIR/$plugin.fail"
        fi
    }
    export -f build_one_plugin
    export PLUGINS_DIR BUILD_FLAGS STATUS_DIR RED GREEN YELLOW NC BZ2_STATIC_PLUGINS

    printf '%s\n' "${TO_BUILD[@]}" | xargs -P "$JOBS" -I{} bash -c 'build_one_plugin "$@"' _ {}

    FAILED=()
    for plugin in "${TO_BUILD[@]}"; do
        [ -f "$STATUS_DIR/$plugin.fail" ] && FAILED+=("$plugin")
    done

    if [ ${#FAILED[@]} -gt 0 ]; then
        echo ""
        echo -e "${RED}❌ Build failed for: ${FAILED[*]}${NC}"
        echo ""
        for plugin in "${FAILED[@]}"; do
            echo -e "${RED}--- $plugin ---${NC}"
            cat "$STATUS_DIR/$plugin.fail"
            echo ""
        done
        echo -e "${YELLOW}Fix the error(s) above and run ./build.sh again${NC}"
        exit 1
    fi
fi

echo ""
PLUGIN_COUNT=$((PLUGIN_COUNT + ${#FAT_PLUGINS[@]}))
if [ $REBUILT_COUNT -gt 0 ]; then
    echo -e "${GREEN}✅ $PLUGIN_COUNT plugins checked ($REBUILT_COUNT standalone rebuilt, ${#FAT_PLUGINS[@]} via fat binary)${NC}"
else
    echo -e "${GREEN}✅ All $PLUGIN_COUNT plugins up to date${NC}"
fi
echo ""

# Summary
echo -e "${BLUE}╔════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║         Build Complete! 🎉             ║${NC}"
echo -e "${BLUE}╚════════════════════════════════════════╝${NC}"
echo ""
echo -e "${GREEN}Executable:${NC} $OUTPUT_DIR/crystal-ansible"
echo -e "${GREEN}Executable:${NC} $OUTPUT_DIR/ansible"
echo -e "${GREEN}Plugins:${NC} $PLUGINS_DIR/ ($PLUGIN_COUNT plugins)"
echo ""
echo -e "${YELLOW}Quick Start:${NC}"
echo -e "  ${BLUE}./bin/crystal-ansible test-facts.yml${NC}"
echo -e "  ${BLUE}./bin/crystal-ansible --diff test-lineinfile.yml${NC}"
echo -e "  ${BLUE}./bin/crystal-ansible --check test-handlers.yml${NC}"
echo ""

# Show size information
if command -v du &> /dev/null; then
    TOTAL_SIZE=$(du -sh "$OUTPUT_DIR" | cut -f1)
    echo -e "${YELLOW}Build size:${NC} $TOTAL_SIZE"
fi

echo ""
echo -e "${GREEN}Happy automating! 🚀${NC}"
