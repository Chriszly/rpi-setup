## Summary

<!-- What does this PR do and why? Keep it short. -->

## Type of change

<!-- Check all that apply -->

- [ ] Bug fix
- [ ] New feature / new task
- [ ] Documentation update
- [ ] Refactor / cleanup
- [ ] Build / CI / tooling

## Checklist

- [ ] Code follows the existing pattern in `tasks/` (see `tasks/base.sh`)
- [ ] No secrets, passwords or personal info added
- [ ] README updated if task list, options or behavior changed
- [ ] Commit messages are clear and concise

---

<!-- Optional -->

## Testing

<!-- How was this verified? Include the exact commands/script you ran. -->

- [ ] Ran `bash -n tasks/<file>.sh` (shell syntax check) / `PSScriptAnalyzer` on changed scripts
- [ ] Ran the affected task(s) on a Raspberry Pi: `sudo bash setup.sh <task>`
- [ ] Re-ran an existing task to confirm idempotency (safe to re-run)

## Related issues / PRs

<!-- e.g. Fixes #12 -->

## Screenshots

<!-- Only if UI/visual output changed -->

## Notes for reviewers

<!-- Anything worth calling out: platform specifics, breaking changes, side effects -->