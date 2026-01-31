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
BUILD_MODE="release"

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
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
            echo "  --debug    Build with debug symbols"
            echo "  --clean    Remove build artifacts"
            echo "  --help     Show this help message"
            echo ""
            echo "Examples:"
            echo "  $0              # Build in release mode"
            echo "  $0 --debug      # Build in debug mode"
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
echo -e "${BLUE}║     Crystal Play - Build System       ║${NC}"
echo -e "${BLUE}╚════════════════════════════════════════╝${NC}"
echo ""

# Check for Crystal
if ! command -v crystal &> /dev/null; then
    echo -e "${RED}❌ Crystal not found!${NC}"
    echo "Please install Crystal from: https://crystal-lang.org/install/"
    exit 1
fi

echo -e "${GREEN}✅ Crystal found: $(crystal --version | head -n1)${NC}"
echo ""

# Check for system library dependencies
echo -e "${YELLOW}🔍 Checking system dependencies...${NC}"

MISSING_SYSTEM_DEPS=()

# Check for libssh2 (required for ssh2 shard)
# Try to compile a simple program that links to libssh2
if ! echo 'int main() { return 0; }' | gcc -x c - -lssh2 -o /tmp/test_ssh2 2>/dev/null; then
    MISSING_SYSTEM_DEPS+=("libssh2-1-dev")
fi
rm -f /tmp/test_ssh2

if [ ${#MISSING_SYSTEM_DEPS[@]} -gt 0 ]; then
    echo -e "${RED}❌ Missing system libraries!${NC}"
    echo ""
    echo -e "${YELLOW}The following system libraries are required:${NC}"
    for dep in "${MISSING_SYSTEM_DEPS[@]}"; do
        echo -e "  ${RED}✗${NC} $dep"
    done
    echo ""
    echo -e "${BLUE}To install on Ubuntu/Debian, run:${NC}"
    echo -e "${GREEN}  sudo apt-get install libssh2-1-dev${NC}"
    echo ""
    echo -e "${BLUE}To install on RHEL/Fedora, run:${NC}"
    echo -e "${GREEN}  sudo dnf install libssh2-devel${NC}"
    echo ""
    echo -e "${BLUE}To install on macOS, run:${NC}"
    echo -e "${GREEN}  brew install libssh2${NC}"
    echo ""
    echo -e "${YELLOW}Then run ./build.sh again${NC}"
    exit 1
fi

echo -e "${GREEN}✅ All system dependencies found${NC}"
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

# Check for crinja (needed for template plugin)
if [ ! -d "lib/crinja" ]; then
    MISSING_DEPS+=("crinja")
fi

# Check for ssh2 (needed for SSH connections)
if [ ! -d "lib/ssh2" ]; then
    MISSING_DEPS+=("ssh2")
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
crystal build crystal-play.cr -o "$OUTPUT_DIR/crystal-ansible" $BUILD_FLAGS
echo -e "${GREEN}✅ Main executable built: $OUTPUT_DIR/crystal-play${NC}"
echo ""

# Build plugins
echo -e "${YELLOW}🔌 Building plugins...${NC}"
PLUGINS=(
    "copy"
    "template"
    "file"
    "lineinfile"
    "service"
    "shell"
    "apt"
    "dnf"
    "package"
)

PLUGIN_COUNT=0
for plugin in "${PLUGINS[@]}"; do
    if [ -f "$plugin.cr" ]; then
        echo -n "   Building $plugin... "
        
        if ! OUTPUT=$(crystal build "$plugin.cr" -o "$PLUGINS_DIR/$plugin" $BUILD_FLAGS 2>&1); then
            echo -e "${RED}✗${NC}"
            echo ""
            echo -e "${RED}❌ Build failed for plugin: $plugin${NC}"
            echo ""
            echo "$OUTPUT"
            echo ""
            echo -e "${YELLOW}Fix the error above and run ./build.sh again${NC}"
            exit 1
        fi
        
        chmod +x "$PLUGINS_DIR/$plugin"
        echo -e "${GREEN}✓${NC}"
        ((PLUGIN_COUNT++))
    else
        echo -e "   ${YELLOW}⚠  Skipping $plugin (not found)${NC}"
    fi
done

echo ""
echo -e "${GREEN}✅ Built $PLUGIN_COUNT plugins${NC}"
echo ""

# Summary
echo -e "${BLUE}╔════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║         Build Complete! 🎉             ║${NC}"
echo -e "${BLUE}╚════════════════════════════════════════╝${NC}"
echo ""
echo -e "${GREEN}Executable:${NC} $OUTPUT_DIR/crystal-play"
echo -e "${GREEN}Plugins:${NC} $PLUGINS_DIR/ ($PLUGIN_COUNT plugins)"
echo ""
echo -e "${YELLOW}Quick Start:${NC}"
echo -e "  ${BLUE}./bin/crystal-play test-facts.yml${NC}"
echo -e "  ${BLUE}./bin/crystal-play --diff test-lineinfile.yml${NC}"
echo -e "  ${BLUE}./bin/crystal-play --check test-handlers.yml${NC}"
echo ""

# Show size information
if command -v du &> /dev/null; then
    TOTAL_SIZE=$(du -sh "$OUTPUT_DIR" | cut -f1)
    echo -e "${YELLOW}Build size:${NC} $TOTAL_SIZE"
fi

echo ""
echo -e "${GREEN}Happy automating! 🚀${NC}"
