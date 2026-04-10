#!/usr/bin/env bash
# ============================================================================
# Claude Council — Multi-session deliberation engine
# Adapted from cliagent-council architecture, using Claude Code sessions only
# ============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
COUNCIL_HOME="${COUNCIL_HOME:-$HOME/.council}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(pwd)"
PROJECT_NAME="$(basename "$PROJECT_DIR")"
SESSION_DIR=""
PERSONAS_DIR="${SCRIPT_DIR}/../personas"
PROMPTS_DIR="${SCRIPT_DIR}/../prompts"
TEMPLATES_DIR="${SCRIPT_DIR}/../templates"

# Defaults
MODE="standard"          # standard | quick | with-review
STREAM=true              # streaming on by default, use --no-stream to disable
QUORUM_GRACE_MS=30000    # 30 seconds grace after quorum
TIMEOUT_MS=120000        # 2 minutes per agent
ALLOWED_TOOLS="Read,Grep,Glob,Bash(git log *),Bash(git diff *),Bash(git blame *),Bash(git status *),Bash(ls *),Bash(cat *),Bash(find *),Bash(wc *)"

# Model selection: Sonnet for fast parallel work, Opus for chairman synthesis
MODEL_COUNCIL="claude-sonnet-4-6"    # Stage 1 opinions + Stage 2 reviews
MODEL_CHAIRMAN="claude-opus-4-6"     # Stage 3 synthesis + Stage 4 nudge

# GitNexus integration (optional — requires gitnexus CLI installed and repo indexed)
USE_NEXUS=false
NEXUS_MCP_CONFIG=""

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m'
BOLD='\033[1m'
DIM='\033[2m'

# Persona config: parallel arrays (bash 3.2 compatible — no associative arrays)
PERSONA_NAMES=("architect" "pragmatist" "security-perf")
PERSONA_FILES=("architect.md" "pragmatist.md" "security-perf.md")
PERSONA_COUNT=${#PERSONA_NAMES[@]}

# ---------------------------------------------------------------------------
# Cleanup trap — kill background processes on Ctrl+C
# ---------------------------------------------------------------------------
BG_PIDS=""
cleanup() {
    echo -e "\n${YELLOW}[council]${NC} Interrupted — cleaning up..."
    if [ -n "$BG_PIDS" ]; then
        for pid in $BG_PIDS; do
            kill "$pid" 2>/dev/null || true
        done
    fi
    # Restore cursor in case stream monitor hid it
    printf '\033[?25h'
    exit 130
}
trap cleanup INT TERM

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
log()   { echo -e "${CYAN}[council]${NC} $*"; }
warn()  { echo -e "${YELLOW}[council]${NC} $*"; }
error() { echo -e "${RED}[council]${NC} $*" >&2; }
ok()    { echo -e "${GREEN}[council]${NC} $*"; }

timestamp() { date +%s; }

ensure_deps() {
    if ! command -v claude &>/dev/null; then
        error "Claude Code CLI not found. Install it first: npm install -g @anthropic-ai/claude-code"
        exit 1
    fi
    if ! command -v jq &>/dev/null; then
        error "jq not found. Install it: brew install jq (macOS) or apt install jq (Linux)"
        exit 1
    fi
}

setup_nexus() {
    # Check if GitNexus is available and the repo is indexed
    if ! command -v gitnexus &>/dev/null; then
        warn "GitNexus CLI not found. Install: npm install -g gitnexus"
        warn "Falling back to standard tools (grep/read)."
        USE_NEXUS=false
        return
    fi

    if [ ! -d "${PROJECT_DIR}/.gitnexus" ]; then
        log "GitNexus index not found. Indexing repository..."
        (cd "$PROJECT_DIR" && gitnexus analyze . 2>/dev/null) || {
            warn "GitNexus indexing failed. Falling back to standard tools."
            USE_NEXUS=false
            return
        }
        ok "GitNexus index created."
    fi

    # Create a temporary MCP config for the GitNexus server
    NEXUS_MCP_CONFIG="${SESSION_DIR}/nexus_mcp.json"
    cat > "$NEXUS_MCP_CONFIG" <<MCPEOF
{
  "mcpServers": {
    "gitnexus": {
      "command": "gitnexus",
      "args": ["mcp"]
    }
  }
}
MCPEOF

    ok "GitNexus enabled — agents will use knowledge graph for codebase queries."
}

nexus_args() {
    # Returns extra claude -p flags when GitNexus is active
    if [ "$USE_NEXUS" = true ] && [ -n "$NEXUS_MCP_CONFIG" ] && [ -f "$NEXUS_MCP_CONFIG" ]; then
        echo "--mcp-config $NEXUS_MCP_CONFIG"
    fi
}

init_session() {
    local session_id
    session_id="$(date +%Y%m%d_%H%M%S)_$(openssl rand -hex 4)"
    SESSION_DIR="${COUNCIL_HOME}/${PROJECT_NAME}/${session_id}"
    mkdir -p "${SESSION_DIR}/stage1" "${SESSION_DIR}/stage2" "${SESSION_DIR}/stage3" "${SESSION_DIR}/stage4"

    # Save metadata
    cat > "${SESSION_DIR}/meta.json" <<METAEOF
{
    "id": "${session_id}",
    "project": "${PROJECT_NAME}",
    "project_dir": "${PROJECT_DIR}",
    "question": $(echo "$QUESTION" | jq -Rs .),
    "mode": "${MODE}",
    "personas": $(printf '%s\n' "${PERSONA_NAMES[@]}" | jq -R . | jq -s .),
    "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
    "status": "in_progress"
}
METAEOF

    log "Session: ${session_id}"
    log "Stored:  ${SESSION_DIR}"
}

load_prompt() {
    local stage_file="$1"
    local prompt
    prompt="$(cat "${PROMPTS_DIR}/${stage_file}")"
    echo "$prompt"
}

load_persona() {
    local persona_file="$1"
    cat "${PERSONAS_DIR}/${persona_file}"
}

substitute() {
    # Replace {{PLACEHOLDER}} in a string with a value
    local template="$1"
    local placeholder="$2"
    local value="$3"
    echo "${template//\{\{${placeholder}\}\}/${value}}"
}

# Persona color for stream labels
persona_color() {
    case "$1" in
        architect)     echo "$BLUE" ;;
        pragmatist)    echo "$GREEN" ;;
        security-perf) echo "$RED" ;;
        *)             echo "$PURPLE" ;;
    esac
}

