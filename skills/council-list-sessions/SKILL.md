# /council-list-sessions — List Past Council Deliberations

Show a table of past council sessions for the current project.

## Usage

```
/council-list-sessions
```

## How It Works

### Step 1: Find sessions

Derive the project name from the git repository's main worktree (so all worktrees of the same repo find the same sessions):

```bash
MAIN_WORKTREE="$(git worktree list --porcelain 2>/dev/null | head -1 | sed 's/^worktree //')"
PROJECT_NAME="$(basename "${MAIN_WORKTREE:-$(pwd)}")"
SESSION_BASE="$HOME/.council/${PROJECT_NAME}/sessions"
```

Read all `${SESSION_BASE}/*/meta.json` files.

If `${SESSION_BASE}` doesn't exist or has no sessions, tell the user:
> No council sessions found for project **{PROJECT_NAME}**. Run `/council "your question"` to start one.

### Step 2: Present the table

Sort sessions by timestamp (most recent first). Present as a markdown table:

```
| # | Session ID | Date | Question | Personas | Status |
|---|-----------|------|----------|----------|--------|
| 1 | 20260413_103047_9084117b | 2026-04-13 10:30 | Should we migrate from... | 3 | complete |
| 2 | 20260412_141522_a3f8e201 | 2026-04-12 14:15 | How should we restructure... | 3 | complete |
```

- **Question**: Truncate to 50 characters, append `...` if truncated
- **Personas**: Show count from the `personas` array
- **Status**: From the `status` field in meta.json
- **Date**: Format timestamp as `YYYY-MM-DD HH:MM`

### Step 3: Offer next steps

After the table:

> To revisit a session: `/council --revisit SESSION_ID`
> To open the viewer: The HTML viewer is at `~/.council/{PROJECT_NAME}/sessions/SESSION_ID/viewer.html`

## Rules

- Only read `meta.json` files — don't load opinions or synthesis for the listing
- Most recent sessions first
- If a `meta.json` is malformed, skip it silently
