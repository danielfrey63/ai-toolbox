# Component Inventory — {{project name}}

Used by the `component-audit` skill. Defines what counts as a factory, what counts as a bypass, and which files to scan in this project.

## Target files

- path/to/main-ui.html        # primary file(s) to audit
- src/components/**/*.tsx     # globs are fine

## Factories

List shared factories that produce UI/DOM. One per line: name, signature, short description, and what a bypass looks like.

- `renderThumbCard(opts)` — produces `<div class="thumb-card">…</div>`. Bypass = manual `.thumb-card` construction.
- `createUploadButton(opts)` — produces `<label class="upload-btn">` with hidden file input. Bypass = any `<input type="file">` outside this factory.
- `textareaToolbar(id, label, opts)` — standardized expand/copy/upload row. Bypass = ad-hoc toolbar markup next to a `<textarea>`.

## Layout contracts (CSS classes that are part of the component contract)

- `.card-header-actions` — wraps action buttons; layout rules depend on it.
- `.briefing-field` — wraps label+input in forms.

## Bypass patterns (grep recipes)

Numbered list of concrete patterns the audit agent will grep for. Each entry needs a regex or a clearly described search heuristic.

1. Direct `.thumb-card` construction: `className\s*=\s*['"\x60].*thumb-card`
2. Hand-rolled file inputs: `<input\s+type=['"\x60]file`
3. Filenames bypassing `downloadName`: `\.download\s*=\s*['"\x60]` not preceded by `downloadName(`
4. Action-buttons direct in `.card-header` (skipping `.card-header-actions`) — inspect each `<div class="card-header">` block.
5. Inline-styled flex blocks that match an existing class: `style=['"\x60][^'"\x60]*display:\s*flex`
6. Show/hide via inline display where a `hidden` attribute or a state class exists: `style\.display\s*=` and `style=['"\x60]display:` — list the allowed sites explicitly.
7. Static values under a "dynamic" label: `\.style\.(cursor|background|margin\w*|padding\w*|zIndex)\s*=` with a literal — belongs in CSS.
8. Dead contract classes: every class selector in the stylesheet(s) without a producer in the target files (`grep -o '\.[a-z][a-z0-9-]*' styles.css | sort -u` against `grep -rho` over the target files) — delete or wire up. Keep this recipe; it catches leftovers no factory-specific recipe sees.

## Known legitimate exceptions (last re-examined YYYY-MM-DD)

Cases the audit must NOT re-flag as findings — but every audit re-examines them (does the code still exist, is the justification still true, has the pattern spread?) and updates the date above. State the justification, not just the location, so the next audit can verify it. Narrowed exceptions are rewritten; struck ones move to the section below.

- `_renderCharPromptRefs` uses a 40px compact `.thumb-wrap` strip — not a `.thumb-card` bypass (single site, own layout contract).
- Dynamic values stay inline — closed list: context-menu `left`/`top`, tooltip `left`/`top`, computed colours on chips. Anything else inline under this label is a bypass.

## Struck (no longer exists — do not re-add)

Former factories, contract classes or exceptions that were removed, with the date. Keeps a later audit (or a stale memory) from re-introducing them.

- `17-fuzzy-dialog.js` / `.fuzzy-match-*` — torn down with v1 (2026-08-29).

## Recommended verification command

The command the skill runs (or asks the user to run) after refactors. One line.

`npx playwright test tests/smoke.spec.mjs --reporter=line`