persona_icon() {
    case "$1" in
        architect)     echo "🏗️" ;;
        pragmatist)    echo "🚀" ;;
        security-perf) echo "🛡️" ;;
        *)             echo "🤖" ;;
    esac
}

# ---------------------------------------------------------------------------
# Stream monitor — uses a single python process to tail all stream files
# with colored labels, handling partial lines and interleaved output cleanly
# ---------------------------------------------------------------------------
stream_monitor() {
    local stream_dir="$1"

    log ""
    log "${BOLD}━━━ Live Council Stream ━━━${NC}"
    log ""

    # Call the standalone Python monitor with agent names as args
    python3 "${SCRIPT_DIR}/stream_monitor.py" "$stream_dir" "${PERSONA_NAMES[@]}" || true

    log "${BOLD}━━━ Stream Complete ━━━${NC}"
    log ""
}

# ---------------------------------------------------------------------------
# Stage 1: Independent Opinions (parallel)
# ---------------------------------------------------------------------------
run_stage1() {
    log ""
    log "${BOLD}━━━ Stage 1: Independent Opinions ━━━${NC}"
    log "Dispatching ${PERSONA_COUNT} council members in parallel..."
    log ""

    local pids=()
    local names=()
    local stream_dir="${SESSION_DIR}/streams"
    mkdir -p "$stream_dir"

    for i in $(seq 0 $((PERSONA_COUNT - 1))); do
        local persona_name="${PERSONA_NAMES[$i]}"
        local persona_file="${PERSONA_FILES[$i]}"
        local persona_prompt
        persona_prompt="$(load_persona "$persona_file")"

        local stage1_template
        stage1_template="$(load_prompt "stage1-opinion.md")"

        # Build the full prompt
        local full_prompt
        full_prompt="$(substitute "$stage1_template" "QUESTION" "$QUESTION")"
        full_prompt="$(substitute "$full_prompt" "PERSONA" "$persona_prompt")"

        local output_file="${SESSION_DIR}/stage1/opinion_${persona_name}.json"
        local stream_file="${stream_dir}/${persona_name}.stream"
        local pid_file="${stream_dir}/${persona_name}.pid"

        # Initialize stream file
        : > "$stream_file"

        log "  ${PURPLE}▶${NC} ${persona_name} starting..."

        # Launch Claude Code in headless mode, in background
        (
            # Write our PID so the monitor can check if we're alive
            echo $$ > "$pid_file"

            if [ "$STREAM" = true ]; then
                # ── Streaming mode ──
                # Use stream-json with --include-partial-messages to get
                # token-level text_delta events. A single python process
                # handles all parsing (much faster than per-line jq).
                local raw_stream="${stream_dir}/${persona_name}.raw"

                claude -p "$full_prompt" \
                    --model "$MODEL_COUNCIL" \
                    --output-format stream-json \
                    --verbose \
                    --include-partial-messages \
                    --allowedTools "$ALLOWED_TOOLS" \
                    $(nexus_args) \
                    --append-system-prompt "You are participating in a council deliberation. Output ONLY valid JSON. No markdown fences. No preamble. No explanation outside the JSON. FORMATTING: Use markdown in JSON string values — backticks for code/file refs, **bold** for key terms, *italics* for emphasis. Describe findings in concise prose. Do NOT paste raw code blocks, grep output, or file contents into JSON values." \
                    2>/dev/null \
                | tee "$raw_stream" \
                | python3 -u -c "
import sys, json

sf = open('${stream_file}', 'a', buffering=1)
for raw in sys.stdin:
    raw = raw.strip()
    if not raw:
        continue
    try:
        obj = json.loads(raw)
    except:
        continue
    t = obj.get('type', '')
    if t == 'stream_event':
        ev = obj.get('event', {})
        delta = ev.get('delta', {})
        # Text tokens
        if delta.get('type') == 'text_delta':
            text = delta.get('text', '')
            if text:
                sf.write(text)
                sf.flush()
        # Tool use start
        if ev.get('type') == 'content_block_start':
            cb = ev.get('content_block', {})
            if cb.get('type') == 'tool_use':
                name = cb.get('name', '?')
                sf.write(f'\n🔧 [using {name}...]\n')
                sf.flush()
            elif cb.get('type') == 'tool_result':
                sf.write('\n')
                sf.flush()
sf.close()
" || true

                # Extract the final result from the raw stream
                local result_line
                result_line=$(grep '"type":"result"' "$raw_stream" 2>/dev/null | tail -1) || true

                local opinion=""
                if [ -n "$result_line" ]; then
                    opinion=$(echo "$result_line" | jq -r '.result // empty' 2>/dev/null) || true
                fi

                # If we couldn't get it from the result line, try the accumulated text
                if [ -z "$opinion" ] || [ "$opinion" = "null" ]; then
                    opinion=$(cat "$stream_file" 2>/dev/null) || true
                fi
            else
                # ── Non-streaming mode (original behavior) ──
                local result
                result=$(claude -p "$full_prompt" \
                    --model "$MODEL_COUNCIL" \
                    --output-format json \
                    --allowedTools "$ALLOWED_TOOLS" \
                    $(nexus_args) \
                    --append-system-prompt "You are participating in a council deliberation. Output ONLY valid JSON. No markdown fences. No preamble. No explanation outside the JSON. FORMATTING: Use markdown in JSON string values — backticks for code/file refs, **bold** for key terms, *italics* for emphasis. Describe findings in concise prose. Do NOT paste raw code blocks, grep output, or file contents into JSON values." \
                    2>/dev/null) || true

                local opinion
                opinion=$(echo "$result" | jq -r '.result // empty' 2>/dev/null) || opinion="$result"
            fi

            # Try to parse as JSON, wrap if needed
            if echo "$opinion" | jq . &>/dev/null; then
                echo "$opinion" > "$output_file"
            else
                # Try to extract JSON from within the text
                local extracted
                extracted=$(echo "$opinion" | grep -o '{.*}' | head -1) || true
                if [ -n "$extracted" ] && echo "$extracted" | jq . &>/dev/null; then
                    echo "$extracted" > "$output_file"
                else
                    # Wrap raw text as JSON
                    jq -n --arg rec "$opinion" '{recommendation: $rec, reasoning: ["Raw response - could not parse structured output"], confidence: 0.5}' > "$output_file"
                fi
            fi

            # Mark stream as done
            printf '\n━━━ done ━━━\n' >> "$stream_file"
            ok "  ${GREEN}✓${NC} ${persona_name} completed"
        ) &

        pids+=($!)
        names+=("$persona_name")
        BG_PIDS="$BG_PIDS $!"

        # Also save the real PID for the monitor (bash 3.2 compatible — no negative indexing)
        echo "$!" > "$pid_file"
    done

    if [ "$STREAM" = true ]; then
        # Stream monitor blocks until all agents finish (with its own timeout)
        stream_monitor "$stream_dir"
        # Just wait for background jobs to clean up
        for pid in "${pids[@]}"; do
            wait "$pid" 2>/dev/null || true
        done
    else
        # Non-streaming: quorum-based waiting with grace window
        local completed=0
        local quorum_reached=false
        local quorum_time=0

        while true; do
            completed=0
            for i in "${!pids[@]}"; do
                if ! kill -0 "${pids[$i]}" 2>/dev/null; then
                    ((completed++))
                fi
            done

            if [ "$completed" -ge 2 ] && [ "$quorum_reached" = false ]; then
                quorum_reached=true
                quorum_time=$(timestamp)
                log "  Quorum reached (${completed}/${PERSONA_COUNT}). Grace window: $((QUORUM_GRACE_MS / 1000))s for stragglers."
            fi

            if [ "$completed" -eq "${PERSONA_COUNT}" ]; then
                break
            fi

            if [ "$quorum_reached" = true ]; then
                local elapsed=$(( $(timestamp) - quorum_time ))
                if [ "$elapsed" -ge $((QUORUM_GRACE_MS / 1000)) ]; then
                    warn "  Grace window expired. Proceeding with ${completed}/${PERSONA_COUNT} opinions."
                    for pid in "${pids[@]}"; do
                        kill "$pid" 2>/dev/null || true
                    done
                    break
                fi
            fi

            sleep 2
        done

        # Wait for all background jobs to finish
        for pid in "${pids[@]}"; do
            wait "$pid" 2>/dev/null || true
        done
    fi

    # Report results
    local opinion_count
    opinion_count=$(ls "${SESSION_DIR}/stage1/"opinion_*.json 2>/dev/null | wc -l)
    ok "Stage 1 complete: ${opinion_count} opinions collected."
    echo ""
}

