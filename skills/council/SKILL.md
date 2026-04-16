---
argument-hint: [--all, --peer-review, --dashboard, --revisit, --max-turns 25, --personas ai-tooling,developer-experience,prompt-architect]
---

# /council — Claude Council Deliberation

Convene a panel of expert agents to deliberate on engineering problems through structured multi-stage discussion, peer review, and synthesis — all within Claude Code using native Agent parallelism with full tool and MCP access.

## Usage

```
/council "Should we migrate from Zustand to Jotai for state management?"
/council --with-review "How should we restructure the auth module?"
/council --quick "What testing framework should we add?"
/council --personas architect,pragmatist "Just these two perspectives"
/council --all "Force all personas even if some seem irrelevant"
/council --peer-review "Focus on security and test coverage"
/council --peer-review --max-turns 30
/council --peer-review
/council --revisit SESSION_ID
/council --dashboard
```

## Orchestration

When the user invokes `/council`, you become the **orchestrator**. You do NOT answer the question yourself. You run a structured deliberation protocol using the Agent tool to spawn parallel expert sessions, then synthesize their findings.

Every spawned agent has full access to all tools and MCP servers available in this session.

---

## Step 0: Parse and Prepare

Extract from the user's message:

- **QUESTION**: The deliberation question
- **MODE**: `standard` (default — chairman decides if peer review is needed), `--with-review` (always includes Stage 2), `--quick` (Stage 1 only), `--peer-review` (CI mode for PR reviews — non-interactive, auto-gathers diff), `--revisit SESSION_ID` (reload a past session), or `--dashboard` (generate and open the session browser)
- **PERSONAS**: If `--personas` flag given, use those names. If `--all` flag given, use every persona. Otherwise, triage for relevance (see below).
- **MAX_TURNS**: If `--max-turns N` flag given, set the turn budget to N. Otherwise default to **unlimited** (no budget enforcement). When set, the orchestrator must plan its pipeline to complete within N orchestrator turns — see **Turn budget** under `--peer-review` for the planning strategy. This flag works with any mode but is most important for `--peer-review` in CI.

### Handle --dashboard

If the user passed `--dashboard`, skip all deliberation stages and generate the session browser:

1. Check that the dashboard template exists at `~/.claude/skills/council/templates/dashboard.html`. If missing, tell the user to run `./setup.sh` and stop.
2. Generate the dashboard:

```bash
python3 -c "
import sys, json, glob, os
from datetime import datetime, timezone

def safe(s):
    return s.replace('</', '<\\\\/')

template_path = sys.argv[1]
council_dir = os.path.expanduser('~/.council')
os.makedirs(council_dir, exist_ok=True)
output_path = os.path.join(council_dir, 'dashboard.html')

template = open(template_path).read()

sessions = []
for meta_path in sorted(glob.glob(os.path.join(council_dir, '*', 'sessions', '*', 'meta.json'))):
    try:
        meta = json.load(open(meta_path))
        session_dir = os.path.dirname(meta_path)

        # Read verdict from synthesis if available
        verdict = ''
        synth_path = os.path.join(session_dir, 'synthesis.json')
        if os.path.exists(synth_path):
            try:
                synth = json.load(open(synth_path))
                verdict = synth.get('verdict', '')
            except:
                pass

        # Check for viewer.html
        viewer_path = os.path.join(session_dir, 'viewer.html')
        viewer_rel = viewer_path if os.path.exists(viewer_path) else ''

        sessions.append({
            'meta': meta,
            'verdict': verdict,
            'viewer_path': viewer_rel
        })
    except:
        continue

# Sort by timestamp descending
sessions.sort(key=lambda s: s['meta'].get('timestamp', ''), reverse=True)

generated = datetime.now(timezone.utc).isoformat()

template = template.replace('__SESSIONS_JSON__', safe(json.dumps(sessions)))
template = template.replace('__GENERATED_TS__', generated)

with open(output_path, 'w') as f:
    f.write(template)

projects = len(set(s['meta'].get('project', '') for s in sessions))
print(f'{len(sessions)} sessions across {projects} projects')
print(output_path)
" ~/.claude/skills/council/templates/dashboard.html
```

3. Open it:

```bash
DASHBOARD="$HOME/.council/dashboard.html"
if command -v open &>/dev/null; then
  open "$DASHBOARD"
elif command -v xdg-open &>/dev/null; then
  xdg-open "$DASHBOARD"
else
  echo "Open $DASHBOARD in your browser"
fi
```

