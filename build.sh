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
)

PLUGIN_COUNT=0
TO_BUILD=()

# First pass: figure out which plugins need a rebuild (cheap mtime checks,
# no compilation) so the actual `crystal build` invocations below can run
# in parallel instead of one at a time.
for plugin in "${PLUGINS[@]}"; do
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

    build_one_plugin() {
        local plugin="$1"
        local source="plugins/$plugin.cr"
        local binary="$PLUGINS_DIR/$plugin"

        # Each parallel job gets its own CRYSTAL_CACHE_DIR - concurrent
        # `crystal build` invocations sharing the default `~/.cache/crystal`
        # can race on the compiler's own temp/object files (seen as a
        # spurious "you've found a bug in the Crystal compiler" /
        # errno.cr "No such file or directory" mid-codegen under real
        # parallel load - not an actual bug in any of these plugins).
        if OUTPUT=$(CRYSTAL_CACHE_DIR="$STATUS_DIR/cache-$plugin" crystal build "$source" -o "$binary" $BUILD_FLAGS 2>&1); then
            chmod +x "$binary"
            echo -e "   ${GREEN}✓${NC} $plugin"
        else
            echo -e "   ${RED}✗${NC} $plugin"
            printf '%s\n' "$OUTPUT" > "$STATUS_DIR/$plugin.fail"
        fi
    }
    export -f build_one_plugin
    export PLUGINS_DIR BUILD_FLAGS STATUS_DIR RED GREEN YELLOW NC

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
if [ $REBUILT_COUNT -gt 0 ]; then
    echo -e "${GREEN}✅ $PLUGIN_COUNT plugins checked ($REBUILT_COUNT rebuilt)${NC}"
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
