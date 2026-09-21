Two INDEPENDENT plans for the same task follow (Plan A from Claude, Plan B from Codex).
Task: "{{TASK}}"

Research brief (verified facts; may be empty):
{{RESEARCH}}

{{ARGUE}}

PLAN A (Claude):
{{PLAN_A}}

PLAN B (Codex):
{{PLAN_B}}

Merge the BEST of both into ONE plan — don't average into mush, pick the stronger option at
each point. Where they genuinely conflict, choose one and record the conflict under
"disagreements". Answer ONLY the JSON the schema asks for (goal, steps ≤12,
acceptance_criteria that the Verifier can check, risks, disagreements, and
proposed_redirection only if the literal task conflicts with its goal).
