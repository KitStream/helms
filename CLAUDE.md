    AGENT SAFEGUARDS (non-negotiable)

Operating principles

1. Prefer clear code over comments.
   - Use comments only for: non-obvious reasoning, security invariants, protocol quirks, or “why” that code cannot express.
   - Prefer descriptive names, small functions, and explicit types over commentary.

2. Solve root cause, not band-aids.
   - Do not add retries/timeouts/logging to hide failures unless the root cause is addressed or explicitly impossible to fix.
   - If a workaround is necessary, document the root cause and the exact reason it can’t be fixed now.

3. Use idioms of the language and ecosystem.
   - Follow standard style guides, conventions, directory layout, and tooling.
   - Avoid clever patterns that fight the ecosystem. Prefer boring, maintainable solutions.

Quality gates
4) Tests must run after each modification.

- After any functional change, run the relevant test suite locally (or in CI steps) and ensure it passes.
- If tests cannot run (missing dependency, environment), add or update a runnable test harness or clearly state what is required.
- Never leave the repo in a state where tests are known failing.

5. Documentation for all features.
   - Every new feature must have usage docs + one runnable example.
   - Docs must include intent, flags/config, and failure modes.
   - Prefer docs that answer user questions (“How do I…”) and include copy/paste snippets.

6. Update CHANGELOG with all changes.
   - Every user-visible change must be added to CHANGELOG.md under “Unreleased”.
   - Use categories: Added / Changed / Fixed / Security / Deprecated / Removed.
   - Mention migration steps if behavior changes.
   - The `artifacthub.io/changes` annotation in `Chart.yaml` is the chart-level changelog shown to consumers. Only include consumer-facing changes (new features, bug fixes, breaking changes, dependency bumps that affect behavior). Do not add chores, refactoring, CI changes, or test-only changes to it.

Robustness & correctness
7) Include error handling everywhere it matters.

- Never ignore errors; propagate with context.
- Wrap/annotate errors so the caller has actionable info.
- Ensure exit codes/return values are correct and consistent.

8. Test edge cases and invariants.
   - Add tests for: empty inputs, invalid inputs, boundary values, timeouts, large payloads (reasonable), and concurrency/ordering if relevant.
   - Include at least one test for each bug fixed to prevent regressions.

Security & safety (important for agentic tooling)
9) No harmful actions by default.

- Do not delete data, rotate secrets, publish releases, or mutate external systems unless explicitly requested.
- Treat external calls (network, cloud APIs) as “dangerous”: require explicit opt-in via config/flags.

10. Least privilege and safe defaults.

- Minimize permissions, capabilities, scopes, and access tokens.
- For Kubernetes artifacts: runAsNonRoot, readOnlyRootFilesystem, allowPrivilegeEscalation=false, drop ALL capabilities unless justified.

11. No secret leakage.

- Never print tokens, passwords, or full credential material to logs.
- Redact known secret patterns; avoid echoing env vars that might contain secrets.

12. Deterministic builds and reproducibility.

- Prefer pinned versions, lockfiles, and deterministic packaging.
- Avoid “download latest at build time” unless necessary.

Change management rules
13) Chart versions must only be updated via the /release skill.

- **Never** bump `version` in Chart.yaml manually or as part of a regular change.
- Chart version bumps, changelog updates, and release commits are handled exclusively by the release skill.

14. Small, reviewable diffs.

- Prefer incremental changes with clear commit boundaries.
- If a refactor is needed, do it in a separate commit/PR before feature changes.

15. Respect existing standards and tooling.

- Use the repo's existing lint/format/test tools (Makefile/package scripts/cargo test/etc.).
- If tooling is missing, add it in a minimal conventional way.

16. Provide a “How to verify” section in PR descriptions/output.

- Include exact commands: build, lint, unit tests, integration tests (if any).

Agent execution constraints (for local runners / GH actions)
17) Only modify files that are in-scope for the task.

- Do not reformat unrelated files.
- Do not introduce new dependencies unless justified.

18. When uncertain, choose the safer option and make it explicit.

- Prefer failing fast with actionable errors over silent fallback.
- If ambiguity remains, implement a guardrail and document the decision.

19. When really uncertain, ask for help.

- Avoid making assumptions without asking for confirmation.

### Definition of defining an issue

- Gather requirements.
- Create a github issue.
- Include a clear description and motivation of the problem.
- Include:
  - Expected behavior.
  - Test cases.
  - Use cases.
  - Acceptance criteria.

### Definition of implement issue

- Find the issue in github issues.
- If not found, inform the user.
- If found:
  - Fetch the git origin
  - Create a branch with the issue number in the name from origin/main.
  - Implement the issue.
  - Run all e2e tests.
  - If during implementation, obvious errors was found in the ooriginating issue, also add a comment to the issue about the fix.
  - If running from Claude Code or Claude Desktop:
    - Do NOT create a PR automatically.
    - Instead, present a summary of changes and let the user decide when to create the PR.
  - Otherwise (e.g. GitHub Copilot, Junie, or other automated agents):
    - Create a PR with the issue number in the title.
    - Make sure the PR passes CI.

### Definition of done

- Code compiles without warnings.
- Code is linted.
- Code is formatted.
- Tests pass.
- Docs updated.
- CHANGELOG updated.
- Edge cases tested.
- Security posture maintained.
- Output includes a concise summary of changes + how to verify.
- For rust code:
  - All unsafe code is annotated.
  - Use explicit lifetimes where necessary.
  - Use clippy lints.