# ---------------------------------------------------------------------------
# Stage 2: Peer Review (optional, parallel)
# ---------------------------------------------------------------------------
run_stage2() {
    if [ "$MODE" != "with-review" ]; then
        log "Skipping Stage 2 (use --with-review to enable)"
        return
    fi

    log ""
    log "${BOLD}━━━ Stage 2: Anonymized Peer Review ━━━${NC}"
    log ""

    # Collect and anonymize opinions
    local opinions_text=""
    local agent_labels=("A" "B" "C" "D" "E")
    local idx=0

    for opinion_file in "${SESSION_DIR}"/stage1/opinion_*.json; do
        local label="${agent_labels[$idx]}"
        local opinion_content
        opinion_content="$(cat "$opinion_file")"
        opinions_text="${opinions_text}\n\n### Agent ${label}'s Opinion:\n${opinion_content}"
        ((idx++))
    done

    local review_template
    review_template="$(load_prompt "stage2-review.md")"

    local pids=()

    for i in $(seq 0 $((PERSONA_COUNT - 1))); do
        local persona_name="${PERSONA_NAMES[$i]}"
        local full_prompt
        full_prompt="$(substitute "$review_template" "QUESTION" "$QUESTION")"
        full_prompt="$(substitute "$full_prompt" "OPINIONS" "$opinions_text")"

        local output_file="${SESSION_DIR}/stage2/review_${persona_name}.json"

        log "  ${PURPLE}▶${NC} ${persona_name} reviewing..."

        (
            local result
            result=$(claude -p "$full_prompt" \
                --model "$MODEL_COUNCIL" \
                --output-format json \
                --allowedTools "$ALLOWED_TOOLS" \
                $(nexus_args) \
                --append-system-prompt "You are peer-reviewing council opinions. Output ONLY valid JSON. No markdown fences. No preamble. FORMATTING: Use markdown in JSON string values — backticks for code/file refs, **bold** for key terms, *italics* for emphasis. Write strengths and weaknesses as complete, well-formatted sentences." \
                2>/dev/null) || true

            local review
            review=$(echo "$result" | jq -r '.result // empty' 2>/dev/null) || review="$result"

            if echo "$review" | jq . &>/dev/null; then
                echo "$review" > "$output_file"
            else
                local extracted
                extracted=$(echo "$review" | grep -o '{.*}' | head -1) || true
                if [ -n "$extracted" ] && echo "$extracted" | jq . &>/dev/null; then
                    echo "$extracted" > "$output_file"
                else
                    jq -n --arg raw "$review" '{reviews: [], raw_response: $raw}' > "$output_file"
                fi
            fi

            ok "  ${GREEN}✓${NC} ${persona_name} review done"
        ) &

        pids+=($!)
    done

    for pid in "${pids[@]}"; do
        wait "$pid" 2>/dev/null || true
    done

    ok "Stage 2 complete."
    echo ""
}

