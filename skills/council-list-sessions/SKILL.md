# /council-list-sessions — List Past Council Deliberations

Show a table of past council sessions for the current project.

## Usage

```
/council-list-sessions
```

## How It Works

### Step 1: Find sessions

Read all `.council/sessions/*/meta.json` files in the current project directory.

If `.council/sessions/` doesn't exist or has no sessions, tell the user:
> No council sessions found. Run `/council "your question"` to start one.

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
> To open the viewer: The HTML viewer is at `.council/sessions/SESSION_ID/viewer.html`

## Rules

- Only read `meta.json` files — don't load opinions or synthesis for the listing
- Most recent sessions first
- If a `meta.json` is malformed, skip it silently
