# /council-migrate — Migrate Sessions to ~/.council/

Move council sessions from old project-local `.council/sessions/` directories to the new `~/.council/{project}/sessions/` location.

## Usage

```
/council-migrate
/council-migrate --scan ~/Projects
```

## How It Works

### Step 1: Scan for old sessions

By default, scan the current directory for `.council/sessions/*/meta.json`. If `--scan PATH` is provided, recursively search under that path for any `.council/sessions/*/meta.json` files.

```bash
# Default: current project only
SCAN_DIR="$(pwd)"

# With --scan: search recursively
# SCAN_DIR=<user-provided path>

# Find all old-style session directories
find "$SCAN_DIR" -path '*/.council/sessions/*/meta.json' -not -path '*/node_modules/*' -not -path '*/.git/*' 2>/dev/null
```

If no old sessions are found, tell the user:

> No old-style sessions found. Nothing to migrate.

### Step 2: Preview the migration plan

For each `meta.json` found, read it and extract the `project` and `project_dir` fields. Derive the target path:

```bash
# From meta.json:
#   project_dir -> basename gives PROJECT_NAME
#   session dir -> gives SESSION_ID
# Target: ~/.council/{PROJECT_NAME}/sessions/{SESSION_ID}/

PROJECT_NAME="$(basename "$PROJECT_DIR")"
TARGET="$HOME/.council/${PROJECT_NAME}/sessions/${SESSION_ID}"
```

Present a table showing what will be moved:

```
Found N sessions to migrate:

| # | Project | Session ID | Source | Target |
|---|---------|-----------|--------|--------|
| 1 | cv-mobile | 20260413_103047_9084117b | ~/Projects/cv-mobile/.council/sessions/... | ~/.council/cv-mobile/sessions/... |
| 2 | cv-mobile | 20260412_141522_a3f8e201 | ~/worktrees/cv-mobile-feat/.council/sessions/... | ~/.council/cv-mobile/sessions/... |

{M} sessions from {K} projects.
```

If any target directories already exist (session already migrated), flag them:

> **Skipping** session `{SESSION_ID}` — already exists at target.

Ask the user to confirm:

> Proceed with migration? **y/n**

### Step 3: Migrate

For each session to migrate:

1. Create the target directory: `mkdir -p "$TARGET"`
2. Copy the session contents: `cp -R "$SOURCE"/* "$TARGET"/`
3. Verify the copy by checking `meta.json` exists at the target
4. Remove the source: `rm -rf "$SOURCE"`

```bash
for each session:
  SOURCE="<old session dir>"
  TARGET="$HOME/.council/${PROJECT_NAME}/sessions/${SESSION_ID}"

  mkdir -p "$TARGET"
  cp -R "${SOURCE}/"* "$TARGET/"

  # Verify
  if [ -f "$TARGET/meta.json" ]; then
    rm -rf "$SOURCE"
    echo "Migrated: $SESSION_ID -> $TARGET"
  else
    echo "FAILED: $SESSION_ID — source preserved at $SOURCE"
  fi
done
```

### Step 4: Clean up empty directories

After migrating, remove any empty `.council/sessions/` directories left behind:

```bash
# Remove empty session dirs
find "$SCAN_DIR" -type d -name "sessions" -path '*/.council/sessions' -empty -delete 2>/dev/null
```

### Step 5: Report

Present the results:

```
Migration complete:

  Migrated: {N} sessions
  Skipped:  {S} (already at target)
  Failed:   {F}
  Projects: {K}

Sessions are now at ~/.council/{project}/sessions/
Use /council-list-sessions to browse them.
```

## Rules

- **Always preview before migrating** — never move files without user confirmation
- **Copy-then-delete, never move** — ensures data safety if the copy fails
- **Preserve all session files** — meta.json, stage1/, stage2/, synthesis.json, viewer.html
- **Skip duplicates** — if a session ID already exists at the target, don't overwrite
- **Use `project_dir` from meta.json** when available to derive `PROJECT_NAME`, falling back to the parent directory name if `project_dir` is missing
- **Never delete .council/personas/** — only session data is migrated
