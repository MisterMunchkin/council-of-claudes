# Claude Council — Full Textual TUI Rewrite Plan

## Goal
Replace the current bash + python hybrid (`council.sh` + `session_prep.py` + `stream_monitor.py` + `results_viewer.py`) with a single unified Python/Textual application that handles the entire lifecycle: prep → deliberation → results → follow-up.

`council.sh` stays as a thin CLI entry point for argument parsing and subcommands, but delegates all interactive work to the Python TUI.

---

## Current Architecture (what we're replacing)

```
council.sh (1261 lines bash)
├── Argument parsing + subcommands (list, nudge, outcome, revisit)
├── session_prep.py — Textual TUI for question prep (Phase 0)
├── Stage 1: Parallel agent opinions (claude -p, background processes)
│   └── stream_monitor.py — in-place ANSI status lines
├── Stage 2: Peer review (optional, parallel)
├── Stage 3: Chairman synthesis (single claude -p call)
├── generate_viewer() — builds HTML viewer from results
├── results_viewer.py — ANSI terminal results display
└── Stage 5: Interactive follow-up (bash read loop)
```

**Problems with current approach:**
- Visual break when TUI exits and bash takes over
- stream_monitor.py uses raw ANSI cursor manipulation (fragile)
- results_viewer.py is a separate script with its own styling
- Follow-up uses raw `read -r` (no paste handling, no multiline)
- No unified progress tracking across stages

---

## Proposed Architecture

### File Structure

```
src/
├── council_app.py          # Main Textual App — the single entry point
├── council_engine.py       # Pure Python orchestration (no TUI deps)
├── council_cli.py          # CLI arg parsing, launches app or subcommands
├── widgets/
│   ├── prompt_input.py     # PromptInput widget (Enter=submit, \+Enter=newline)
│   ├── agent_panel.py      # Per-agent status/streaming panel
│   └── results_panel.py    # Verdict + opinion display
└── (existing files kept as fallback)
    ├── council.sh          # Simplified — delegates to council_cli.py
    ├── stream_monitor.py   # Kept for --no-tui fallback
    └── results_viewer.py   # Kept for --no-tui fallback
```

### Layer 1: `council_engine.py` — Orchestration (no TUI)

Pure async Python. Manages the entire deliberation lifecycle. Emits events that the TUI layer consumes. Can also run headless for CI/scripting.

```python
class CouncilEngine:
    """Manages a council deliberation session."""
    
    # Configuration
    question: str
    mode: str                    # "standard" | "quick" | "with-review"
    stream: bool
    model_council: str
    model_chairman: str
    use_nexus: bool
    personas: list[Persona]
    
    # Session state
    session_dir: Path
    stage: str                   # "prep" | "stage1" | "stage2" | "stage3" | "results" | "followup"
    
    # Event callbacks (the TUI hooks into these)
    on_stage_start: Callable     # (stage_name, description)
    on_agent_start: Callable     # (agent_name)
    on_agent_token: Callable     # (agent_name, token)
    on_agent_tool: Callable      # (agent_name, tool_name)
    on_agent_done: Callable      # (agent_name, result_json)
    on_stage_done: Callable      # (stage_name, summary)
    on_synthesis_ready: Callable # (synthesis_json)
    on_followup_response: Callable  # (response_json)
    on_error: Callable           # (stage, agent, error_msg)
    
    # Core methods
    async def init_session(self)
    async def run_stage1(self)           # Parallel opinions
    async def run_stage2(self)           # Peer review (if mode=with-review)
    async def run_stage3(self)           # Chairman synthesis
    async def generate_viewer(self)      # HTML output
    async def ask_followup(self, text)   # Stage 5 follow-up
    async def run_full(self)             # Runs stages 1→3 + viewer
    
    # Helpers
    async def _launch_agent(self, name, prompt, model, stream_callback)
    def _load_prompt(self, template_name) -> str
    def _load_persona(self, name) -> str
    def _substitute(self, template, replacements) -> str
```

**Key design decisions:**
- All agent calls use `asyncio.create_subprocess_exec` (same as current session_prep.py)
- Stage 1 launches all agents concurrently with `asyncio.gather`
- Streaming: reads `--output-format stream-json` line by line, fires `on_agent_token`
- JSON extraction logic (try parse → extract `{...}` → wrap raw) stays identical to council.sh
- Session directory structure unchanged (`~/.council/project/session_id/`)

### Layer 2: `council_app.py` — Textual TUI

Single Textual App with multiple screens/phases:

