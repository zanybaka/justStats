## Phase 16 — Reclaimable space cleanup (2026-10-11, from manual cleanup session)

- [ ] CLEAN-005 Copy AI prompt for deeper analysis (English, with preview)
Task Context
FR16: AIPromptBuilder produces the English prompt per TECHSPEC §12.3 from scanner output, a preview sheet shows the full text, Copy puts it on NSPasteboard. Entry point is a quiet link under Reclaimable space and under largest files: 'Still short on space? Copy AI prompt'. Prompt carries the safety preamble first so the assistant is read-only by default.
Task DOD
Pure-function builder unit-tested with golden text; preview shows exactly what is copied; no network; works when the Reclaimable section is empty; paths in the text are the only personal data and the preview says so.
Source: owner
Priority: P3
Size: S
Depends on: CLEAN-002
Agent: auto
Verify: xcodebuild test; manual — paste prompt into an assistant
