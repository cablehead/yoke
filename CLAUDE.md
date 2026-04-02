## Git Commit Style Preferences

**NEVER commit unless explicitly asked by the user.**

When committing: review `git diff`

- Use conventional commit format: `type: subject line`
- Keep subject line concise and descriptive
- **NEVER include marketing language, promotional text, or AI attribution**
- **NEVER add "Generated with Claude Code", "Co-Authored-By: Claude", or similar spam**
- Follow existing project patterns from git log
- Prefer just a subject and no body, unless the change is particularly complex

## Tone and Communication

- ASCII only. No em dashes, smart quotes, or other unicode punctuation. Use "--" only in code contexts, not as prose punctuation.
- No wasted words. No fluff. Each word should add value to the reader.
- Human readable and clear.
- Calm, matter-of-fact technical tone.

## Code Quality

Always run `cargo fmt` and `cargo clippy --all-targets` before committing.
