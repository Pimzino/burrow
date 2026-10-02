## What and why

<!-- What does this change, and why? Link any related issue (Fixes #123). -->

## How it was tested

- [ ] `swift build` finishes with zero errors and zero warnings
- [ ] `./scripts/build-app.sh debug` produces a working `build/Burrow.app`
- [ ] E2E: `./scripts/e2e.sh <routes>` (paste the summary line below)
- [ ] Destructive flows were exercised with `--dry-run` only, or on a disposable account or VM

```
E2E summary:
```

## Safety checklist

- [ ] No automation or E2E path starts a destructive action (scans, dry runs, listings and JSON reports only)
- [ ] Every new destructive action has an in-app confirmation listing what will happen, and Return does not confirm it
- [ ] Prompts where end-of-input means "yes" use `keepInputOpen: true`
- [ ] `admin: true` is used only where `sudo` is really needed
- [ ] No new third-party dependencies

## Screenshots

<!-- For UI changes: before and after, light and dark mode. -->
