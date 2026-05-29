# AGENTS.md

- When creating a branch, do not set an upstream. When pushing, set the upstream to a remote branch of the same name. Never set the upstream to main.
- Unless instructed otherwise, prefer minimal, low-duplication code built from as few concepts as the problem requires. Comment the why, not the what, where intent isn't obvious.
- Respect the existing clean architecture if the codebase already follows it.
- In planning mode, first ask the user whether they want a minimal-change approach or clean, compact code that may involve a wider rewrite.
- Do not introduce behavior, visual styling, or UX changes that were not explicitly requested. Keep changes scoped to the user's instructions.
- When checking an app bundle, confirm the displayed build ID is the expected value so old builds are not mistaken for current ones.
- Keep menu item labels in title case.
