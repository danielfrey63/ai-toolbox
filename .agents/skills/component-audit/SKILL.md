---
name: component-audit
description: Audit a codebase for component-orientation drift — finds DOM/UI-construction bypasses, hand-rolled patterns that should go through shared factories, and refactor opportunities, then routes them through the right component. Use after any UI-touching change, or when the user asks to "verify component consistency", "check for duplication", "audit the components". Works on any project — reads the project's component inventory from `.claude/component-inventory.md` (or a path passed as argument).
metadata:
  version: "0.2.7"
---

# Component-Audit Skill

Use this skill when UI code has changed and you want to make sure new code goes through the project's shared component factories instead of duplicating construction logic. Bypasses are bug magnets — hand-built markup means dead CSS, visual drift, and broken layout-rules that the factories silently encode.

This skill is **project-agnostic**. The project itself defines what counts as a factory, what counts as a bypass, and which files to scan, via a small inventory file. The skill brings the workflow: spawn a read-only audit, get a structured punch list, refactor in-place, verify, commit.

## Setup — Component Inventory

The skill expects a project-local inventory file describing the factories and bypass patterns. Resolution order:

1. Argument passed when invoking the skill (e.g. a path to a markdown file).
2. `.claude/component-inventory.md` in the project root.
3. `COMPONENT_INVENTORY.md` in the project root.

If none exists, **ask the user once** where the inventory lives, or offer to bootstrap one by exploring the codebase (see "Bootstrap" below).

### Inventory format

Use the template in `inventory-template.md` (next to this SKILL.md) as the canonical structure. Required sections:

- **Target files** — paths/globs the audit scans.
- **Factories** — shared constructors that must not be bypassed.
- **Layout contracts** — CSS classes that are part of the component contract.
- **Bypass patterns (grep recipes)** — concrete regexes or search heuristics; this is what makes the audit deterministic.
- **Known legitimate exceptions** — cases the audit must NOT re-flag.
- **Recommended verification command** — single command to run after refactors (see Workflow step 5).

The factories list is the human-readable map. The bypass patterns drive the agent. The exceptions list prevents repeat false positives. The verification command makes step 5 non-interactive.

## Workflow

1. **Resolve the inventory.** Load the file (per resolution order above). If unclear, ask. Surface a one-line summary of what will be audited (target files + count of bypass patterns).

2. **Spawn a read-only audit agent** so it can't accidentally mutate the codebase:

   ```
   Agent({
     subagent_type: 'Explore',
     description: 'Component-bypass audit',
     prompt: <see Audit Prompt template below, filled with the inventory>
   })
   ```

3. **Review findings.** Classify each entry into one of four buckets — every bucket has a code action AND an inventory action:
   - **Bypass → direct factory replacement.** Refactor inline. Inventory unchanged.
   - **Almost-fits → extend the factory.** Add the small option, then call. **Inventory:** update the factory's entry to mention the new option, if it changes the call surface.
   - **Repeated hand-built pattern without factory (3+ similar sites).** Extract a new factory. **Inventory:** add the new factory to the Factories section AND add a fresh grep recipe to Bypass patterns so the next audit defends it.
   - **Legitimate exception.** Add it to the inventory's exceptions section so the next audit doesn't re-flag it.

4. **Apply refactors AND inventory updates in the current turn.** Don't just report — fix. Migrate to factory calls, drop the dead inline code, cross-check that no other site still references the old pattern. If a new factory was extracted or an existing one extended, the inventory edit is part of this step — not a follow-up.

5. **Verify.** Run the command from the inventory's "Recommended verification command" field. If the field is missing, ask the user once and offer to add it to the inventory. Tests must stay green. If a user-facing surface changed, run the targeted spec too.

6. **Commit + push** as a refactor-only commit (project's commit-style applies — per repo convention English/German, conventional commits, etc.). Body structure:
   - What bypass was found (one sentence)
   - Which factory now owns it
   - What was deleted

7. **Loop until clean (optional).** When the user asks for a loop ("run until no substantial findings remain"), repeat steps 2–6 as rounds. The exit criterion is the audit's severity verdict: stop when a round reports **zero substantial findings**. Rules per round:
   - Update the inventory BETWEEN rounds — every extracted factory, extended option and accepted exception goes in before the next audit prompt is built, otherwise the next round re-flags the previous round's own output.
   - Commit each round separately (one verified, revertable step per round).
   - Minor/cosmetic findings may be fixed opportunistically in a round, but they do not keep the loop alive on their own.
   - Run a final confirmation round (reduced search breadth is fine) that spot-checks the earlier fixes and confirms the zero-substantial verdict.

## Audit Prompt Template (for the spawned agent)

Fill the `{{…}}` placeholders from the inventory before passing to the agent.

```
You are a component-orientation auditor for the following project.

Target files: {{target files / globs from inventory}}

Factories (must be used instead of hand-rolled equivalents):
{{factories list, one per line}}

Layout-classes that are part of the component contract:
{{layout contracts list}}

Report patterns where the code BYPASSES one of the above. For each finding, give file:line + a one-line note "bypass" / "almost-fits — extend with X" / "legitimate exception".

Run each grep recipe below and inspect a small block around every hit:

{{bypass patterns list, numbered}}

Known legitimate exceptions (do NOT re-report):
{{exceptions list}}

Report format:
  - Group findings under the numbered categories above.
  - For each finding: file:line, 5-word summary, one of "bypass" / "extend X" / "factory candidate (N similar sites)" / "exception", a severity judgement "substantial" / "minor", suggested refactor target.
  - Severity rubric: "substantial" = duplicated construction logic, inline styling that imitates or should be a CSS class, or any pattern that will drift (3+ sites, bulk static styles); "minor" = cosmetic single-property issues or inconsistencies with no drift risk.
  - End with a one-line verdict that counts severities first (e.g. "2 substantial, 3 minor — 3 bypasses, 1 extension opportunity, 1 factory candidate").

Do NOT modify files. Read-only.
```

## Bootstrap (when no inventory exists)

If the project has no inventory and the user wants one, propose:

1. Quickly survey the target file(s) for repeated patterns (DOM-construction helpers, factory-like functions returning markup, layout-CSS classes referenced from JS).
2. Draft `.claude/component-inventory.md` with the structure above — factories you observed, bypass-grep recipes derived from their distinctive markers.
3. Show the draft, let the user confirm/edit, then commit it.

Don't run the audit on a bootstrapped inventory until the user has reviewed it — false-positive-heavy audits waste the refactor turn.

## Key Rules

- **Never duplicate.** 3 similar call sites = look for shared factory; 4 = factor out.
- **Bypass = bug magnet.** Hand-built markup means dead CSS, visual drift, and broken layout rules the factory silently enforces.
- **CSS classes are part of the component contract.** Layout classes define WHERE; factories define WHAT. Code that ignores the class loses the WHERE.
- **No new low-level primitives where a factory exists.** New file-inputs, new toolbar markup, new card-construction outside the factory all drift.
- **Refactor in the same turn.** Don't drop a punch list and stop — apply the fixes, verify, commit. If a refactor is genuinely too large, say so and propose a separate scoped session.
- **Feed exceptions back into the inventory.** A legitimate exception flagged twice means the inventory is incomplete, not that the user has to re-explain.
- **Inventory is a living document.** Every new factory extracted, every factory extended, every legitimate exception accepted goes back into `.claude/component-inventory.md` in the same turn. A factory that exists in code but not in the inventory is invisible to the next audit — and the next audit will then flag *its* call sites as bypasses.