Tell the user:
> **Dashboard**: `~/.council/dashboard.html` — report the counts from the script output.

Then stop — do not proceed to any deliberation stages.

### Handle --revisit

If the user passed `--revisit SESSION_ID`, skip all stages and go directly to **Revisit Mode**:

1. Derive `PROJECT_NAME` and `SESSION_BASE` as described in **Initialize session**
2. Set `SESSION_DIR="${SESSION_BASE}/${SESSION_ID}"`
3. Read `${SESSION_DIR}/meta.json` to get the original question and personas
4. Read `${SESSION_DIR}/synthesis.json` for the verdict
5. Read all `${SESSION_DIR}/stage1/opinion_*.json` for individual opinions
6. Present the results using the same format as **Presenting Results**
7. If `${SESSION_DIR}/viewer.html` does not exist, generate it using the **Generate HTML Viewer** steps
8. Enter **Follow-Up** mode — the user can ask questions, nudge agents, or request a fresh re-deliberation with the current codebase

If the session ID doesn't exist, list available sessions from `${SESSION_BASE}/*/meta.json` and ask the user to pick one.

### Handle --peer-review

This mode is designed for CI pipelines (e.g., GitHub Actions). It runs a fully non-interactive, **read-only** deliberation on the current branch's changes — no triage confirmation, no user prompts, chairman decides everything.

> **GUARD RAILS — READ-ONLY MODE**
>
> `--peer-review` is strictly observational. The orchestrator and all spawned agents MUST NOT:
> - Edit, write, or delete any files in the working tree
> - Run `git commit`, `git push`, `git checkout`, `git stash`, or any state-changing git command
> - Execute code-modification tools (Edit, Write, NotebookEdit) or run scripts that mutate the codebase
> - Auto-apply any action items or fixes
>
> Agents MAY use read-only tools: Read, Grep, Glob, Bash (for read-only commands like `git diff`, `git log`, `ls`), and MCP read operations.
>
> The output is a **summary report** — findings, confidence scores, and copy-paste prompts the user can execute themselves.

**Turn budget**: When `--max-turns N` is set, the orchestrator must plan its pipeline to complete within N orchestrator turns. If `--max-turns` is not set, there is no budget enforcement — run the full pipeline.

Each step of the pipeline costs roughly this many orchestrator turns:

| Step | ~Turns |
|------|--------|
| Gather context + build question | 2–3 |
| Sync argument-hint + load personas + triage | 3–4 |
| Launch Stage 1 agents (1 call) + collect results | 2 |
| Chairman pre-assessment | 2 |
| Stage 2 if requested (1 call) + collect | 2 |
| Stage 3 synthesis | 2 |
| Present results | 1 |
| Generate viewer | 2–3 |

**Planning strategy**: At the start of the pipeline (after parsing flags), calculate what fits within the budget. Use these tiers:

| Budget | Strategy |
|--------|----------|
| **N >= 25** | Full pipeline: up to 4 personas, Stage 2 if chairman requests, viewer |
| **20 <= N < 25** | Standard: 2–3 personas, Stage 2 if chairman requests, viewer |
| **15 <= N < 20** | Lean: 2–3 personas, skip Stage 2 (go straight to synthesis), viewer |
| **N < 15** | Minimal: 2 personas, skip Stage 2, skip viewer, present results only |

**Adaptation rules**:
- **Persona count is the biggest lever.** Each additional persona doesn't add orchestrator turns (they run in parallel), but more opinions means a heavier synthesis prompt. Prefer fewer, more relevant personas when the budget is tight.
- **Stage 2 is the first thing to cut.** A single pass with synthesis is far more valuable than an incomplete two-pass run.
- **Viewer is the second thing to cut.** A verdict without a viewer is useful; a viewer without a verdict is not.
- **Never cut Stage 3 synthesis.** The verdict is the whole point. If the budget can't fit synthesis, reduce persona count until it can.

Report the plan after triage:
> **Turn budget**: {N} turns — running **{tier name}** pipeline ({persona count} personas, {with/without} Stage 2, {with/without} viewer)

**Step 1: Gather PR context**

Run these commands to collect the diff context:

