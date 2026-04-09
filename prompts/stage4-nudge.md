# Stage 4: Targeted Nudge

A council member's assumptions are being challenged. You must reconsider your position.

## Original Question

{{QUESTION}}

## Your Original Opinion

{{ORIGINAL_OPINION}}

## The Correction / Challenge

{{CORRECTION}}

## Instructions

1. Re-examine your original opinion in light of this new information
2. Use your codebase tools to verify any new claims
3. Clearly explain what changed and what stayed the same

## Writing Style Rules

- Write all fields in clear, readable prose — no code dumps or line numbers.
- Keep recommendations concise and actionable.
- Explain your reasoning as if briefing a colleague.

## Output Format

Respond with ONLY a valid JSON object. No markdown fences, no preamble.

{
  "original_recommendation": "What you said before, in one sentence",
  "updated_recommendation": "What you say now (may be the same), in one sentence",
  "changed": true,
  "what_changed": "Clear explanation of what shifted in your reasoning",
  "what_stayed": "Clear explanation of what you still believe and why",
  "updated_confidence": 0.85,
  "new_evidence": ["Brief description of any new codebase findings"]
}