# ---------------------------------------------------------------------------
# Stage 3: Chairman Synthesis
# ---------------------------------------------------------------------------
run_stage3() {
    log ""
    log "${BOLD}━━━ Stage 3: Chairman Synthesis ━━━${NC}"
    log ""

    # Collect all opinions with agent names
    local opinions_text=""
    for opinion_file in "${SESSION_DIR}"/stage1/opinion_*.json; do
        local agent_name
        agent_name="$(basename "$opinion_file" .json | sed 's/opinion_//')"
        local opinion_content
        opinion_content="$(cat "$opinion_file")"
        opinions_text="${opinions_text}\n\n### ${agent_name}'s Opinion:\n${opinion_content}"
    done

    # Collect reviews if they exist
    local reviews_text="No peer reviews conducted."
    if [ -d "${SESSION_DIR}/stage2" ] && ls "${SESSION_DIR}"/stage2/review_*.json &>/dev/null; then
        reviews_text=""
        for review_file in "${SESSION_DIR}"/stage2/review_*.json; do
            local reviewer
            reviewer="$(basename "$review_file" .json | sed 's/review_//')"
            local review_content
            review_content="$(cat "$review_file")"
            reviews_text="${reviews_text}\n\n### ${reviewer}'s Review:\n${review_content}"
        done
    fi

    local synthesis_template
    synthesis_template="$(load_prompt "stage3-synthesis.md")"

    local full_prompt
    full_prompt="$(substitute "$synthesis_template" "QUESTION" "$QUESTION")"
    full_prompt="$(substitute "$full_prompt" "OPINIONS" "$opinions_text")"
    full_prompt="$(substitute "$full_prompt" "REVIEWS" "$reviews_text")"

    log "  ${PURPLE}▶${NC} Chairman synthesizing..."

    local result
    result=$(claude -p "$full_prompt" \
        --model "$MODEL_CHAIRMAN" \
        --output-format json \
        --allowedTools "$ALLOWED_TOOLS" \
        $(nexus_args) \
        --append-system-prompt "You are the Chairman synthesizing a council deliberation. Output ONLY valid JSON. No markdown fences. No preamble. FORMATTING: Use markdown in JSON string values — backticks for code/file refs, **bold** for key terms, *italics* for emphasis. Write as if briefing a team lead — concise, actionable, well-formatted. CRITICAL: Each item in action_items MUST be an object with these exact fields: {priority: 'high'|'medium'|'low', type: 'action'|'note', action: 'description', ai_prompt: 'full prompt for Claude Code session' or null for notes}. NEVER use plain strings for action_items." \
        2>/dev/null) || true

    local synthesis
    synthesis=$(echo "$result" | jq -r '.result // empty' 2>/dev/null) || synthesis="$result"

    if echo "$synthesis" | jq . &>/dev/null; then
        echo "$synthesis" > "${SESSION_DIR}/synthesis.json"
    else
        local extracted
        extracted=$(echo "$synthesis" | grep -o '{.*}' | head -1) || true
        if [ -n "$extracted" ] && echo "$extracted" | jq . &>/dev/null; then
            echo "$extracted" > "${SESSION_DIR}/synthesis.json"
        else
            jq -n --arg raw "$synthesis" '{verdict: $raw, confidence_scores: {overall: 0.5}}' > "${SESSION_DIR}/synthesis.json"
        fi
    fi

    ok "Stage 3 complete. Verdict rendered."
    echo ""
}

# ---------------------------------------------------------------------------
# Generate Viewer
# ---------------------------------------------------------------------------
generate_viewer() {
    log "Generating session viewer..."

    # ── Build opinions JSON object using jq ──
    # Start with empty object, merge each opinion file in
    local opinions_json="{}"
    for opinion_file in "${SESSION_DIR}"/stage1/opinion_*.json; do
        [ -f "$opinion_file" ] || continue
        local agent_name
        agent_name="$(basename "$opinion_file" .json | sed 's/opinion_//')"

        # Validate the file is valid JSON; if not, wrap it
        local valid_content
        if jq . "$opinion_file" &>/dev/null; then
            valid_content="$(jq -c . "$opinion_file")"
        else
            valid_content=$(jq -n --arg raw "$(cat "$opinion_file")" \
                '{recommendation: $raw, reasoning: ["Could not parse original output"], confidence: 0.5}')
        fi

        opinions_json=$(echo "$opinions_json" | jq --arg k "$agent_name" --argjson v "$valid_content" '. + {($k): $v}')
    done

    # ── Build synthesis JSON ──
    local synthesis_json="{}"
    if [ -f "${SESSION_DIR}/synthesis.json" ]; then
        if jq . "${SESSION_DIR}/synthesis.json" &>/dev/null; then
            synthesis_json="$(jq -c . "${SESSION_DIR}/synthesis.json")"
        else
            synthesis_json=$(jq -n --arg raw "$(cat "${SESSION_DIR}/synthesis.json")" \
                '{verdict: $raw, confidence_scores: {overall: 0.5}}')
        fi
    fi

    # ── Build reviews JSON object ──
    local reviews_json="{}"
    if ls "${SESSION_DIR}"/stage2/review_*.json &>/dev/null 2>&1; then
        for review_file in "${SESSION_DIR}"/stage2/review_*.json; do
            [ -f "$review_file" ] || continue
            local reviewer
            reviewer="$(basename "$review_file" .json | sed 's/review_//')"

            local valid_review
            if jq . "$review_file" &>/dev/null; then
                valid_review="$(jq -c . "$review_file")"
            else
                valid_review=$(jq -n --arg raw "$(cat "$review_file")" '{reviews: [], raw_response: $raw}')
            fi

            reviews_json=$(echo "$reviews_json" | jq --arg k "$reviewer" --argjson v "$valid_review" '. + {($k): $v}')
        done
    fi

    local meta_json
    meta_json="$(jq -c . "${SESSION_DIR}/meta.json")"

    # ── Inject JSON into HTML template using Python (sed breaks on large JSON) ──
    # IMPORTANT: Escape </ sequences to prevent </script> in JSON data from
    # prematurely terminating the script block in the HTML parser.
    python3 -c "
import sys, json

def safe_for_script(s):
    \"\"\"Escape sequences that break HTML script blocks.\"\"\"
    return s.replace('</', '<\\\\/')

template = open(sys.argv[1]).read()
template = template.replace('__META_JSON__',      safe_for_script(sys.argv[2]))
template = template.replace('__OPINIONS_JSON__',   safe_for_script(sys.argv[3]))
template = template.replace('__SYNTHESIS_JSON__',  safe_for_script(sys.argv[4]))
template = template.replace('__REVIEWS_JSON__',    safe_for_script(sys.argv[5]))

with open(sys.argv[6], 'w') as f:
    f.write(template)
" \
        "${TEMPLATES_DIR}/viewer.html" \
        "$meta_json" \
        "$(echo "$opinions_json" | jq -c .)" \
        "$(echo "$synthesis_json" | jq -c .)" \
        "$(echo "$reviews_json" | jq -c .)" \
        "${SESSION_DIR}/viewer.html"

    ok "Viewer: ${SESSION_DIR}/viewer.html"
}

