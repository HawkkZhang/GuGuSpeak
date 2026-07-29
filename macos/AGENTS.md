# Agent Instructions (macOS)

This is the macOS subtree of the GuGuTalk monorepo. **Read the repo-root [`../AGENTS.md`](../AGENTS.md) first** — it covers the cross-platform structure and shared conventions.

All commands below assume your working directory is `macos/` (i.e. `cd macos` from the repo root before running them).

## Start Here

Before making changes, read:

- `../PRODUCT.md` — product definition (shared across platforms)
- `../DESIGN.md` — design system (shared across platforms)
- `MEMORY.md` — durable macOS project facts
- `HANDOFF.md` — current macOS development state
- `../README.md` — project overview

Then inspect the relevant source files before proposing or editing code.

## Collaboration Rules

- Preserve user work. Never revert or overwrite uncommitted changes without explicit approval.
- Prefer small, understandable changes over sweeping rewrites.
- Keep the app native to macOS. Use Swift, SwiftUI, and AppKit patterns already present in the repo.
- Use system font and native macOS controls unless there is a clear reason not to.
- Keep UI calm, compact, and restrained. Avoid flashy AI aesthetics, web dashboard styling, game-like panels, and decorative gradients.
- Update `HANDOFF.md` when the current state, next step, or known risks change.
- Update `MEMORY.md` when a durable project fact changes.
- **Stay inside `macos/`.** If you find yourself wanting to touch `windows/` or root-level shared docs, see the cross-cutting rules in `../AGENTS.md`.

## Build And Verification

For code changes, build with:

```bash
xcodebuild -project DesktopVoiceInput.xcodeproj -scheme DesktopVoiceInput -configuration Debug -derivedDataPath /tmp/DesktopVoiceInputDerivedData build
```

For user-facing changes, run the debug app after building:

```bash
open /tmp/DesktopVoiceInputDerivedData/Build/Products/Debug/DesktopVoiceInput.app
```

If another `DesktopVoiceInput` process is already running, stop it before opening the newly built app.

## Packaging And Artifacts

All generated DMG files must be stored in one canonical local artifact directory:

```bash
dist/dmg/
```

Use the packaging script instead of creating DMGs by hand:

```bash
./scripts/package-dmg.sh
```

`package-dmg.sh` runs `scripts/fresh-install-local.sh` after the DMG is created and verified. This hook stops and unregisters old GuGuTalk builds, moves the installed app and local GuGuTalk data to Trash, resets TCC permissions for `com.end.DesktopVoiceInput`, installs the newly packaged app in `/Applications`, and launches it. Packaging tasks for local user testing must keep this default behavior.

When full Xcode is unavailable, `package-dmg.sh` automatically uses `scripts/build-swiftpm-app.sh` to assemble the same signed app shape from the SwiftPM Release executable, bundled runtimes, repository icons, and verified local ASR models.

For artifact-only CI or an explicitly requested package without local installation, opt out deliberately:

```bash
GUGUTALK_SKIP_POST_PACKAGE_INSTALL=1 ./scripts/package-dmg.sh
```

Do not put DMGs in the repo root, `Packages/`, Desktop, Downloads, or ad-hoc temporary folders. `dist/dmg/*.dmg` and matching checksum files are local artifacts and must not be committed.

## Git Workflow

- Current stable checkpoint: `stable-2026-05-01`
- Stable commit: `960f2b3`
- Remote repository: `https://github.com/HawkkZhang/GuGuTalk`
- Current local branch may be `codex/archive-current-state` while tracking `origin/main`.

Before editing:

```bash
git status --short --branch
```

After a stable change:

```bash
git add -A
git commit -m "<short clear summary>"
git push
```

If pushing over HTTPS fails because macOS keychain credential helper interferes, use GitHub CLI credential helper for that push:

```bash
git -c credential.helper= -c credential.https://github.com.helper='!/opt/homebrew/bin/gh auth git-credential' push
```

## Sensitive Data

Do not commit:

- Qwen API keys
- Doubao App ID or Access Token
- personal tokens
- local user defaults
- signing certificates
- provisioning profiles
- machine-specific Xcode user data

Provider credentials are entered in the app settings and stored locally on each Mac.

## Product Guardrails

- This is not a system IME yet.
- This is not a meeting transcription app.
- This is not a voice command system.
- Partial recognition updates the overlay only.
- Final text is inserted only after the recording session ends.
- If insertion fails, keep the final text visible and copyable.

## Important UX Rules

- Permission guidance should appear only when useful.
- Required permissions are microphone and Accessibility only. Global hotkeys share the Accessibility grant; do not add separate Input Monitoring onboarding.
- Settings should be simple and grouped by task.
- Recognition mode is a single choice: local, Doubao, or Qwen.
- Only Doubao and Qwen need provider configuration.
- Shortcut recording must suspend global voice-input hotkeys.
- The overlay should stay small and out of the user's workspace.
- Long transcript preview should preserve the newest text and omit only from the beginning.
