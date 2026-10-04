---
name: component-audit
description: Audits a codebase for component-orientation drift – finds UI/DOM construction that bypasses the project's shared factories, hand-rolled patterns that deserve a factory, and stale exceptions, then refactors the findings, verifies and commits. Driven by a project-local component inventory. Optionally uses OpenAI Codex as a cross-model read-only auditor. Use after any UI-touching change or when the user asks to verify component consistency, check for duplication or audit the components. Trigger: «Komponenten prüfen», «Component-Audit», «Duplikate im UI suchen».
metadata:
  version: "0.8.2"
---

# Component-Audit Skill

Makes sure UI code goes through the project's shared component factories instead of duplicating construction logic. Bypasses are bug magnets: hand-built markup means dead CSS, visual drift and broken layout rules that the factories silently encode.

The skill is project-agnostic. The project defines factories, bypass patterns and target files in an inventory file; the skill brings the workflow: read-only audit → punch list → refactor → verify → commit.

**Whoever audits never refactors.** The auditor is read-only and produces the punch list, Claude applies it. With the default auditor (a Claude Explore agent) that is a separation of context; with `auditor=codex` it is a separation of models.

## Component inventory

Resolution order:

1. Argument passed when invoking the skill (a path to a markdown file).
2. `.claude/component-inventory.md` in the project root.
3. `COMPONENT_INVENTORY.md` in the project root.

If none exists, ask the user once where the inventory lives, or offer to bootstrap one (see "Bootstrap").

Canonical structure: [inventory-template.md](inventory-template.md). Required sections:

- **Target files** – paths/globs the audit scans.
- **Factories** – shared constructors that must not be bypassed.
- **Layout contracts** – CSS classes that are part of the component contract.
- **Bypass patterns (grep recipes)** – concrete regexes or search heuristics; they make the audit deterministic.
- **Known legitimate exceptions** – cases the audit must not re-flag.
- **Recommended verification command** – one command to run after refactors (workflow step 5).

## Arguments

Read from the invocation (`/component-audit auditor=codex rounds=3 <inventory path>`), else default:

| Arg | Default | Meaning |
|-----|---------|---------|
| `auditor` | `claude` | `claude` = read-only Explore agent (own context). `codex` = OpenAI Codex CLI in a read-only sandbox; loop rounds resume the same Codex session. |
| `rounds` | `1` | Rounds for step 7; `1` = single audit + refactor. |
| `breadth` | `medium` | Search breadth hint for the auditor (`medium` / `very thorough`). |

Echo the resolved values in one line before the audit starts. For `auditor=codex`, read [references/codex-auditor.md](references/codex-auditor.md) first (prerequisites, launch commands, write guard, session resume).

## Workflow

1. **Resolve the inventory.** Load it per the resolution order. Surface a one-line summary of what will be audited (target files + count of bypass patterns).

2. **Run the read-only audit** – never in the main session's own context, so the punch list comes from something that did not just write the code. Build the prompt from [references/audit-prompt.md](references/audit-prompt.md), filled with the inventory.
   - `auditor=claude`: spawn `Agent({ subagent_type: 'Explore', description: 'Component-bypass audit', prompt: <filled audit prompt> })`.
   - `auditor=codex`: follow [references/codex-auditor.md](references/codex-auditor.md).

3. **Review findings.** Classify each entry into one of five buckets – every bucket has a code action AND an inventory action:
   - **Bypass → direct factory replacement.** Refactor inline. Inventory unchanged.
   - **Almost-fits → extend the factory.** Add the small option, then call it. Inventory: update the factory entry if the call surface changes.
   - **Repeated hand-built pattern without factory (3+ similar sites).** Extract a new factory. Inventory: add it to Factories AND add a grep recipe to Bypass patterns so the next audit defends it.
   - **Legitimate exception.** Add it to the inventory's exceptions section.
   - **Exception re-examined.** `still valid` → leave, stamp the re-examination date on the section; `valid but narrowed` → rewrite the entry to the narrowed scope and fix whatever fell outside; `no longer valid` → fix the finding and move the entry to the "Struck" section.

4. **Apply refactors AND inventory updates in the current turn.** Migrate to factory calls, drop the dead inline code, cross-check that no other site still uses the old pattern. Inventory edits are part of this step, not a follow-up.

5. **Verify.** Run the inventory's "Recommended verification command". If missing, ask the user once and offer to add it. Tests must stay green; if a user-facing surface changed, run the targeted spec too.

6. **Commit + push** as a refactor-only commit in the repo's commit style. Body: what bypass was found (one sentence), which factory now owns it, what was deleted.

7. **Loop until clean (optional).** When the user asks for a loop or passes `rounds=N`, repeat steps 2–6. Stop when a round reports **zero substantial findings**, or at `rounds`.
   - Update the inventory BETWEEN rounds (new factories, extended options, accepted, narrowed or struck exceptions), otherwise the next round re-flags the previous round's output.
   - Commit each round separately.
   - Minor findings may be fixed opportunistically but do not keep the loop alive.
   - Finish with a confirmation round (reduced breadth is fine) that spot-checks earlier fixes.
   - With `auditor=codex`, Claude arbitrates every finding (accept or reject with a logged reason in the commit body).

## Bootstrap (no inventory yet)

1. Survey the target files for repeated patterns (DOM-construction helpers, factory-like functions returning markup, layout CSS classes referenced from JS).
2. Keep the inventory under version control: if `git check-ignore .claude/component-inventory.md` reports it as ignored, write `COMPONENT_INVENTORY.md` in the project root instead.
3. Draft the inventory from [inventory-template.md](inventory-template.md) – observed factories, bypass recipes derived from their distinctive markers.
4. Show the draft, let the user confirm/edit, then commit it.

Do not audit against a bootstrapped inventory before the user has reviewed it – false-positive-heavy audits waste the refactor turn.

## Key rules

- **Never duplicate.** 3 similar call sites = look for a shared factory; 4 = factor out.
- **CSS classes are part of the component contract.** Layout classes define WHERE, factories define WHAT.
- **No new low-level primitives where a factory exists** (file inputs, toolbar markup, card construction).
- **The auditor never edits.** A round that leaves the tree dirty is failed, not "helpful".
- **Refactor in the same turn.** If a refactor is genuinely too large, say so and propose a separate scoped session.
- **The inventory is a living document.** A factory missing from the inventory is invisible to the next audit, which then flags its call sites as bypasses.
- **Exceptions expire.** Every audit re-examines each exception; narrowed ones are rewritten, struck ones move to "Struck".
- **Dead contract classes are findings.** Delete leftovers or wire up the second implementation.