# ---------------------------------------------------------------------------
# Interactive Follow-Up (Stage 5)
# ---------------------------------------------------------------------------
run_followup() {
    local followup_dir="${SESSION_DIR}/stage5"
    mkdir -p "$followup_dir"

    local opinions_text=""
    for f in "${SESSION_DIR}"/stage1/opinion_*.json; do
        [ -f "$f" ] || continue
        local aname
        aname="$(basename "$f" .json | sed 's/opinion_//')"
        opinions_text="${opinions_text}\n\n### ${aname}:\n$(cat "$f")"
    done

    local synthesis_text
    synthesis_text="$(cat "${SESSION_DIR}/synthesis.json" 2>/dev/null || echo '{}')"

    local followup_template
    followup_template="$(load_prompt "stage5-followup.md")"

    local delegate_template
    delegate_template="$(load_prompt "stage5-delegate.md")"

    local history=""
    local turn=0

    echo ""
    log "${BOLD}━━━ Council Follow-Up ━━━${NC}"
    log "${DIM}Ask the chairman anything about the verdict. Type ${NC}${BOLD}q${NC}${DIM} or ${NC}${BOLD}done${NC}${DIM} to exit.${NC}"
    echo ""

    while true; do
        # Read user input
        printf "  ${CYAN}${BOLD}You ▸${NC} "
        local user_input
        read -r user_input

        # Exit conditions
        if [ -z "$user_input" ]; then
            continue
        fi
        if [ "$user_input" = "q" ] || [ "$user_input" = "done" ] || [ "$user_input" = "exit" ]; then
            echo ""
            log "${DIM}Follow-up session ended.${NC}"
            break
        fi

        turn=$((turn + 1))

        # Build the chairman prompt
        local full_prompt
        full_prompt="$(substitute "$followup_template" "QUESTION" "$QUESTION")"
        full_prompt="$(substitute "$full_prompt" "OPINIONS" "$opinions_text")"
        full_prompt="$(substitute "$full_prompt" "SYNTHESIS" "$synthesis_text")"
        full_prompt="$(substitute "$full_prompt" "FOLLOWUP_HISTORY" "$history")"
        full_prompt="$(substitute "$full_prompt" "USER_INPUT" "$user_input")"
        full_prompt="$(substitute "$full_prompt" "AGENT_NAMES" "${PERSONA_NAMES[*]}")"

        echo ""
        log "  ${PURPLE}▶${NC} Chairman thinking..."

        local result
        result=$(claude -p "$full_prompt" \
            --model "$MODEL_CHAIRMAN" \
            --output-format json \
            --allowedTools "$ALLOWED_TOOLS" \
            $(nexus_args) \
            --append-system-prompt "You are the Chairman responding to a follow-up. Output ONLY valid JSON. No markdown fences." \
            2>/dev/null) || true

        local response
        response=$(echo "$result" | jq -r '.result // empty' 2>/dev/null) || response="$result"

        # Try to parse JSON from the response
        local parsed=""
        if echo "$response" | jq . &>/dev/null; then
            parsed="$response"
        else
            local extracted
            extracted=$(echo "$response" | grep -o '{.*}' | head -1) || true
            if [ -n "$extracted" ] && echo "$extracted" | jq . &>/dev/null; then
                parsed="$extracted"
            fi
        fi

        local mode
        mode=$(echo "$parsed" | jq -r '.mode // "direct"' 2>/dev/null) || mode="direct"

        if [ "$mode" = "delegate" ]; then
            # ── Chairman is delegating to a council member ──
            local delegate_to delegate_reason delegate_question
            delegate_to=$(echo "$parsed" | jq -r '.delegate_to // ""' 2>/dev/null)
            delegate_reason=$(echo "$parsed" | jq -r '.reason // ""' 2>/dev/null)
            delegate_question=$(echo "$parsed" | jq -r '.refined_question // ""' 2>/dev/null)

            log "  ${YELLOW}↳${NC} Chairman delegating to ${BOLD}${delegate_to}${NC}: ${DIM}${delegate_reason}${NC}"

            # Find the agent's persona
            local persona_file=""
            for i in $(seq 0 $((PERSONA_COUNT - 1))); do
                if [ "${PERSONA_NAMES[$i]}" = "$delegate_to" ]; then
                    persona_file="${PERSONA_FILES[$i]}"
                    break
                fi
            done

            if [ -n "$persona_file" ]; then
                local persona_prompt
                persona_prompt="$(load_persona "$persona_file")"

                local original_opinion
                original_opinion="$(cat "${SESSION_DIR}/stage1/opinion_${delegate_to}.json" 2>/dev/null || echo '{}')"

                local delegate_prompt
                delegate_prompt="$(substitute "$delegate_template" "QUESTION" "$QUESTION")"
                delegate_prompt="$(substitute "$delegate_prompt" "ORIGINAL_OPINION" "$original_opinion")"
                delegate_prompt="$(substitute "$delegate_prompt" "SYNTHESIS" "$synthesis_text")"
                delegate_prompt="$(substitute "$delegate_prompt" "DELEGATE_REASON" "$delegate_reason")"
                delegate_prompt="$(substitute "$delegate_prompt" "DELEGATE_QUESTION" "$delegate_question")"

                log "  ${PURPLE}▶${NC} ${delegate_to} responding..."

                local d_result
                d_result=$(claude -p "$delegate_prompt" \
                    --model "$MODEL_COUNCIL" \
                    --output-format json \
                    --allowedTools "$ALLOWED_TOOLS" \
                    $(nexus_args) \
                    --append-system-prompt "${persona_prompt}\n\nOutput ONLY valid JSON. No markdown fences. FORMATTING: Use markdown in JSON string values." \
                    2>/dev/null) || true

                local d_response
                d_response=$(echo "$d_result" | jq -r '.result // empty' 2>/dev/null) || d_response="$d_result"

                local d_parsed=""
                if echo "$d_response" | jq . &>/dev/null; then
                    d_parsed="$d_response"
                else
                    local d_extracted
                    d_extracted=$(echo "$d_response" | grep -o '{.*}' | head -1) || true
                    if [ -n "$d_extracted" ] && echo "$d_extracted" | jq . &>/dev/null; then
                        d_parsed="$d_extracted"
                    fi
                fi

                # Save delegate response
                echo "$d_parsed" > "${followup_dir}/followup_${turn}_delegate_${delegate_to}.json"

                # Display
                local style_icon style_color
                case "$delegate_to" in
                    architect)      style_icon="🏗️ "; style_color="$BLUE" ;;
                    pragmatist)     style_icon="🚀"; style_color="$GREEN" ;;
                    security-perf)  style_icon="🛡️ "; style_color="$RED" ;;
                    *)              style_icon="🤖"; style_color="$PURPLE" ;;
                esac

                echo ""
                local d_resp_text
                d_resp_text=$(echo "$d_parsed" | jq -r '.response // empty' 2>/dev/null) || d_resp_text="$d_response"
                echo -e "  ${style_color}${BOLD}${style_icon} ${delegate_to}${NC}"
                python3 -c "