```bash
# Detect base branch — use $BASE_BRANCH env var if set, otherwise default to main
BASE="${BASE_BRANCH:-main}"

# Gather context
COMMITS="$(git log --oneline ${BASE}...HEAD 2>/dev/null)"
DIFFSTAT="$(git diff --stat ${BASE}...HEAD 2>/dev/null)"
DIFF="$(git diff ${BASE}...HEAD 2>/dev/null)"
DIFF_SIZE="$(echo "$DIFF" | wc -c)"
CHANGED_FILES="$(git diff --name-only ${BASE}...HEAD 2>/dev/null)"
```

If the diff is empty (no commits ahead of base), tell the user and stop.

**Step 2: Build the question**

Construct the deliberation question automatically. If the user provided text after `--peer-review`, append it as additional focus areas. Otherwise use the default:

```
Review the changes in this pull request.

## Commits
{COMMITS}

## Changed Files
{DIFFSTAT}

## Full Diff
{DIFF}

## Focus Areas
- Code quality and adherence to project conventions
- Potential bugs or edge cases
- Security concerns
- Architecture and design decisions
- Test coverage gaps

{user's additional context if provided}
```

If `DIFF_SIZE` exceeds 30000 bytes, omit `{DIFF}` from the question and instead instruct agents to run `git diff {BASE}...HEAD` themselves to read specific sections. Always include the diffstat and commit log.

**Step 3: Continue with the standard pipeline**

After building the question, fall through to the normal flow starting from **Sync argument-hint**. The following behaviors apply in `--peer-review` mode:

- **Read-only enforcement**: all agents are instructed to only use read-only tools (see guard rails above)
- **Triage**: runs automatically, no confirmation (same as `--quick` and `--with-review`)
- **Chairman pre-assessment**: runs — chairman decides if Stage 2 peer review is warranted
- **All stages complete without user interaction**
- **HTML viewer is generated** as normal (CI can upload it as an artifact)
- **No follow-up actions**: after presenting results, stop — do not offer to apply fixes or spawn action agents

### Sync argument-hint

Before loading personas, sync the `argument-hint` in this skill's frontmatter so autocomplete stays current (personas may have been added in other worktrees or sessions):

```bash
PERSONAS_DIR=".council/personas"
SKILL_FILE="$HOME/.claude/skills/council/SKILL.md"
if [ -d "$PERSONAS_DIR" ] && [ -f "$SKILL_FILE" ]; then
  NAMES=$(ls "$PERSONAS_DIR"/*.md 2>/dev/null | xargs -I{} basename {} .md | sort | paste -sd, -)
  if [ -n "$NAMES" ]; then
    sed -i.bak "s/^argument-hint: .*/argument-hint: [--all, --peer-review, --dashboard, --revisit, --personas $NAMES]/" "$SKILL_FILE" && rm -f "$SKILL_FILE.bak"
  fi
fi
```

### Load personas

Read persona `.md` files from `.council/personas/` in the current project directory. Each `.md` file defines one persona. The filename (minus `.md`) is the persona identifier.

If `.council/personas/` doesn't exist or is empty, tell the user to run `/council-init` first and stop.

If `--personas` was specified, load only those. If a requested persona doesn't exist, tell the user and suggest `/council-persona` to create it.

If `--all` flag, load all `.md` files and skip triage. If neither `--personas` nor `--all` was specified, load all `.md` files as triage candidates.

### Triage personas for relevance

Skip this step if `--personas` or `--all` was specified — those are explicit overrides.

When no flag is given, you (the orchestrator) must select only the personas whose expertise is relevant to the question. This prevents wasting tokens on perspectives that add no value (e.g., a UX persona reviewing CI/CD pipeline YAML).

**How to triage:**

1. Read the first three lines of each loaded persona file — line 1 contains the role declaration, line 3 contains the lens description. Use both to assess relevance.
2. Consider the question and any obvious context clues (mentioned files, technologies, domains).
3. If the question references specific files or a PR, do a quick scan (e.g., list changed files) to understand what domain the work touches.
4. For each persona, ask: *"Would this expert have a meaningfully different perspective on this question, or would they be stretching outside their domain?"* Drop personas that would be stretching.
5. **Minimum 2 personas** — a council of one isn't a deliberation. If only 1 survives triage, keep the next-closest.
6. **When in doubt, keep.** Only drop personas you're confident are irrelevant. A security reviewer on a "refactor the auth module" question is relevant even if the question doesn't explicitly mention security.

**Report your selection** before proceeding:

> **Personas selected** ({N} of {TOTAL}): **architect**, **security-perf**
> *Excluded*: **ux-designer** — question is about CI pipeline configuration, no user-facing impact.

