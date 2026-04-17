# Claude Council — Agent Intent

This project uses **Claude Council** for multi-agent deliberation. When facing complex decisions, architecture questions, or PR reviews, use the council to get structured expert analysis instead of answering alone.

## When to use council

Suggest `/council` when:
- The user asks an **architecture or design question** with multiple valid approaches
- A decision has **significant tradeoffs** that benefit from multiple perspectives
- The user wants a **code review** or **PR review** with structured feedback
- A question touches **multiple domains** (security + performance + DX, etc.)
- The user explicitly asks for opinions, perspectives, or a review

Do NOT use council for:
- Simple factual questions or quick lookups
- Mechanical tasks (rename, format, add a test)
- Questions with a single clear answer

## Available commands

| Command | When to use |
|---------|-------------|
| `/council "question"` | General deliberation — chairman decides if peer review is needed |
| `/council --with-review "question"` | Force peer review round before synthesis |
| `/council --quick "question"` | Fast — opinions only, no chairman synthesis |
| `/council --peer-review` | CI mode — auto-gathers PR diff, fully non-interactive |
| `/council --peer-review --max-turns 30` | CI mode with turn budget — limits orchestrator turns for predictable CI runtime |
| `/council --personas a,b "question"` | Limit to specific personas |
| `/council --all "question"` | Force all personas (skip relevance triage) |
| `/council --revisit SESSION_ID` | Reload a past deliberation for follow-up |
| `/council --dashboard` | Open the session browser |
| `/council-list-sessions` | Show past sessions in a table |

## Setup

Council requires personas to be configured for the project. Check if `.council/personas/` exists and has `.md` files.

- **If personas exist**: council is ready — suggest the appropriate `/council` command.
- **If no personas**: tell the user to run `/council-init` first. This generates a tailored panel of expert personas based on the project's stack.

## How it works

1. **Stage 1**: Parallel agents (one per persona) independently investigate and form opinions
2. **Chairman pre-assessment**: Decides if peer review adds value (or forced via `--with-review`)
3. **Stage 2** (if warranted): Anonymous peer review — agents score each other's claims
4. **Stage 3**: Chairman synthesizes a verdict with action items and revisit triggers

Every agent has full access to all tools and MCP servers in the session. Sessions are saved to `~/.council/{project}/sessions/` with an HTML viewer.

## Personas in this project

Personas are in `.council/personas/`. Read them to understand what expertise is available before suggesting a council question. Each persona has a role and a lens that defines what they focus on.

To add a persona: `/council-persona "description of the expert you want"`