import sys, re, textwrap
BOLD, RESET, CYAN, ITALIC, DIM = '\033[1m', '\033[0m', '\033[0;36m', '\033[3m', '\033[2m'
s = sys.argv[1]
s = re.sub(r'\`([^\`\n]+)\`', CYAN + r'\1' + RESET, s)
s = re.sub(r'\*\*([^*]+)\*\*', BOLD + r'\1' + RESET, s)
s = re.sub(r'(?<!\*)\*([^*]+)\*(?!\*)', ITALIC + r'\1' + RESET, s)
for line in s.split('\n'):
    wrapped = textwrap.fill(line, width=90, initial_indent='    ', subsequent_indent='    ')
    print(wrapped)
" "$d_resp_text"

                # Show key points if present
                local kp
                kp=$(echo "$d_parsed" | jq -r '.key_points[]? // empty' 2>/dev/null) || true
                if [ -n "$kp" ]; then
                    echo ""
                    echo -e "    ${BOLD}Key points:${NC}"
                    echo "$kp" | while read -r point; do
                        echo -e "    ${DIM}•${NC} $point"
                    done
                fi

                # Add to history
                history="${history}\n\n[Turn ${turn}] User: ${user_input}\nChairman delegated to ${delegate_to}: ${delegate_reason}\n${delegate_to}'s response: ${d_resp_text}"
            else
                log "  ${RED}Unknown agent: ${delegate_to}${NC}"
            fi
        else
            # ── Chairman answering directly ──
            local resp_text
            resp_text=$(echo "$parsed" | jq -r '.response // empty' 2>/dev/null) || resp_text="$response"

            # Save response
            echo "$parsed" > "${followup_dir}/followup_${turn}_chairman.json"

            echo ""
            echo -e "  ${BOLD}⚖️  Chairman${NC}"
            python3 -c "
import sys, re, textwrap
BOLD, RESET, CYAN, ITALIC, DIM = '\033[1m', '\033[0m', '\033[0;36m', '\033[3m', '\033[2m'
s = sys.argv[1]
s = re.sub(r'\`([^\`\n]+)\`', CYAN + r'\1' + RESET, s)
s = re.sub(r'\*\*([^*]+)\*\*', BOLD + r'\1' + RESET, s)
s = re.sub(r'(?<!\*)\*([^*]+)\*(?!\*)', ITALIC + r'\1' + RESET, s)
for line in s.split('\n'):
    wrapped = textwrap.fill(line, width=90, initial_indent='    ', subsequent_indent='    ')
    print(wrapped)
" "$resp_text"

            # Show references if present
            local refs
            refs=$(echo "$parsed" | jq -r '.references[]? // empty' 2>/dev/null) || true
            if [ -n "$refs" ]; then
                echo ""
                echo -e "    ${DIM}Referenced: ${refs}${NC}"
            fi

            # Add to history
            history="${history}\n\n[Turn ${turn}] User: ${user_input}\nChairman: ${resp_text}"
        fi

        echo ""
    done
}

# ---------------------------------------------------------------------------
# Print Summary
# ---------------------------------------------------------------------------
print_summary() {
    # Hand off to the Python results viewer for formatted output + interactive browsing
    python3 "${SCRIPT_DIR}/results_viewer.py" "${SESSION_DIR}"
}

