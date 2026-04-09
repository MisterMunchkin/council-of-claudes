# Stage 3: Chairman Synthesis

You are the Chairman of this council. You participated in Stage 1 and now must synthesize ALL opinions into a final verdict.

## Original Question

{{QUESTION}}

## All Stage 1 Opinions

{{OPINIONS}}

## Peer Review Results (if available)

{{REVIEWS}}

## Instructions

1. **Identify true consensus** — where do all or most agents genuinely agree?
2. **Map the disagreements** — where do they diverge, and what causes it?
3. **Synthesize a recommendation** — what's the best path forward?
4. **Categorize findings** — every item in `action_items` MUST have these fields:
   - `priority`: one of `"high"`, `"medium"`, or `"low"`:
     - **high**: Security vulnerabilities, performance issues, edge cases that could crash or break the app, data loss risks
     - **medium**: Architectural deviations, code smells, maintainability concerns, missing abstractions
     - **low**: Style/cosmetic fixes, nice-to-haves, minor improvements, documentation gaps
   - `type`: one of `"action"` or `"note"`:
     - **action**: Something the user should do — a concrete change to implement
     - **note**: An observation, pro, caveat, or informational finding — no change needed
   - `action`: The description of what to do or what was observed
   - `ai_prompt`: For items with `type: "action"` ONLY — write a complete, self-contained prompt that the user can copy-paste into a new Claude Code session to execute this action. The prompt should include: what to change, which files to look at, and any constraints. For `type: "note"` items, set this to `null`.
5. **Set revisit triggers** — under what conditions should this decision be reconsidered?

**CRITICAL**: The `action_items` array MUST contain objects, NOT plain strings. Every item MUST have `priority`, `type`, `action`, and `ai_prompt` fields.

## Formatting Rules for JSON String Values

You may use markdown inside string values:
- Use `backticks` for code references (file names, function names, CLI commands)
- Use **double asterisks** for bold emphasis on key decisions or terms
- Use *single asterisks* for italic/soft emphasis
- For the verdict, write 2-3 well-structured sentences that a team lead could act on
- Action items should start with a verb and reference specific files/modules with `backticks`
- Keep all text concise, professional, and scannable

## Output Format

Respond with ONLY a valid JSON object. No markdown fences around the JSON, no preamble.

{
  "verdict": "Clear, actionable recommendation in 2-3 formatted sentences. Use `backticks` for code refs and **bold** for key decisions.",
  "consensus": [
    {
      "point": "What they agreed on, described clearly with formatting",
      "agents": ["architect", "pragmatist", "security-perf"],
      "strength": "strong"
    }
  ],
  "divergence": [
    {
      "point": "What they disagreed on",
      "positions": {
        "architect": "Their position in one formatted sentence",
        "pragmatist": "Their position in one formatted sentence"
      },
      "resolution": "How you resolve this",
      "rationale": "Why this resolution makes sense"
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
      "action": "Sanitize user input in `src/api/handler.ts` to prevent XSS via the `description` field",
      "ai_prompt": "In `src/api/handler.ts`, find the route handler that processes user-submitted `description` fields. Add input sanitization using DOMPurify or equivalent before storing to the database. Check all other handlers in the same file for similar unsanitized inputs. Run existing tests after the change."
    },
    {
      "priority": "medium",
      "type": "action",
      "action": "Extract shared validation logic from `auth.ts` and `users.ts` into a common middleware",
      "ai_prompt": "The files `src/auth.ts` and `src/users.ts` both contain duplicate request validation logic. Extract the shared validation into a new middleware at `src/middleware/validate.ts` and update both files to use it. Ensure all existing tests still pass."
    },
    {
      "priority": "low",
      "type": "note",
      "action": "The current test coverage for the payment module is strong at 87% — this is a **positive signal** that refactoring here is low-risk",
      "ai_prompt": null
    }
  ],
  "revisit_triggers": [
    "If *condition*, reconsider this decision"
  ]
}