If the user disagrees, they can say so and you adjust before launching Stage 1.

In `--quick`, `--with-review`, or `--peer-review` mode, proceed immediately after reporting the selection — do not wait for user confirmation. These modes are designed to run without interactive gates.

### Initialize session

Session artifacts are stored in `~/.council/{PROJECT_NAME}/sessions/` so they persist across worktrees and don't pollute the project directory. `PROJECT_NAME` is the basename of the git repository's main worktree — this ensures all worktrees of the same repo share a single session directory.

```bash
# Use the main worktree basename so all worktrees share one session folder
MAIN_WORKTREE="$(git worktree list --porcelain 2>/dev/null | head -1 | sed 's/^worktree //')"
PROJECT_NAME="$(basename "${MAIN_WORKTREE:-$(pwd)}")"
SESSION_ID="$(date +%Y%m%d_%H%M%S)_$(openssl rand -hex 4)"
SESSION_BASE="$HOME/.council/${PROJECT_NAME}/sessions"
SESSION_DIR="${SESSION_BASE}/${SESSION_ID}"
mkdir -p "${SESSION_DIR}/stage1" "${SESSION_DIR}/stage2"
```

Write a `meta.json` to the session directory:

```json
{
  "id": "SESSION_ID",
  "project": "PROJECT_NAME",
  "project_dir": "/current/working/dir",
  "question": "the question",
  "mode": "standard",
  "personas": ["architect", "security-perf"],
  "excluded_personas": ["ux-designer"],
  "timestamp": "ISO 8601 UTC",
  "status": "in_progress"
}
```

- `personas` — the personas that will participate (after triage, or as explicitly requested)
- `excluded_personas` — personas dropped by triage (empty array if `--personas` or `--all` was used)

---

## Stage 1: Independent Opinions

Launch **one Agent call per persona, all in a single message** so they run in parallel. Use `model: "sonnet"` for all.

Set each agent's `description` to `"Council: {persona_name} opinion"`.

### Agent prompt template

Build each agent's prompt by combining the persona text with this template:

```
You are a council member deliberating on a question. You must provide your independent opinion — you have no knowledge of what other council members will say.

## The Question

{QUESTION}

## Your Role

{PERSONA — the full text from the persona .md file}

## Instructions

1. **Investigate first.** Use your tools to examine available artifacts before forming an opinion. Read relevant files, grep for patterns, check git history, review documents and specs. You have full access to all tools and MCP servers — use whatever is most effective. If GitNexus or other knowledge graph tools are available, use them to query architecture, dependencies, and impact analysis.
2. **Form your opinion.** Based on what you found, provide a clear recommendation.
3. **Be thorough but concise.** Reference specific files and patterns. Do NOT paste entire files or raw grep output.

{If MODE is --peer-review, append this block:}
**READ-ONLY MODE**: This is a peer review session. You MUST NOT edit, write, or delete any files. Do NOT use the Edit, Write, or NotebookEdit tools. Do NOT run git commands that change state (commit, push, checkout, stash). Only use read-only tools: Read, Grep, Glob, and read-only Bash commands (git diff, git log, ls, etc.). Your job is to analyze and report findings — not to fix them.

## Output Format

Respond with ONLY a valid JSON object — no markdown fences around it, no preamble, no text outside the JSON. You MAY use markdown formatting (backticks, bold, italics) inside JSON string values.

{
  "recommendation": "Clear, actionable recommendation in 1-3 sentences. Reference key files with `backticks`.",
  "reasoning": [
    "Each point grounded in codebase evidence, using `backticks` for code refs."
  ],
  "evidence": [
    "What you found — describe the pattern, reference specific files or sources. Don't paste raw contents."
  ],
  "tradeoffs": {
    "pros": ["Short benefit with `code refs` if relevant"],
    "cons": ["Short downside with `code refs` if relevant"]
  },
  "assumptions": [
    "Things about the project/context that could change your answer."
  ],
  "belief_triggers": [
    "If *condition*, I would change my recommendation to **alternative**."
  ],
  "confidence": 0.85
}
```

### After Stage 1

For each agent response:
1. Parse the JSON from the agent's output (try `json.loads` on the full text, then look for `{...}` if that fails)
2. Write the JSON to `${SESSION_DIR}/stage1/opinion_{persona_name}.json`

Present a brief status:

> **Stage 1 complete** — {N} opinions collected.

Then show each persona's recommendation as a one-liner so the user sees progress:
> - **architect**: {recommendation first sentence}
> - **pragmatist**: {recommendation first sentence}
> - **security-perf**: {recommendation first sentence}

If `--quick` mode: skip to **Presenting Results** and **Generate Viewer**.

If `--with-review` was passed, skip the chairman pre-assessment and go straight to Stage 2.

### Chairman pre-assessment

In `standard` and `--peer-review` modes, the chairman decides whether peer review would add value — the user is never prompted.

Launch **1 Agent call** using `model: "opus"`. Description: `"Council: chairman pre-assessment"`.

```
You are the Chairman of an expert council. You have received independent opinions from all council members. Before synthesizing a verdict, you must decide whether a peer review round would improve the outcome.

## Original Question

{QUESTION}

## All Stage 1 Opinions

### {persona_name}'s Opinion:
{full JSON opinion}

(repeat for each persona)

## Instructions

Assess the opinions and decide if a peer review round is warranted. Peer review is valuable when:
- Opinions contain factual claims that contradict each other
- Confidence scores diverge significantly (e.g., 0.9 vs 0.5)
- Multiple agents reference the same evidence but draw opposite conclusions
- The question is high-stakes (security, data integrity, architecture) and you want claims verified

Peer review is NOT needed when:
- Opinions broadly agree with minor variations
- The question is exploratory or low-stakes
- Evidence is clear and non-contradictory
- Adding a review round would just confirm what's already obvious

## Output Format

Respond with ONLY a valid JSON object — no markdown fences, no preamble.

{
  "needs_peer_review": true,
  "reason": "Brief explanation of why peer review is or isn't warranted."
}
```

Parse the chairman's response:
- If `needs_peer_review` is `true`, tell the user:
  > **Chairman**: Requesting peer review — {reason}
  Then proceed to **Stage 2**.
- If `false`, tell the user:
  > **Chairman**: Peer review not needed — {reason}
  Then skip to **Stage 3**.

---

## Stage 2: Peer Review

Launch **one Agent per persona, all in parallel** using `model: "sonnet"`. Set each agent's `description` to `"Council: {persona_name} review"`.

Anonymize opinions with shuffled letter labels (Agent A, B, C...) so reviewers can't identify who wrote what.

Each agent's prompt:

```
You are reviewing other council members' opinions on an engineering question. Their identities are hidden.

## Original Question

{QUESTION}

## Opinions to Review

### Agent {LETTER}'s Opinion:
{full JSON opinion text}

(repeat for each opinion)

## Instructions

For EACH opinion, evaluate:
1. **Correctness**: Are the claims accurate? Does the evidence support the recommendation?
2. **Completeness**: Did they miss important considerations?
3. **Feasibility**: Is their recommendation practical to implement?

{If MODE is --peer-review, append this block:}
**READ-ONLY MODE**: This is a peer review session. You MUST NOT edit, write, or delete any files. Only use read-only tools (Read, Grep, Glob, read-only Bash). Your job is to review and critique — not to fix.

## Output Format

Respond with ONLY a valid JSON object — no markdown fences, no preamble.

{
  "reviews": [
    {
      "agent": "Agent A",
      "scores": { "correctness": 4, "completeness": 3, "feasibility": 5 },
      "strengths": ["Clear sentence about what they got right"],
      "weaknesses": ["Clear sentence about what they missed"],
      "factual_issues": ["Any claims that don't hold up, or empty array"]
    }
  ],
  "consensus_points": ["Where agents agree and why it matters"],
  "contradictions": ["Where they disagree and why it matters"],
  "blind_spots": ["What everyone missed"],
  "ranking": ["Agent B", "Agent A", "Agent C"]
}
```

Write each review to `${SESSION_DIR}/stage2/review_{persona_name}.json`.

> **Stage 2 complete** — peer reviews collected.

---

## Stage 3: Chairman Synthesis

Launch **1 Agent call** using `model: "opus"`. Description: `"Council: chairman synthesis"`.