# ---------------------------------------------------------------------------
# Subcommands
# ---------------------------------------------------------------------------
cmd_nudge() {
    local session_id="$1"
    local agent_name="$2"
    local correction="$3"

    local target_session="${COUNCIL_HOME}/${PROJECT_NAME}/${session_id}"
    if [ ! -d "$target_session" ]; then
        error "Session not found: ${session_id}"
        exit 1
    fi

    local original_question
    original_question=$(jq -r '.question' "${target_session}/meta.json")

    local original_opinion
    original_opinion="$(cat "${target_session}/stage1/opinion_${agent_name}.json" 2>/dev/null || echo '{}')"

    local nudge_template
    nudge_template="$(load_prompt "stage4-nudge.md")"

    # Find the persona file for this agent
    local persona_file=""
    for i in $(seq 0 $((PERSONA_COUNT - 1))); do
        if [ "${PERSONA_NAMES[$i]}" = "$agent_name" ]; then
            persona_file="${PERSONA_FILES[$i]}"
            break
        fi
    done
    if [ -z "$persona_file" ]; then
        error "Unknown agent: ${agent_name}. Available: ${PERSONA_NAMES[*]}"
        exit 1
    fi
    local persona_prompt
    persona_prompt="$(load_persona "$persona_file")"

    local full_prompt
    full_prompt="$(substitute "$nudge_template" "QUESTION" "$original_question")"
    full_prompt="$(substitute "$full_prompt" "ORIGINAL_OPINION" "$original_opinion")"
    full_prompt="$(substitute "$full_prompt" "CORRECTION" "$correction")"

    log "Nudging ${agent_name} with correction..."

    local result
    result=$(claude -p "$full_prompt" \
        --model "$MODEL_CHAIRMAN" \
        --output-format json \
        --allowedTools "$ALLOWED_TOOLS" \
        $(nexus_args) \
        --append-system-prompt "${persona_prompt}\n\nOutput ONLY valid JSON. No markdown fences." \
        2>/dev/null) || true

    local nudge_response
    nudge_response=$(echo "$result" | jq -r '.result // empty' 2>/dev/null) || nudge_response="$result"

    local nudge_file="${target_session}/stage4/nudge_${agent_name}_$(date +%s).json"

    if echo "$nudge_response" | jq . &>/dev/null; then
        echo "$nudge_response" > "$nudge_file"
    else
        jq -n --arg raw "$nudge_response" '{updated_recommendation: $raw, changed: true}' > "$nudge_file"
    fi

    ok "Nudge saved: ${nudge_file}"
    echo ""
    jq . "$nudge_file"
}

