# Claude Council

A multi-session deliberation engine for Claude Code. Adapted from [cliagent-council](https://github.com/yogirk/agent-council), but using **Claude Code sessions exclusively** instead of multiple CLI agents.

## Why Claude Council?

cliagent-council requires 3 different CLI agents (Claude Code + Codex + Gemini). Claude Council gives you the same deliberation framework — structured stages, peer review, synthesis, nudges — but runs entirely on Claude Code sessions with **expert persona diversity** instead of model diversity.

Each session gets a different expert lens (Architect, Pragmatist, Security & Performance Engineer) with full codebase access, so opinions are grounded in your actual code.

## Quick Start

```bash
# Clone and install
git clone <this-repo>
cd claude-council
bash setup.sh

# Run your first deliberation
council "Should we migrate from REST to GraphQL for the mobile API?"
```

## Architecture

```
┌─────────────────────────────────────────────────────┐
│                   ORCHESTRATOR                       │
│                  (council.sh)                        │
├─────────────────────────────────────────────────────┤
│                                                      │
│  Stage 1: Independent Opinions (parallel)            │
│  ┌──────────┐  ┌──────────┐  ┌──────────────────┐  │
│  │ Architect │  │Pragmatist│  │Security & Perf   │  │
│  │ claude -p │  │claude -p │  │claude -p         │  │
│  │ (codebase │  │(codebase │  │(codebase access) │  │
│  │  access)  │  │ access)  │  │                  │  │
│  └─────┬─────┘  └─────┬────┘  └────────┬────────┘  │
│        │              │                 │            │
│        └──────────────┼─────────────────┘            │
│                       ▼                              │
│  Stage 2: Peer Review (optional, parallel)           │
│  Each agent scores the others anonymously            │
│                       │                              │
│                       ▼                              │
│  Stage 3: Chairman Synthesis                         │
│  ┌─────────────────────────────────────────────┐    │
│  │ Chairman (claude -p) reads all opinions,     │    │
│  │ identifies consensus/divergence, renders     │    │
│  │ final verdict with confidence scores         │    │
│  └─────────────────────────────────────────────┘    │
│                       │                              │
│                       ▼                              │
│  Stage 4: Nudge (post-hoc, on demand)               │
│  Challenge specific agent's assumptions              │
│                                                      │
├─────────────────────────────────────────────────────┤
│  Output: ~/.council/{project}/{session}/             │
│  - opinion_*.json, review_*.json, synthesis.json    │
│  - viewer.html (self-contained, dark/light mode)    │
└─────────────────────────────────────────────────────┘
```

## Commands

| Command | Description |
|---------|-------------|
| `council "question"` | Standard deliberation (Stages 1 + 3) |
| `council --with-review "question"` | Include peer review (Stages 1 + 2 + 3) |
| `council --quick "question"` | Fast mode, skip optional stages |
| `council-list` | Browse past sessions |
| `council-revisit <id>` | Re-run with current codebase |
| `council-nudge <id> --agent <name> --correction "text"` | Challenge assumptions |
| `council-outcome <id> "result"` | Record what happened |

## Customization

### Add a persona

Create `personas/ux-advocate.md`:

```markdown
You are a **UX Advocate** on this council.

Your lens: user experience, accessibility, interaction patterns, cognitive load.

When analyzing a question:
- Consider the end user's perspective first
- Evaluate accessibility implications (WCAG, screen readers, color contrast)
- Think about error states, loading states, and edge cases from the user's POV
- Flag any patterns that increase cognitive load or reduce usability
...
```

Then add it to the `PERSONAS` array in `council.sh`.

### Modify stage prompts

Edit files in `prompts/` to change how agents are instructed.

### Session storage

All sessions live in `~/.council/{project}/`. Each session has a self-contained HTML viewer you can open in any browser.

## How it compares to cliagent-council

| Feature | cliagent-council | Claude Council |
|---------|-----------------|----------------|
| Agents | Claude + Codex + Gemini | 3x Claude Code sessions |
| Diversity source | Different models | Expert personas |
| Codebase access | All agents have tools | All sessions have tools |
| 4-stage deliberation | ✅ | ✅ |
| Peer review | ✅ | ✅ |
| Session storage | ✅ | ✅ |
| HTML viewer | ✅ | ✅ |
| Nudge/revisit | ✅ | ✅ |
| Outcome recording | ✅ | ✅ |
| Proactive suggestions | ✅ | ✅ (via SKILL.md) |
| Prerequisites | Bun + 2 CLI agents | Claude Code + jq |
| Cost | 3 subscriptions | 1 subscription |

## License

MIT