```
You are the Chairman of an expert council. You must synthesize all opinions into a final verdict.

## Original Question

{QUESTION}

## All Stage 1 Opinions

### {persona_name}'s Opinion:
{full JSON opinion}

(repeat for each persona)

## Peer Review Results

{If peer review was conducted (--with-review, or chairman requested it): include all review JSONs with reviewer names. Otherwise: "No peer reviews conducted."}

## Instructions

1. **Identify true consensus** — where do all or most agents genuinely agree?
2. **Map the disagreements** — where do they diverge, and what causes it?
3. **Synthesize a recommendation** — the best path forward, weighing all perspectives.
4. **Create action items** — each with priority, type, action description, and an ai_prompt for actionable items.
5. **Set revisit triggers** — conditions under which to reconsider.

You have full access to the codebase and all tools/MCPs. Verify any claims you find questionable.

{If MODE is --peer-review, append this block:}
**READ-ONLY MODE**: This is a peer review session. You MUST NOT edit, write, or delete any files. Only use read-only tools. Focus on producing actionable `ai_prompt` values that the user can copy-paste to fix issues — do not attempt fixes yourself.

## Output Format

Respond with ONLY a valid JSON object — no markdown fences, no preamble.

{
  "verdict": "Clear, actionable recommendation in 2-3 sentences.",
  "consensus": [
    {
      "point": "What they agreed on",
      "agents": ["architect", "pragmatist"],
      "strength": "strong"
    }
  ],
  "divergence": [
    {
      "point": "What they disagreed on",
      "positions": {
        "architect": "Their position in one sentence",
        "pragmatist": "Their position in one sentence"
      },
      "resolution": "How you resolve this",
      "rationale": "Why"
    }
  ],
  "confidence_scores": {
    "architect": 0.85,
    "pragmatist": 0.90,
    "security-perf": 0.75,
    "overall": 0.85
  },
  "action_items": [
    {
      "priority": "high",
      "type": "action",
      "action": "Description of what to do, with `code refs`",
      "ai_prompt": "Prompt the user can copy-paste into a separate Claude Code session to execute this fix. Include files, constraints, intent. The orchestrator MUST NOT execute this prompt — it is for the user only. Set to null for type: note."
    }
  ],
  "revisit_triggers": [
    "If *condition*, reconsider this decision."
  ]
}

Priority guide:
- high: Security vulns, data loss, breaking bugs
- medium: Architectural issues, code smells, missing abstractions
- low: Style, nice-to-haves, documentation
```

Write synthesis to `${SESSION_DIR}/synthesis.json`.

Update `${SESSION_DIR}/meta.json` to set status to `"complete"`:

```bash
python3 -c "
import json, sys
path = sys.argv[1]
data = json.load(open(path))
data['status'] = 'complete'
json.dump(data, open(path, 'w'), indent=2)
" "${SESSION_DIR}/meta.json"
```

For `--quick` mode, run the same status update after writing opinion files (before presenting results).

---

## Presenting Results

After synthesis (or Stage 1 in `--quick` mode), present results to the user in clean markdown. Parse the JSON and format it readably — don't dump raw JSON.

For standard/with-review/peer-review modes:

```markdown
---

## Council Verdict

{verdict text, with markdown formatting preserved}

---

### Consensus
{For each consensus point: the point, which agents, strength}

### Divergence
{For each: the point, each agent's position, resolution}

### Confidence
{Bar-style or table: each persona score + overall}

### Action Items
{Grouped by priority (HIGH first). For each: priority badge, type, description.
 For ACTION items, include the ai_prompt in a fenced block the user can copy.}

### Revisit Triggers
{Bulleted list}

---
```

For `--quick` mode, show each persona's full opinion with headers.

For `--peer-review` mode, use the same format as standard but add these sections:

```markdown
### Confidence Scores
| Persona | Confidence | Assessment |
|---------|-----------|------------|
| {persona} | {score} | {high/medium/low label} |
| **Overall** | **{overall}** | |

### Fix Prompts
{For each ACTION item, render the ai_prompt in a clearly labeled fenced block:}

**{priority} — {action description}**
```
{ai_prompt}
```

{End with a reminder:}
> **Note**: This is a read-only review. No files were modified. Copy the prompts above into Claude Code to apply fixes.
```

---

## Generate HTML Viewer

After presenting terminal results, generate the self-contained HTML viewer.

### Step 1: Verify template exists

Check that the viewer template is available at `~/.claude/skills/council/templates/viewer.html`. If the file is missing, tell the user:

> HTML viewer template not found. Run `./setup.sh` from the claude-council repo to install it. Skipping viewer generation.

Then skip Steps 2 and 3 — continue with the rest of the flow (follow-up, etc.) as normal.

### Step 2: Generate the HTML

