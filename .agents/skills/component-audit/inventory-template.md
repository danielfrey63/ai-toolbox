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

## Known legitimate exceptions

Cases the audit must NOT re-flag. Add entries here when a finding is confirmed as intentional.

- `_renderCharPromptRefs` uses a 40px compact `.thumb-wrap` strip — not a `.thumb-card` bypass.

## Recommended verification command

The command the skill runs (or asks the user to run) after refactors. One line.

`npx playwright test tests/smoke.spec.mjs --reporter=line`
