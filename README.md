# ai-attribution-check

Enforce a commit-attribution policy for AI tools, as a GitHub Action and as a
[pre-commit](https://pre-commit.com) `commit-msg` hook. Both run the same script,
`check_ai_attribution.sh`.

The policy distinguishes *authorship* from *assistance*:

- An AI agent must **not** be the commit author.
- An AI agent must **not** appear in a *human-only* trailer (`Signed-off-by:`,
  `Co-authored-by:`, `Reviewed-by:`, ...). A human takes responsibility for a commit;
  a tool does not.
- An AI agent may appear in a *descriptive* trailer (`Generated-by:`, `Tested-by:`, ...)
  only if the same agent is also named in an `Assisted-by:` trailer.
- Any other trailer key (`Cc:`, `Link:`, `Foo-by:`) is treated as human-only.
- A generated-by footer in the message (`Generated with [Claude Code]`,
  `🤖 Generated`, `claude.ai/code`, ...) is an error unless the commit also has an
  `Assisted-by:` trailer.
- `Assisted-by: <tool>` is the sanctioned disclosure. It is reported as an
  informational message (`::notice` in Actions) and never fails the check.
- Allowlisted bots (below) have no requirements, as author or in any trailer.

Other tools flag every commit that mentions AI; this one lets contributors disclose
assistance honestly.

### Trailer classes

Keys are compared case-insensitively.

| Class | Keys | AI agent allowed? |
| --- | --- | --- |
| Human-only | `Signed-off-by`, `Co-authored-by`, `Co-developed-by`, `Acked-by`, `Approved-by`, `Authorized-by`, `Reviewed-by` | Never, even if named in `Assisted-by` |
| Descriptive | `Generated-by`, `Tested-by`, `Reported-by`, `Suggested-by`, `Debugged-by`, `Analyzed-by`, `Found-by`, `Helped-by`, `Proposed-by` | Only if named in `Assisted-by` |
| Other | any unlisted key | Never |
| `Assisted-by` | | The disclosure itself; its value is not checked |

`--extra-descriptive-trailers` and `--extra-human-only-trailers` (comma-separated)
extend the lists. A key in both is human-only.

### When is an agent "named in `Assisted-by`"?

Both sides are reduced to an *agent key*: the name up to the first `:`, `<`, `(` or
`[`, trimmed and lowercased. Two keys match if they are equal, or if one is a prefix
of the other ending at a word boundary (a space or `-`). The `Assisted-by` value can
use the `Tool:model` format (`Assisted-by: Copilot:gpt-4o`), so no email is needed.

| Trailer | `Assisted-by:` | Match? |
| --- | --- | --- |
| `Generated-by: Claude <noreply@anthropic.com>` | `Claude:claude-sonnet-5-5` | yes |
| `Generated-by: Claude Sonnet 5.5` | `Claude` | yes (prefix at a space) |
| `Tested-by: copilot-swe-agent[bot] <...>` | `Copilot:gpt-4o` | yes (prefix at a `-`) |
| `Suggested-by: Some Agent <x@agentmail.to>` | `Some Agent:v1` or `Some` | yes |
| `Suggested-by: Some Agent <x@agentmail.to>` | `Agent:v1` | no (not a leading prefix) |
| `Suggested-by: Some Agent <x@agentmail.to>` | `Somebody` | no (not a word boundary) |
| `Generated-by: <x@agentmail.to>` | anything | no (no name to match) |

So an AI identity whose name contains a space needs an `Assisted-by` that starts with
the same words.

## What counts as an AI agent

An identity is the string `Name <email>`:

- Its name or email contains a known agent marker: `noreply@anthropic.com`,
  `noreply@openai.com`, `copilot@github.com`, `+copilot@users.noreply.github.com`,
  `cursoragent@cursor.com`, `@devin.ai`, `devin-ai-integration`, `google-labs-jules`,
  `noreply@aider.chat`, `@agentmail.to`, `(aider)`, `[aider]`.
- Or it has **no email** (an empty `<>` counts as none) and its name is a bare agent
  name, optionally with a vendor prefix, version or model words, or a parenthesised note
  (`Claude`, `GitHub Copilot`, `Claude 3.5 Sonnet`, `Gemini 2.5 Pro`, `ChatGPT 4o`,
  `Claude (AI)`, `@copilot`, `claude-code`, `OpenAI Codex`, `Cursor Agent`, `GPT-5`,
  `aider`). Names are never matched when an email is present, and a trailing human
  name does not match, so `Claude Martin <claude.martin@example.org>` and `Devin Smith`
  pass.
- Or it contains `[bot]` and is not on the allowlist (`dependabot[bot]`,
  `pre-commit-ci[bot]`, matched on their GitHub noreply addresses, and Dependabot's
  `support@github.com` sign-off). The whole `Name <email>` must match, since a name
  alone is free text. Extend the allowlist for other non-AI automation.

Trailers are those git recognises (`git interpret-trailers`): the last paragraph of
the message. A `Co-authored-by:` line followed by another paragraph is not a trailer
and is not checked.

### How the commit-msg hook reads the message

The range check (the Action, or the `pre-push` hook) reads each commit as stored and is
authoritative. The `commit-msg` hook runs earlier, before git has cleaned the message
up, so it *predicts* what will be stored with one best guess and then applies exactly
the same checks. It has no allowances, so a message it accepts is one the range check
accepts, as long as the guess is right.

The guess follows what git does, which depends on whether an editor ran and on
`commit.cleanup`:

- The editor template always has a line that is just the comment string (`#`), so a
  file with one is an editor commit. Git cuts it at the scissors line (`commit -v`
  adds one, with the diff below it; `commit.cleanup=scissors` cuts there too). A file
  without one comes from `-m`/`-F`, where git cuts nothing, whatever the mode.
- Comment lines: `commit.cleanup=strip` removes them; `whitespace` and `scissors` keep
  them; `verbatim` leaves the message alone and is never cut (git cuts a verbatim
  message only for `commit -v`, which the file can't be told from a typed scissors
  line, so a `commit -v` diff counts). By default an editor commit strips them
  and `-m`/`-F` keeps them.
- The comment string is `core.commentString` (or `core.commentChar`); `auto` means `#`.

Git's trailer parser ignores a trailing comment block and everything from a scissors
line on, so those never hide or add trailers.

The guess can be wrong, for example with `commit.status=false` or a custom template
without a bare comment line. Use the `pre-push` hook for an exact check, or let the CI
run catch it.

Trailers are checked in merge commits too (as is the author); only the generated-by
footer check is skipped for them, since git generates the message.

Known gap: an agent that uses a non-standard email and a name that is neither bare nor
a `[bot]` account is not caught. Patterns are deliberately narrow so that humans are
not rejected; add markers with the options below, and send a PR for new agents.

## GitHub Action

```yaml
name: AI attribution
on:
  pull_request:
    types: [opened, synchronize, reopened, edited]  # 'edited' covers retargeting

jobs:
  check:
    # Title/body edits don't change the commit range; a base change does.
    if: github.event.action != 'edited' || github.event.changes.base
    runs-on: ubuntu-latest
    permissions:
      contents: read
    steps:
    - uses: actions/checkout@v7
      with:
        ref: ${{ github.event.pull_request.head.sha }}
        fetch-depth: 0   # the commit range must be available
        persist-credentials: false
    - uses: kc9jud/ai-attribution-check@v0  # pin a commit SHA in real use
```

Inputs:

| Input | Default | Description |
| --- | --- | --- |
| `base-sha` | PR base SHA | Start of the range (exclusive). Required outside `pull_request` events. |
| `head-sha` | PR head SHA | End of the range (inclusive). |
| `extra-ai-identity-regex` | none | Extended regex; matching name/email is treated as an AI agent. |
| `extra-bot-allowlist` | none | Extended regex matched against `Name <email>`; allows extra `[bot]` identities. |
| `extra-descriptive-trailers` | none | Comma-separated keys (`Foo-by, Bar-by`) that may name an AI agent if disclosed in `Assisted-by`. |
| `extra-human-only-trailers` | none | Comma-separated keys that may never name an AI agent. |
| `policy-url` | none | Link printed after a violation. |

Merge commits are checked for author and trailers; the generated-by footer is skipped.

## pre-commit hooks

Two hooks, which can be used together:

- `ai-attribution` (`commit-msg`) checks the commit being created, so an agent gets
  feedback *before* it commits itself as a co-author. It predicts the stored message
  (see above). The author is read from `git var GIT_AUTHOR_IDENT`.
- `ai-attribution-range` (`pre-push`) runs the exact range check on the commits being
  pushed (those not already on a remote, for a new branch). pre-commit hands a hook
  only the first updated ref, and none for an initial push, where it checks the
  commits of the pushed branch (`HEAD` if pre-commit doesn't name it) that no remote
  has. A push of several branches at once is not
  fully covered; for that, use a native hook (below) or rely on the Action.

In `.pre-commit-config.yaml`:

```yaml
default_install_hook_types: [pre-commit, commit-msg, pre-push]  # plain `pre-commit install` sets up all

repos:
  - repo: https://github.com/kc9jud/ai-attribution-check
    rev: v0.1.0  # pin a commit SHA in real use
    hooks:
    - id: ai-attribution
      # args: [--extra-ai-identity-regex, 'acme-agent', --policy-url, 'https://example.org/policy']
    - id: ai-attribution-range  # same args as above if you set any
```

Without `default_install_hook_types`, run
`pre-commit install --hook-type commit-msg --hook-type pre-push`.

### Native pre-push hook

Git's own hook input lists every updated ref, so a native `.git/hooks/pre-push`
(executable) checks them all:

```sh
#!/bin/sh
exec /path/to/check_ai_attribution.sh --pre-push-stdin
```

## Command line

```
check_ai_attribution.sh [options] <base>..<head>
check_ai_attribution.sh --commit-msg [options] FILE
check_ai_attribution.sh --pre-push [options]       # PRE_COMMIT_FROM_REF / PRE_COMMIT_TO_REF if set
check_ai_attribution.sh --pre-push-stdin [options] # git's pre-push input on stdin
```

Options: `--extra-ai-identity-regex REGEX`, `--extra-bot-allowlist REGEX`,
`--extra-descriptive-trailers LIST` and `--extra-human-only-trailers LIST`
(comma- or newline-separated; each key is letters, digits and `-`; the singular
`--extra-descriptive-trailer KEY` and `--extra-human-only-trailer KEY` can be repeated),
`--policy-url URL`. Exit status: `0` compliant, `1` violation, `2` usage or tool error
(including an invalid regex).

Requires `bash` (3.2 or newer, so macOS works) and `git`.

## Development

```
tests/test.sh                                   # needs only bash and git
shellcheck check_ai_attribution.sh tests/test.sh
```

CI runs both on Ubuntu and macOS.