Use a Bash command to generate the viewer. The python script reads all JSON directly from the session directory files — do NOT pass JSON as shell arguments.

```bash
python3 -c "
import sys, json, glob, os

def safe(s):
    return s.replace('</', '<\\\\/')

template_path = sys.argv[1]
session_dir = sys.argv[2]

template = open(template_path).read()

meta = json.dumps(json.load(open(os.path.join(session_dir, 'meta.json'))))

opinions = {}
for f in sorted(glob.glob(os.path.join(session_dir, 'stage1', 'opinion_*.json'))):
    name = os.path.basename(f).replace('opinion_', '').replace('.json', '')
    opinions[name] = json.load(open(f))

synth_path = os.path.join(session_dir, 'synthesis.json')
synth = json.dumps(json.load(open(synth_path))) if os.path.exists(synth_path) else '{}'

reviews = {}
for f in sorted(glob.glob(os.path.join(session_dir, 'stage2', 'review_*.json'))):
    name = os.path.basename(f).replace('review_', '').replace('.json', '')
    reviews[name] = json.load(open(f))

template = template.replace('__META_JSON__', safe(meta))
template = template.replace('__OPINIONS_JSON__', safe(json.dumps(opinions)))
template = template.replace('__SYNTHESIS_JSON__', safe(synth))
template = template.replace('__REVIEWS_JSON__', safe(json.dumps(reviews)))

with open(os.path.join(session_dir, 'viewer.html'), 'w') as f:
    f.write(template)
" ~/.claude/skills/council/templates/viewer.html "${SESSION_DIR}"
```

### Step 3: Open it

```bash
if command -v open &>/dev/null; then
  open "${SESSION_DIR}/viewer.html"
elif command -v xdg-open &>/dev/null; then
  xdg-open "${SESSION_DIR}/viewer.html"
else
  echo "Open ${SESSION_DIR}/viewer.html in your browser"
fi
```

Tell the user:
> **Viewer**: `{SESSION_DIR}/viewer.html`

**After generating the viewer, STOP and wait for user input.** Do not apply action items, make code changes, or spawn fix agents unless the user explicitly asks. Your role as orchestrator ends at presenting findings. The `ai_prompt` fields in action items are for the **user** to copy — not for you to execute.

---

## Follow-Up

After presenting results (whether from a fresh deliberation or `--revisit`), handle follow-up questions **only when the user initiates them**.

**Exception — `--peer-review` mode**: After presenting results and generating the viewer, the session is **complete**. Do not enter follow-up mode, do not offer to apply fixes, and do not spawn action agents. If the user wants to act on findings, they should copy the prompts or start a new non-peer-review session.

For all other modes:

1. **Answerable from existing analysis** — answer directly, citing which persona.
2. **Needs deeper investigation** — spawn a single Agent with the relevant persona (read its file fresh), providing the question, verdict, and follow-up. Use `model: "sonnet"`.
3. **Nudge (challenge an agent)** — spawn an Agent with that persona:
4. **Re-deliberate** — if the user wants a fresh take on the same question with the current codebase, run the full Stage 1 → Stage 3 pipeline again using the original question from `meta.json`. Save to a new session directory.

```
A council member's assumptions are being challenged. Reconsider your position.

## Original Question
{QUESTION}

## Your Original Opinion
{agent's Stage 1 JSON}

## The Challenge
{user's correction or new information}

## Instructions
1. Re-examine your opinion in light of this.
2. Use tools to verify any new claims.
3. Report what changed, what stayed, updated confidence.

## Output Format
JSON only:
{
  "original_recommendation": "What you said before",
  "updated_recommendation": "What you say now",
  "changed": true,
  "what_changed": "Explanation",
  "what_stayed": "Explanation",
  "updated_confidence": 0.85,
  "new_evidence": ["New findings"]
}
```

---

## Important Rules

- **Never answer the question yourself.** You are the orchestrator, not a panelist.
- **Always launch Stage 1 agents in parallel** — all in a single message.
- **Agents must investigate available artifacts.** Abstract opinions without grounded evidence mean the deliberation failed.
- **Use sonnet for panelists, opus for chairman.**
- **Pass full agent responses between stages** — don't summarize.
- **Persona files are the source of truth.** Always read them from disk — never hardcode persona text.
- **Always generate the HTML viewer** after presenting results.
- **Always create the session directory** and save all JSONs — this enables `list`, `revisit`, and viewer generation.