cmd_list() {
    local project_dir="${COUNCIL_HOME}/${PROJECT_NAME}"
    if [ ! -d "$project_dir" ]; then
        log "No sessions found for project: ${PROJECT_NAME}"
        return
    fi

    log "${BOLD}Sessions for ${PROJECT_NAME}:${NC}"
    echo ""

    for session_dir in "${project_dir}"/*/; do
        if [ -f "${session_dir}/meta.json" ]; then
            local sid question ts status
            sid=$(jq -r '.id' "${session_dir}/meta.json")
            question=$(jq -r '.question' "${session_dir}/meta.json" | head -c 80)
            ts=$(jq -r '.timestamp' "${session_dir}/meta.json")
            status=$(jq -r '.status // "unknown"' "${session_dir}/meta.json")

            local status_icon="⏳"
            [ "$status" = "completed" ] && status_icon="✅"
            [ "$status" = "outcome_recorded" ] && status_icon="📋"

            echo -e "  ${status_icon} ${BOLD}${sid}${NC}"
            echo -e "     ${question}"
            echo -e "     ${CYAN}${ts}${NC}"
            echo ""
        fi
    done
}

cmd_outcome() {
    local session_id="$1"
    local outcome="$2"

    local target_session="${COUNCIL_HOME}/${PROJECT_NAME}/${session_id}"
    if [ ! -d "$target_session" ]; then
        error "Session not found: ${session_id}"
        exit 1
    fi

    local tmp
    tmp=$(mktemp)
    jq --arg o "$outcome" --arg t "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        '.status = "outcome_recorded" | .outcome = $o | .outcome_recorded_at = $t' \
        "${target_session}/meta.json" > "$tmp" && mv "$tmp" "${target_session}/meta.json"

    ok "Outcome recorded for session ${session_id}"
}

cmd_revisit() {
    local session_id="$1"
    local target_session="${COUNCIL_HOME}/${PROJECT_NAME}/${session_id}"

    if [ ! -d "$target_session" ]; then
        error "Session not found: ${session_id}"
        exit 1
    fi

    local original_question
    original_question=$(jq -r '.question' "${target_session}/meta.json")

    log "Re-running council on: ${original_question}"
    log "(with current codebase state)"

    QUESTION="[REVISIT] ${original_question} — The codebase may have changed since this was last deliberated. Re-evaluate with the current state of the code."
    init_session
    run_stage1
    [ "$MODE" = "with-review" ] && run_stage2
    run_stage3
    generate_viewer
    print_summary
}

# ---------------------------------------------------------------------------
# Usage
# ---------------------------------------------------------------------------
usage() {
    cat <<USAGE
${BOLD}Claude Council${NC} — Multi-session deliberation engine

${BOLD}USAGE:${NC}
    council                                   Interactive mode — prep your question with the chairman
    council "your question here"              Standard deliberation (streams by default)
    council --with-review "question"          Include peer review stage
    council --quick "question"                Skip optional stages
    council --no-stream "question"            Disable live streaming
    council --model-council <model>           Override council member model (default: sonnet)
    council --model-chairman <model>          Override chairman model (default: opus)
    council --with-nexus "question"           Use GitNexus knowledge graph for deeper codebase context

${BOLD}SUBCOMMANDS:${NC}
    council-list                              List past sessions
    council-replay <session-id>               Replay session in terminal
    council-revisit <session-id>              Re-deliberate with current context
    council-nudge <session-id> \\
        --agent <name> --correction "text"    Challenge an agent's assumptions
    council-outcome <session-id> "result"     Record decision outcome

${BOLD}PERSONAS:${NC}
    architect       Systems architecture, scalability, patterns
    pragmatist      Shipping velocity, DX, practical solutions
    security-perf   Security, performance, failure modes

${BOLD}CUSTOMIZATION:${NC}
    Add personas:    Drop .md files in ${PERSONAS_DIR}/
    Edit prompts:    Modify files in ${PROMPTS_DIR}/
    Config:          ${COUNCIL_HOME}/config.json

${BOLD}GITNEXUS INTEGRATION:${NC}
    Requires: npm install -g gitnexus
    First run indexes the repo automatically. Subsequent runs use cached index.
    Agents get access to knowledge graph queries, impact analysis, and symbol context.

${BOLD}INTERACTIVE MODE:${NC}
    Run 'council' with no question to enter interactive prep mode.
    The chairman helps you refine your question before deliberation.
    Commands:  /run (launch council)  /question (show current)  /edit (revise)  /quit

${BOLD}EXAMPLES:${NC}
    council                                   Start interactive prep session
    council "Should we migrate from Zustand to Jotai?"
    council --with-review "How should we structure the auth module?"
    council --with-nexus "What's the blast radius of refactoring the auth middleware?"
    council-nudge 20260409_143022_a1b2c3d4 --agent architect --correction "We can't use Redis, only SQLite"

USAGE
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    ensure_deps

    # Parse subcommands
    case "${1:-}" in
        --help|-h|help)
            usage
            exit 0
            ;;
        list|council-list)
            cmd_list
            exit 0
            ;;
        outcome|council-outcome)
            cmd_outcome "${2:-}" "${3:-}"
            exit 0
            ;;
        revisit|council-revisit)
            cmd_revisit "${2:-}"
            exit 0
            ;;
        nudge|council-nudge)
            shift
            local agent="" correction="" sid=""
            sid="${1:-}"; shift || true
            while [[ $# -gt 0 ]]; do
                case "$1" in
                    --agent) agent="$2"; shift 2 ;;
                    --correction) correction="$2"; shift 2 ;;
                    *) shift ;;
                esac
            done
            if [ -z "$sid" ] || [ -z "$agent" ] || [ -z "$correction" ]; then
                error "Usage: council-nudge <session-id> --agent <name> --correction \"text\""
                exit 1
            fi
            cmd_nudge "$sid" "$agent" "$correction"
            exit 0
            ;;
    esac

    # Parse flags for main deliberation
    QUESTION=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --with-review) MODE="with-review"; shift ;;
            --quick) MODE="quick"; shift ;;
            --no-stream) STREAM=false; shift ;;
            --timeout) TIMEOUT_MS="$2"; shift 2 ;;
            --grace) QUORUM_GRACE_MS="$2"; shift 2 ;;
            --model-council) MODEL_COUNCIL="$2"; shift 2 ;;
            --model-chairman) MODEL_CHAIRMAN="$2"; shift 2 ;;
            --with-nexus) USE_NEXUS=true; shift ;;
            *) QUESTION="$1"; shift ;;
        esac
    done

    if [ -z "$QUESTION" ]; then
        # Interactive mode — launch session prep with the chairman
        if [ -t 0 ]; then
            local question_file flags_file
            question_file=$(mktemp "${TMPDIR:-/tmp}/council_question.XXXXXX")
            flags_file=$(mktemp "${TMPDIR:-/tmp}/council_flags.XXXXXX")
            export COUNCIL_QUESTION_FILE="$question_file"
            export COUNCIL_FLAGS_FILE="$flags_file"

            # Build session_prep args
            local prep_args=("--model" "$MODEL_CHAIRMAN")
            if [ -n "$ALLOWED_TOOLS" ]; then
                prep_args+=("--allowed-tools" "$ALLOWED_TOOLS")
            fi
            if [ "$USE_NEXUS" = true ] && [ -n "$NEXUS_MCP_CONFIG" ]; then
                prep_args+=("--mcp-config" "$NEXUS_MCP_CONFIG")
            fi

            python3 "${SCRIPT_DIR}/session_prep.py" "${prep_args[@]}"

            # Read the refined question
            if [ -f "$question_file" ] && [ -s "$question_file" ]; then
                QUESTION="$(cat "$question_file")"
                rm -f "$question_file"
            else
                rm -f "$question_file"
                rm -f "$flags_file"
                echo -e "${DIM}  No question provided. Exiting.${NC}"
                exit 0
            fi

            # Apply flags toggled during the prep session
            if [ -f "$flags_file" ] && [ -s "$flags_file" ]; then
                local prep_flags
                prep_flags="$(cat "$flags_file")"
                rm -f "$flags_file"

                if echo "$prep_flags" | jq -e '.review == true' &>/dev/null; then
                    MODE="with-review"
                fi
                if echo "$prep_flags" | jq -e '.quick == true' &>/dev/null; then
                    MODE="quick"
                fi
                if echo "$prep_flags" | jq -e '.nexus == true' &>/dev/null; then
                    USE_NEXUS=true
                fi
                if echo "$prep_flags" | jq -e '.no_stream == true' &>/dev/null; then
                    STREAM=false
                fi
            else
                rm -f "$flags_file"
            fi
        else
            usage
            exit 1
        fi
    fi

    log "${BOLD}Claude Council${NC} — Deliberation starting"
    log "Question: ${QUESTION}"
    log "Mode: ${MODE}$([ "$STREAM" = true ] && echo " + streaming")$([ "$USE_NEXUS" = true ] && echo " + nexus")"
    log "Models: council=${MODEL_COUNCIL##*-}  chairman=${MODEL_CHAIRMAN##*-}"
    log "Personas: ${PERSONA_NAMES[*]}"
    log ""

    local start_ts
    start_ts=$(date +%s)

    init_session

    # Set up GitNexus if requested
    if [ "$USE_NEXUS" = true ]; then
        setup_nexus
    fi

    run_stage1

    if [ "$MODE" = "with-review" ]; then
        run_stage2
    fi

    run_stage3
    generate_viewer

    # ── Session timer ──
    local end_ts elapsed_s mins secs
    end_ts=$(date +%s)
    elapsed_s=$((end_ts - start_ts))
    mins=$((elapsed_s / 60))
    secs=$((elapsed_s % 60))

    # Save elapsed time to meta.json
    local tmp_meta
    tmp_meta=$(jq --arg elapsed "${mins}m ${secs}s" --arg secs "$elapsed_s" \
        '. + {elapsed_display: $elapsed, elapsed_seconds: ($secs | tonumber)}' \
        "${SESSION_DIR}/meta.json")
    echo "$tmp_meta" > "${SESSION_DIR}/meta.json"

    log "${DIM}Total time: ${mins}m ${secs}s${NC}"
    log ""

    print_summary

    # Interactive follow-up if running in a terminal
    if [ -t 0 ]; then
        run_followup
    fi
}

main "$@"