```
┌─────────────────────────────────────────────────┐
│  ⚖ Council Prep  ┃  standard                    │  ← Top bar (persists)
├─────────────────────────────────────────────────┤
│                                                  │
│  Phase 0: Prep (current session_prep.py)         │
│  ─────────────────────────────────────────       │
│  Chat with chairman to refine question           │
│  /run transitions to Phase 1                     │
│                                                  │
│  Phase 1: Deliberation                           │
│  ─────────────────────────────────────────       │
│  ┌──────────┬──────────┬──────────┐              │
│  │architect │pragmatist│sec-perf  │  ← Agent     │
│  │streaming…│using Read│waiting…  │    status     │
│  │          │          │          │    panels     │
│  └──────────┴──────────┴──────────┘              │
│  Stage 1 ━━━━━━━━━━━━━━━━━━━━░░░░ 2/3 done      │  ← Progress bar
│                                                  │
│  Phase 2: Results                                │
│  ─────────────────────────────────────────       │
│  Verdict, opinions, action items                 │
│  Scrollable, formatted with Rich markup          │
│                                                  │
│  Phase 3: Follow-up                              │
│  ─────────────────────────────────────────       │
│  Same chat interface as prep, but talking to      │
│  chairman about the verdict                      │
│                                                  │
├─────────────────────────────────────────────────┤
│ ❯ [input area]                                   │  ← Input (persists)
├─────────────────────────────────────────────────┤
│ enter send  \+enter newline  ctrl+r run  ctrl+q │  ← Footer (persists)
└─────────────────────────────────────────────────┘
```

**Screen transitions:**
1. **Prep** → user types question, chats with chairman → `/run`
2. **Deliberation** → input is disabled, agent panels show live streaming → auto-transitions when done
3. **Results** → verdict and opinions displayed → input re-enables for follow-up
4. **Follow-up** → chat with chairman about the verdict → `q`/`done` to exit

**Widgets:**

| Widget | Purpose |
|--------|---------|
| `PromptInput` | Multiline input (already built) |
| `AgentPanel` | Shows one agent's status: name, icon, streaming text, tool count, done state |
| `StageProgress` | "Stage 1 ━━━━━━━━━░░░ 2/3" progress indicator |
| `ResultsView` | Scrollable verdict + opinions with Rich formatting |
| `ChatLog` | RichLog used in prep and follow-up phases |

### Layer 3: `council_cli.py` — Entry Point

Replaces the argument parsing in `council.sh`. `council.sh` becomes a one-liner:

```bash
#!/usr/bin/env bash
exec python3 "$(dirname "$0")/council_cli.py" "$@"
```

`council_cli.py` handles:
- Argument parsing (same flags as current council.sh)
- Subcommand routing (list, nudge, outcome, revisit) — these stay as simple CLI output, no TUI needed
- For main deliberation: launches `CouncilApp` with the engine
- `--no-tui` flag falls back to the original bash-style output

---

## Implementation Order

### Phase 1: Engine + Deliberation TUI (this session)

1. **`council_engine.py`** — Port all stage logic from council.sh
   - `_launch_agent()` with streaming
   - `run_stage1()` — parallel with asyncio.gather
   - `run_stage3()` — chairman synthesis
   - JSON extraction + session directory management
   - Event callbacks for TUI integration

2. **`council_app.py`** — Merge session_prep.py into a multi-phase app
   - Phase 0 (prep): existing chat UI
   - Phase 1 (deliberation): agent panels + progress bar
   - Phase 2 (results): verdict display
   - Connect engine callbacks to TUI updates

3. **`council_cli.py`** — Argument parsing + app launch

4. **Update `council.sh`** — Delegate to council_cli.py

5. **Update `setup.sh`** — Ensure new files get deployed

### Phase 2: Follow-up + Subcommands (next session)

6. Phase 3 (follow-up) in the TUI
7. Port subcommands (list, nudge, outcome, revisit) to council_cli.py
8. `--no-tui` fallback mode
9. HTML viewer generation from Python

---

## What Stays the Same

- **Prompt templates** (`prompts/*.md`) — unchanged
- **Persona files** (`personas/*.md`) — unchanged
- **HTML viewer template** (`templates/viewer.html`) — unchanged
- **Session directory structure** (`~/.council/project/session_id/`) — unchanged
- **Claude CLI calls** — same `claude -p` with `--output-format stream-json`
- **Model strategy** — Sonnet for council, Opus for chairman

## What Changes

- `council.sh` becomes a thin wrapper (from 1261 lines to ~5)
- `session_prep.py` gets absorbed into `council_app.py`
- `stream_monitor.py` replaced by `AgentPanel` widgets
- `results_viewer.py` replaced by `ResultsView` widget
- Follow-up uses the same `PromptInput` widget (with paste, multiline)

## Risks / Things to Watch

1. **Agent subprocess management** — Need reliable cleanup on Ctrl+C. Textual has its own signal handling; need to make sure background `claude` processes get killed.

2. **Streaming performance** — Reading stdout line-by-line from 3 concurrent processes. asyncio should handle this fine, but need to test with real Opus/Sonnet output speeds.

3. **JSON extraction** — The current bash logic for pulling JSON from agent responses is fiddly. Porting it to Python should actually be cleaner (proper json.loads with fallbacks).

4. **Terminal compatibility** — Textual handles most terminal differences, but the agent panels with live-updating text need to work in standard macOS Terminal, iTerm2, and VS Code terminal.

5. **File size** — `council_engine.py` will be ~400 lines, `council_app.py` ~500 lines. Large but manageable since they're cleanly separated.
