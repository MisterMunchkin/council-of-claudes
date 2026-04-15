#!/usr/bin/env bash
# ============================================================================
# Claude Council — Setup
# Installs the /council, /council-init, and /council-persona skills
# ============================================================================

set -euo pipefail

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
RED='\033[0;31m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

log()   { echo -e "${CYAN}[council]${NC} $*"; }
ok()    { echo -e "${GREEN}[council]${NC} $*"; }
warn()  { echo -e "${YELLOW}[council]${NC} $*"; }
error() { echo -e "${RED}[council]${NC} $*" >&2; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILLS_BASE="${HOME}/.claude/skills"
SKILL_DIR="${SKILLS_BASE}/council"
INIT_SKILL_DIR="${SKILLS_BASE}/council-init"
PERSONA_SKILL_DIR="${SKILLS_BASE}/council-persona"
LIST_SKILL_DIR="${SKILLS_BASE}/council-list-sessions"
MIGRATE_SKILL_DIR="${SKILLS_BASE}/council-migrate"

usage() {
    echo ""
    echo -e "${BOLD}Claude Council — Setup${NC}"
    echo ""
    echo "Usage:"
    echo "  ./setup.sh              Install/update the council skills"
    echo "  ./setup.sh --uninstall  Remove the council skills"
    echo "  ./setup.sh --status     Check installation status"
    echo ""
}

# ---------------------------------------------------------------------------
# Status
# ---------------------------------------------------------------------------
cmd_status() {
    echo ""
    echo -e "${BOLD}Claude Council — Status${NC}"
    echo ""

    # Global skills
    echo -e "${BOLD}  Global Skills${NC}"
    for skill in council council-init council-persona council-list-sessions council-migrate; do
        if [ -f "${SKILLS_BASE}/${skill}/SKILL.md" ]; then
            ok "  /${skill} installed"
        else
            warn "  /${skill} not installed"
        fi
    done

    for tmpl in viewer.html dashboard.html; do
        if [ -f "${SKILL_DIR}/templates/${tmpl}" ]; then
            ok "  ${tmpl} template installed"
        else
            warn "  ${tmpl} template missing"
        fi
    done

    # Project-local council
    echo ""
    echo -e "${BOLD}  Current Project${NC}"
    if [ -d ".council/personas" ]; then
        local persona_count
        persona_count=$(ls .council/personas/*.md 2>/dev/null | wc -l | tr -d ' ')
        ok "  Initialized — ${persona_count} personas"
        for f in .council/personas/*.md; do
            [ -f "$f" ] || continue
            local name desc
            name="$(basename "$f" .md)"
            desc="$(head -1 "$f" | sed 's/^#*\s*//' | sed 's/\*//g' | cut -c1-60)"
            echo -e "    ${DIM}•${NC} ${name} — ${DIM}${desc}${NC}"
        done
    else
        warn "  Not initialized — run /council-init in Claude Code"
    fi

    local project_name session_base session_count=0
    project_name="$(basename "$(pwd)")"
    session_base="${HOME}/.council/${project_name}/sessions"
    if [ -d "${session_base}" ]; then
        session_count=$(find "${session_base}" -name "meta.json" 2>/dev/null | wc -l | tr -d ' ')
    fi
    log "  Sessions: ${session_count} in ~/.council/${project_name}/sessions/"

    echo ""
}

# ---------------------------------------------------------------------------
# Uninstall
# ---------------------------------------------------------------------------
cmd_uninstall() {
    echo ""
    log "Removing Claude Council skills..."

    for skill in council council-init council-persona council-list-sessions council-migrate; do
        if [ -d "${SKILLS_BASE}/${skill}" ]; then
            rm -rf "${SKILLS_BASE}/${skill}"
            ok "Removed /${skill}"
        fi
    done

    echo ""
    log "${DIM}Project personas in .council/ were NOT removed.${NC}"
    log "${DIM}Session data in ~/.council/ was NOT removed.${NC}"
    echo ""
}

# ---------------------------------------------------------------------------
# Install
# ---------------------------------------------------------------------------
cmd_install() {
    echo ""
    echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BOLD}       Claude Council — Setup${NC}"
    echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""

    # Prerequisites
    log "Checking prerequisites..."

    if ! command -v claude &>/dev/null; then
        error "Claude Code CLI not found."
        error "Install it: npm install -g @anthropic-ai/claude-code"
        exit 1
    fi
    ok "Claude Code CLI found"

    if ! command -v python3 &>/dev/null; then
        error "Python 3 not found (needed for HTML viewer generation)."
        exit 1
    fi
    ok "Python 3 found"

    # Install skills
    log "Installing skills..."

    mkdir -p "${SKILL_DIR}/templates"
    cp "${SCRIPT_DIR}/skills/council/SKILL.md" "${SKILL_DIR}/SKILL.md"
    ok "/council installed"

    mkdir -p "${INIT_SKILL_DIR}"
    cp "${SCRIPT_DIR}/skills/council-init/SKILL.md" "${INIT_SKILL_DIR}/SKILL.md"
    ok "/council-init installed"

    mkdir -p "${PERSONA_SKILL_DIR}"
    cp "${SCRIPT_DIR}/skills/council-persona/SKILL.md" "${PERSONA_SKILL_DIR}/SKILL.md"
    ok "/council-persona installed"

    mkdir -p "${LIST_SKILL_DIR}"
    cp "${SCRIPT_DIR}/skills/council-list-sessions/SKILL.md" "${LIST_SKILL_DIR}/SKILL.md"
    ok "/council-list-sessions installed"

    mkdir -p "${MIGRATE_SKILL_DIR}"
    cp "${SCRIPT_DIR}/skills/council-migrate/SKILL.md" "${MIGRATE_SKILL_DIR}/SKILL.md"
    ok "/council-migrate installed"


    # HTML templates
    cp "${SCRIPT_DIR}/templates/viewer.html" "${SKILL_DIR}/templates/viewer.html"
    cp "${SCRIPT_DIR}/templates/dashboard.html" "${SKILL_DIR}/templates/dashboard.html"
    ok "HTML templates installed"

    # Summary
    echo ""
    echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}${BOLD}  Council installed${NC}"
    echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -e "  ${BOLD}Skills:${NC}"
    echo -e "    /council          Deliberate on engineering questions"
    echo -e "    /council-init     Bootstrap personas for a project"
    echo -e "    /council-persona  Add a single persona"
    echo -e "    /council-list-sessions  Browse past deliberations"
    echo -e "    /council-migrate  Move old sessions to ~/.council/"
    echo ""
    echo -e "  ${BOLD}Viewer:${NC}  ${SKILL_DIR}/templates/viewer.html"
    echo ""
    echo -e "  ${BOLD}Get started in a project:${NC}"
    echo ""
    echo -e "    /council-init \"I need 3 members who can review our API design\""
    echo -e "    /council \"Should we use REST or GraphQL for the new endpoints?\""
    echo ""
    echo -e "  ${DIM}Personas are stored per-project in .council/personas/${NC}"
    echo -e "  ${DIM}Sessions are stored in ~/.council/{project}/sessions/${NC}"
    echo ""
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
case "${1:-}" in
    --help|-h)     usage ;;
    --status)      cmd_status ;;
    --uninstall)   cmd_uninstall ;;
    *)             cmd_install ;;
esac
