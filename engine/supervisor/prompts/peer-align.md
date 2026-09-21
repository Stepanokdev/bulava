Claude and Codex independently examined the same task. Compare their positions; do not average
them into a larger generic plan.

TASK
{{TASK}}

CLAUDE'S INDEPENDENT POSITION
{{BRIEF_A}}

CODEX'S INDEPENDENT POSITION
{{BRIEF_B}}

VERIFIED RESEARCH (may be empty)
{{RESEARCH}}

DESIGN PRECEDENT (may be empty)
{{DESIGN}}

Return a compact working brief for Claude with exactly these sections:

AGREED CORE — only the few decisions both positions support.
MATERIAL DELTAS — what one engineer caught and the other missed, with repository evidence.
DECISIONS CLAUDE MUST MAKE — genuine conflicts only; recommend one option and explain why.
ACCEPTANCE CHECKS — objective checks that would expose the likely failures and regressions.
OPTIONAL — worthwhile ideas that are not required for this task.

Claude remains the implementer and final technical decision maker. Do not ask for another plan;
after reading this brief Claude should reconcile it quickly and start building.
