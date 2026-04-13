# /council-init — Bootstrap a Council for Your Project

Generate a tailored panel of expert personas for `/council` deliberations, scoped to the current project.

## Usage

```
/council-init
/council-init "I need 3 council members who can help review our React Native architecture"
/council-init "I want perspectives from someone who knows auth, someone focused on DX, and a mobile performance expert"
/council-init "Set up a council for evaluating our data pipeline changes"
```

## How It Works

### Step 1: Understand the project

Before generating personas, briefly explore the codebase to understand what kind of project this is:
- Read `package.json`, `Cargo.toml`, `go.mod`, `pyproject.toml`, or equivalent to identify the stack
- Glance at the directory structure to understand the architecture
- Check for existing `.council/personas/` — if it already exists, tell the user and ask if they want to regenerate or add to it

### Step 2: Determine the panel

**If the user provided a prompt:** Use their description to determine what personas to create. The user may specify:
- A number of members ("I need 3 members...")
- Specific expertise areas ("someone who knows auth, someone focused on DX")
- A general need ("help review our architecture") — infer the right experts

**If no prompt (bare `/council-init`):** Generate 3 default personas tailored to the project's stack. For example:
- A TypeScript/React project might get: architect, pragmatist, frontend-perf
- A Go backend might get: architect, pragmatist, security-perf
- A Python ML project might get: architect, data-engineer, ml-ops
- An AI tooling project might get: architect, ai-tooling, developer-experience

Use your understanding of the codebase from Step 1 to pick relevant defaults. Don't just always use the same three.

### Step 3: Create the directory and personas

```bash
mkdir -p .council/personas
```

For each persona, write a `.md` file to `.council/personas/{name}.md` using this exact format:

```
You are a **{ROLE TITLE}** on this council.

Your lens: {one-line focus area description}.

When analyzing a question:
- {analysis point 1 — specific to the role}
- {analysis point 2}
- {analysis point 3}
- {analysis point 4}
- {analysis point 5}

You have full access to the codebase and all available tools/MCPs. USE THEM. Read files, grep for patterns, check git history, query knowledge graphs if available — ground every opinion in what the code actually looks like today.
```

Rules for writing analysis points:
- 5-6 points per persona
- Each point should be an actionable instruction, not a vague description
- Points should be specific to the role — avoid generic advice that any engineer would give
- Reference the kinds of things this expert would actually look for in a codebase

### Step 4: Add .council/sessions/ to .gitignore

Check if `.gitignore` exists. If so, check if `.council/sessions/` is already in it. If not, append:

```
# Council deliberation sessions (local)
.council/sessions/
```

Session data is local — it shouldn't be committed. But personas should be version-controlled so the team shares the same panel.

### Step 5: Confirm

Present the created panel:

```
Council initialized with {N} personas:

  {icon} {name} — {lens one-liner}
  {icon} {name} — {lens one-liner}
  {icon} {name} — {lens one-liner}

Personas: .council/personas/
Sessions: .council/sessions/ (gitignored)

Ready to use:
  /council "your question here"
  /council-persona "add another expert"
```

Use these icons based on role type (pick the closest match):
- Architect/systems: 🏗️
- Pragmatist/DX/shipping: 🚀
- Security: 🛡️
- Performance: ⚡
- Data/ML: 📊
- DevOps/infra: 🔧
- QA/testing: 🧪
- Frontend/UX: 🎨
- AI/LLM: 🤖
- API/integration: 🔌
- Mobile: 📱
- General/other: 💡

## Rules

- Always explore the codebase before generating personas — even briefly. Uninformed defaults are worse than informed ones.
- Persona filenames must be kebab-case.
- Every persona must end with the "full access to the codebase" paragraph.
- 5-6 analysis points per persona. Fewer is vague, more is noise.
- Don't create more personas than the user asked for. If they said 3, create 3. If unspecified, default to 3.
- If `.council/personas/` already exists with files in it, warn the user before overwriting. Offer to add new personas alongside existing ones.
- Do NOT add JSON output format instructions to personas — that's the `/council` skill's job.
