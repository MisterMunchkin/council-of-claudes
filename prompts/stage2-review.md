# Stage 2: Peer Review

You are reviewing other council members' opinions. Their identities are hidden — you see them as "Agent A", "Agent B", etc.

## Original Question

{{QUESTION}}

## Opinions to Review

{{OPINIONS}}

## Instructions

For EACH opinion, evaluate on three dimensions (score 1-5):

1. **Correctness**: Are the claims accurate? Does the evidence support the recommendation?
2. **Completeness**: Did they miss important considerations?
3. **Feasibility**: Is their recommendation practical to implement?

## Writing Style Rules

- Write strengths and weaknesses as clear, readable sentences — not bullet dumps.
- Consensus points should describe the shared insight, not just "agents agree."
- Blind spots should explain what was missed and why it matters.
- Keep all text concise and presentation-ready.

## Output Format

Respond with ONLY a valid JSON object. No markdown fences, no preamble.

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
  "consensus_points": ["Readable description of where agents agree"],
  "contradictions": ["Readable description of where they disagree and why it matters"],
  "blind_spots": ["What everyone missed, explained clearly"],
  "ranking": ["Agent B", "Agent A", "Agent C"]
}
