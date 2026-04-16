# Claude Council

A multi-agent deliberation engine for Claude Code. Convene a panel of expert agents to analyze questions through structured discussion, peer review, and synthesis — with full access to your project artifacts, tools, and MCP servers.

## Quick Start

```bash
# Install the skills (one-time)
git clone <this-repo>
cd claude-council
bash setup.sh

# Initialize a council in your project
cd /path/to/your/project
# Then in Claude Code:
/council-init "I need 3 members who can review our API architecture"
# Or for non-code projects:
/council-init "I need 3 members for product strategy decisions"

# Run a deliberation
/council "Should we migrate from REST to GraphQL for the mobile API?"
```

## Architecture

Claude Council runs as a set of Claude Code skills. The orchestration is prompt-driven — no bash scripts, no Python runtime, no subprocess management. Claude Code's native Agent tool handles parallelism, streaming, and tool access.

```
/council "question"
    │
    ├── Stage 1: Parallel Agent calls (one per persona, model: sonnet)
    │   Each agent investigates available artifacts independently
    │
    ├── Chairman Pre-Assessment (decides if peer review is needed)
    │
    ├── Stage 2: Peer Review (if chairman requests it, --with-review, or --peer-review)
    │   Each agent anonymously scores the others
    │
    └── Stage 3: Chairman Synthesis (model: opus)
        Reads all opinions (+ reviews if conducted), renders verdict
        │
        └── Output: ~/.council/{project}/sessions/{id}/
            ├── meta.json, opinion_*.json, synthesis.json
            └── viewer.html (self-contained, dark/light mode)
```

Every spawned agent has full access to all tools and MCP servers available in the session — Grep, Read, Bash, GitNexus, Figma, Sentry, Jira, whatever you have configured.

## Skills

| Skill | Description |
|-------|-------------|
| `/council "question"` | Run a deliberation (chairman decides if peer review needed) |
| `/council --with-review "question"` | Force peer review (Stage 1 + 2 + 3) |
| `/council --peer-review` | CI mode — auto-gathers PR diff, fully non-interactive |
| `/council --quick "question"` | Opinions only, skip synthesis |
| `/council --personas a,b "question"` | Use specific personas |
| `/council --revisit SESSION_ID` | Reload and discuss a past session |
| `/council --dashboard` | Open the session browser in your browser |
| `/council-init` | Bootstrap personas for the current project |
| `/council-init "description"` | Generate tailored personas from a description |
| `/council-persona "description"` | Add a single persona |
| `/council-list-sessions` | Browse past deliberations |
| `/council-migrate` | Move old `.council/sessions/` to `~/.council/` |

## Personas

Personas live in `.council/personas/` per-project and are version-controlled with your code. Each `.md` file defines one expert perspective.

```bash
# Create via skill
/council-persona "DevOps engineer focused on CI/CD and deployment reliability"

# Or drop a file manually
cat > .council/personas/devops.md << 'EOF'
You are a **DevOps Engineer** on this council.

Your lens: CI/CD pipelines, infrastructure reliability, deployment strategies.

When analyzing a question:
- Evaluate how changes affect the build and deployment pipeline
- Consider infrastructure requirements and scaling
- Assess rollback strategies and deployment risk
- Think about observability: logging, metrics, alerting
- Flag environment-specific concerns: config management, secrets

You have full access to the codebase and all available tools/MCPs. USE THEM.
EOF
```

## Intent (Agent Plugin)

Council ships an **intent skill** — a lightweight file that teaches agents in other projects how to use council. Copy it into any project so agents know when and how to suggest deliberation.

```bash
# Add council awareness to another project
mkdir -p /path/to/project/.claude/skills/claude-council
cp intent/SKILL.md /path/to/project/.claude/skills/claude-council/SKILL.md
```

Once installed, agents working in that project will:
- Suggest `/council` when they detect complex decisions or architecture questions
- Know the available modes (`--quick`, `--with-review`, `--peer-review`)
- Guide users through setup if personas aren't configured yet
- Understand what personas are available and how to add new ones

The intent file is self-contained — it doesn't require the full council skills to provide context. But the council skills (`/council`, `/council-init`, etc.) must be installed globally via `setup.sh` for the commands to actually work.

## Project Structure

```
claude-council/
  setup.sh                          # Installs skills to ~/.claude/skills/
  templates/viewer.html             # HTML viewer template
  templates/dashboard.html          # HTML dashboard template
  intent/SKILL.md                   # Agent plugin — copy to other projects
  skills/
    council/SKILL.md                # Main deliberation orchestrator
    council-init/SKILL.md           # Project bootstrapper
    council-persona/SKILL.md        # Persona creator
    council-list-sessions/SKILL.md  # Session browser
    council-migrate/SKILL.md        # Session migration tool

your-project/
  .council/
    personas/                       # Version-controlled expert panel
      architect.md
      pragmatist.md
      security-perf.md

~/.council/
  your-project/
    sessions/                       # Deliberation history, organized by project
      20260413_103047_9084117b/
        meta.json
        stage1/opinion_*.json
        synthesis.json
        viewer.html
```

## How It Compares

| Feature | Standalone TUI (old) | Skill Architecture (current) |
|---------|---------------------|------------------------------|
| Runtime | bash + Python + Textual | Claude Code only |
| Tool access | Hardcoded allowlist | Full MCP/tool inheritance |
| Parallelism | Background PIDs + polling | Native Agent tool |
| Streaming | ANSI cursor manipulation | Claude Code built-in |
| Follow-up | `read -r` bash loop | Natural conversation |
| Personas | Global, hardcoded | Per-project, dynamic |
| Install | jq + python3 + textual | `setup.sh` (copies .md files) |
| Lines of code | ~2,660 (bash+Python) | ~500 (prompt markdown) |

## License

MIT
