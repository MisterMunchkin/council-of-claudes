# /council — Claude Council Deliberation

Convene a panel of expert agents to deliberate on engineering problems through structured multi-stage discussion, peer review, and synthesis — all within Claude Code using native Agent parallelism with full tool and MCP access.

## Usage

```
/council "Should we migrate from Zustand to Jotai for state management?"
/council --with-review "How should we restructure the auth module?"
/council --quick "What testing framework should we add?"
/council --personas architect,pragmatist "Just these two perspectives"
/council --revisit SESSION_ID
```

## Orchestration

When the user invokes `/council`, you become the **orchestrator**. You do NOT answer the question yourself. You run a structured deliberation protocol using the Agent tool to spawn parallel expert sessions, then synthesize their findings.

Every spawned agent has full access to all tools and MCP servers available in this session.

---

## Step 0: Parse and Prepare

Extract from the user's message:

- **QUESTION**: The deliberation question
- **MODE**: `standard` (default — prompts for review after Stage 1), `--with-review` (auto-includes Stage 2, no prompt), `--quick` (Stage 1 only), or `--revisit SESSION_ID` (reload a past session)
- **PERSONAS**: If `--personas` flag given, use those names. Otherwise use all personas in the directory.

### Handle --revisit

If the user passed `--revisit SESSION_ID`, skip all stages and go directly to **Revisit Mode**:

1. Read `.council/sessions/{SESSION_ID}/meta.json` to get the original question and personas
2. Read `.council/sessions/{SESSION_ID}/synthesis.json` for the verdict
3. Read all `.council/sessions/{SESSION_ID}/stage1/opinion_*.json` for individual opinions
4. Present the results using the same format as **Presenting Results**
5. If `${SESSION_DIR}/viewer.html` does not exist, generate it using the **Generate HTML Viewer** steps
6. Enter **Follow-Up** mode — the user can ask questions, nudge agents, or request a fresh re-deliberation with the current codebase

If the session ID doesn't exist, list available sessions from `.council/sessions/*/meta.json` and ask the user to pick one.

### Load personas

Read persona `.md` files from `.council/personas/` in the current project directory. Each `.md` file defines one persona. The filename (minus `.md`) is the persona identifier.

If `.council/personas/` doesn't exist or is empty, tell the user to run `/council-init` first and stop.

If `--personas` was specified, load only those. If a requested persona doesn't exist, tell the user and suggest `/council-persona` to create it.

If no `--personas` flag, load all `.md` files in the personas directory.

### Initialize session

Create a session directory for storing results and the HTML viewer:

```bash
SESSION_ID="$(date +%Y%m%d_%H%M%S)_$(openssl rand -hex 4)"
SESSION_DIR=".council/sessions/${SESSION_ID}"
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
  "personas": ["architect", "pragmatist", "security-perf"],
  "timestamp": "ISO 8601 UTC",
  "status": "in_progress"
}
```

---

## Stage 1: Independent Opinions

Launch **one Agent call per persona, all in a single message** so they run in parallel. Use `model: "sonnet"` for all.

Set each agent's `description` to `"Council: {persona_name} opinion"`.

### Agent prompt template

Build each agent's prompt by combining the persona text with this template:

```
You are a council member deliberating on an engineering question. You must provide your independent opinion — you have no knowledge of what other council members will say.

## The Question

{QUESTION}

## Your Role

{PERSONA — the full text from the persona .md file}

## Instructions

1. **Investigate first.** Use your tools to examine the actual codebase before forming an opinion. Read relevant files, grep for patterns, check git history. You have full access to all tools and MCP servers — use whatever is most effective. If GitNexus or other knowledge graph tools are available, use them to query architecture, dependencies, and impact analysis.
2. **Form your opinion.** Based on what you found, provide a clear recommendation.
3. **Be thorough but concise.** Reference specific files and patterns. Do NOT paste entire files or raw grep output.

## Output Format

Respond with ONLY a valid JSON object — no markdown fences around it, no preamble, no text outside the JSON. You MAY use markdown formatting (backticks, bold, italics) inside JSON string values.

{
  "recommendation": "Clear, actionable recommendation in 1-3 sentences. Reference key files with `backticks`.",
  "reasoning": [
    "Each point grounded in codebase evidence, using `backticks` for code refs."
  ],
  "codebase_evidence": [
    "What you found in `path/to/file` — describe the pattern, don't paste contents."
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

### Prompt for peer review

If the mode is `standard` (not `--quick` and not `--with-review`), ask the user:

> The council has given their opinions. Would you like them to **peer review** each other's positions before synthesis? This adds an anonymous scoring round where each agent evaluates the others.
>
> **y** — run peer review, then synthesize
> **n** — skip to synthesis (default)

If the user says yes, proceed to Stage 2. If no (or if they just want to move on), skip to Stage 3.

If `--with-review` was passed, skip this prompt and go straight to Stage 2.

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
You are the Chairman of an engineering council. You must synthesize all opinions into a final verdict.

## Original Question

{QUESTION}

## All Stage 1 Opinions

### {persona_name}'s Opinion:
{full JSON opinion}

(repeat for each persona)

## Peer Review Results

{If --with-review: include all review JSONs with reviewer names. Otherwise: "No peer reviews conducted."}

## Instructions

1. **Identify true consensus** — where do all or most agents genuinely agree?
2. **Map the disagreements** — where do they diverge, and what causes it?
3. **Synthesize a recommendation** — the best path forward, weighing all perspectives.
4. **Create action items** — each with priority, type, action description, and an ai_prompt for actionable items.
5. **Set revisit triggers** — conditions under which to reconsider.

You have full access to the codebase and all tools/MCPs. Verify any claims you find questionable.

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
      "ai_prompt": "Complete prompt to copy-paste into Claude Code to execute this. Include files, constraints, intent. Set to null for type: note."
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

For standard/with-review modes:

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

---

## Follow-Up

After presenting results (whether from a fresh deliberation or `--revisit`), handle follow-up questions:

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
- **Agents must investigate the codebase.** Abstract opinions without file references mean the deliberation failed.
- **Use sonnet for panelists, opus for chairman.**
- **Pass full agent responses between stages** — don't summarize.
- **Persona files are the source of truth.** Always read them from disk — never hardcode persona text.
- **Always generate the HTML viewer** after presenting results.
- **Always create the session directory** and save all JSONs — this enables `list`, `revisit`, and viewer generation.
