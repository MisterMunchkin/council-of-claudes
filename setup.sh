#!/usr/bin/env bash
# ============================================================================
# Claude Council — Setup Script
# Installs the council skill into your Claude Code environment
# ============================================================================

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

log()   { echo -e "${CYAN}[setup]${NC} $*"; }
ok()    { echo -e "${GREEN}[setup]${NC} $*"; }
warn()  { echo -e "${YELLOW}[setup]${NC} $*"; }
error() { echo -e "${RED}[setup]${NC} $*" >&2; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_SKILLS_DIR="${HOME}/.claude/skills"
COUNCIL_HOME="${HOME}/.council"

echo ""
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BOLD}       Claude Council — Setup${NC}"
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

# Check prerequisites
log "Checking prerequisites..."

if ! command -v claude &>/dev/null; then
    error "Claude Code CLI not found."
    error "Install it: npm install -g @anthropic-ai/claude-code"
    exit 1
fi
ok "Claude Code CLI found: $(which claude)"

if ! command -v jq &>/dev/null; then
    warn "jq not found. Installing..."
    if command -v brew &>/dev/null; then
        brew install jq
    elif command -v apt &>/dev/null; then
        sudo apt install -y jq
    else
        error "Please install jq manually: https://jqlang.github.io/jq/download/"
        exit 1
    fi
fi
ok "jq found: $(which jq)"

# Create directories
log "Creating directories..."
mkdir -p "${CLAUDE_SKILLS_DIR}/council"
mkdir -p "${COUNCIL_HOME}"

# Copy skill files
log "Installing skill files..."
cp -r "${SCRIPT_DIR}/skills/council/SKILL.md" "${CLAUDE_SKILLS_DIR}/council/"
cp -r "${SCRIPT_DIR}/src" "${CLAUDE_SKILLS_DIR}/council/"
cp -r "${SCRIPT_DIR}/personas" "${CLAUDE_SKILLS_DIR}/council/"
cp -r "${SCRIPT_DIR}/prompts" "${CLAUDE_SKILLS_DIR}/council/"
cp -r "${SCRIPT_DIR}/templates" "${CLAUDE_SKILLS_DIR}/council/"

# Make scripts executable
chmod +x "${CLAUDE_SKILLS_DIR}/council/src/council.sh"

# Create convenience symlinks
log "Creating convenience commands..."
SHELL_RC=""
if [ -f "${HOME}/.zshrc" ]; then
    SHELL_RC="${HOME}/.zshrc"
elif [ -f "${HOME}/.bashrc" ]; then
    SHELL_RC="${HOME}/.bashrc"
fi

COUNCIL_BIN="${CLAUDE_SKILLS_DIR}/council/src/council.sh"

# Check if aliases already exist
if [ -n "$SHELL_RC" ]; then
    if ! grep -q "alias council=" "$SHELL_RC" 2>/dev/null; then
        cat >> "$SHELL_RC" <<RCEOF

# Claude Council aliases
alias council='bash ${COUNCIL_BIN}'
alias council-list='bash ${COUNCIL_BIN} list'
alias council-outcome='bash ${COUNCIL_BIN} outcome'
alias council-revisit='bash ${COUNCIL_BIN} revisit'
alias council-nudge='bash ${COUNCIL_BIN} nudge'
RCEOF
        ok "Shell aliases added to ${SHELL_RC}"
        warn "Run: source ${SHELL_RC}  (or open a new terminal)"
    else
        ok "Shell aliases already configured"
    fi
fi

# Create default config
if [ ! -f "${COUNCIL_HOME}/config.json" ]; then
    cat > "${COUNCIL_HOME}/config.json" <<CFGEOF
{
    "timeout_ms": {
        "default": 120000
    },
    "quorum_grace_ms": 30000,
    "proactive": true,
    "personas": {
        "architect": "architect.md",
        "pragmatist": "pragmatist.md",
        "security-perf": "security-perf.md"
    },
    "allowed_tools": "Read,Grep,Glob,Bash(git log *),Bash(git diff *),Bash(git blame *),Bash(git status *),Bash(ls *),Bash(cat *),Bash(find *),Bash(wc *)"
}
CFGEOF
    ok "Default config created: ${COUNCIL_HOME}/config.json"
fi

echo ""
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}${BOLD}  ✓ Claude Council installed successfully!${NC}"
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo "Usage:"
echo ""
echo "  From Claude Code interactive mode:"
echo "    /council \"Should we use Zustand or Jotai?\""
echo ""
echo "  From terminal:"
echo "    council \"Should we use Zustand or Jotai?\""
echo "    council --with-review \"How should we structure auth?\""
echo "    council-list"
echo "    council-nudge SESSION_ID --agent architect --correction \"Can't use Redis\""
echo ""
echo "  Personas:    ${CLAUDE_SKILLS_DIR}/council/personas/"
echo "  Prompts:     ${CLAUDE_SKILLS_DIR}/council/prompts/"
echo "  Sessions:    ${COUNCIL_HOME}/"
echo "  Config:      ${COUNCIL_HOME}/config.json"
echo ""
