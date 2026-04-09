# /council — Claude Council Deliberation

Convene a panel of Claude Code sessions to deliberate on engineering problems through structured multi-stage discussion, peer review, and synthesis.

## Usage

```
/council "Should we migrate from Zustand to Jotai for state management?"
/council --with-review "How should we restructure the auth module?"
/council --quick "What testing framework should we add?"
```

## How It Works

This skill launches 3 parallel Claude Code sessions, each with a different expert persona:

- **Architect** — scalability, patterns, long-term maintainability
- **Pragmatist** — shipping velocity, DX, simplicity
- **Security & Performance** — attack surface, runtime perf, failure modes

Each session has full codebase access (grep, read files, git log). Opinions are grounded in your actual code.

### Stages

1. **Independent Opinions** — All 3 sessions answer in parallel, can't see each other
2. **Peer Review** (optional, `--with-review`) — Each session anonymously scores the others
3. **Chairman Synthesis** — A final session reads all opinions and renders a verdict
4. **Targeted Nudge** (post-hoc) — Challenge a specific agent's assumptions

## Implementation

When the user invokes `/council`, run the orchestrator script:

```bash
bash ~/.claude/skills/council/src/council.sh "THE QUESTION HERE"
```

Or with flags:
```bash
bash ~/.claude/skills/council/src/council.sh --with-review "THE QUESTION"
bash ~/.claude/skills/council/src/council.sh --quick "THE QUESTION"
```

### Subcommands

```bash
# List past sessions
bash ~/.claude/skills/council/src/council.sh list

# Record what happened after following the council's advice
bash ~/.claude/skills/council/src/council.sh outcome SESSION_ID "It worked great"

# Re-run a past deliberation with the current codebase
bash ~/.claude/skills/council/src/council.sh revisit SESSION_ID

# Challenge an agent's assumptions
bash ~/.claude/skills/council/src/council.sh nudge SESSION_ID --agent architect --correction "We can't use Redis"
```

## Output

Sessions are stored in `~/.council/{project}/` with:
- Individual opinion JSON files
- Peer review matrices (if enabled)
- Chairman synthesis/verdict
- Self-contained HTML viewer (open in browser)

## Customization

### Add a new persona

Drop a markdown file in `personas/` following the existing format. The file name (minus `.md`) becomes the persona identifier. Update the `PERSONAS` associative array in `council.sh`.

### Modify stage prompts

Edit files in `prompts/` to change how agents are instructed at each stage.

### Configuration

Set environment variables or edit `~/.council/config.json`:
- `COUNCIL_HOME` — where sessions are stored (default: `~/.council`)
- Timeouts, quorum grace, and allowed tools are configurable in `council.sh`
