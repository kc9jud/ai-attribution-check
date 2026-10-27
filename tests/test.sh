#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
# SPDX-FileCopyrightText: Copyright Contributors to the Kokkos project
#
# Tests for check_ai_attribution.sh. Builds throwaway git repos; needs only
# bash and git. Written for Bash 3.2 (macOS) as well as newer versions.
#
# Usage: tests/test.sh

set -u

# The user's and system git config must not leak into the throwaway repos.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
# Nor may the refs of an enclosing pre-commit/prek pre-push run (this suite is
# one of this repository's own pre-push hooks).
unset PRE_COMMIT_FROM_REF PRE_COMMIT_TO_REF PRE_COMMIT_LOCAL_BRANCH PRE_COMMIT_REMOTE_NAME PRE_COMMIT_REMOTE_URL

REAL_SCRIPT=$(cd "$(dirname "$0")/.." && pwd)/check_ai_attribution.sh
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
MSG=$WORK/msg
# Run the script with the interpreter running this test (CI passes /bin/bash,
# which is Bash 3.2 on macOS), not whatever "env bash" finds first.
SCRIPT=$WORK/script
printf '#!/bin/sh\nexec "%s" "%s" "$@"\n' "$BASH" "$REAL_SCRIPT" > "$SCRIPT"
chmod +x "$SCRIPT"

cd "$WORK" && git init -q repo && cd repo || exit 2
git config user.name "Pat F"
git config user.email p@n.com
git config commit.gpgsign false
git commit -q --allow-empty -m base
BASE=$(git rev-parse HEAD)

pass=0
fail=0

# t NAME WANT_RC OUTPUT_FRAGMENT CMD...   (empty fragment = don't check output)
t() {
  local name=$1 want=$2 frag=$3 out rc
  shift 3
  out=$("$@" 2>&1)
  rc=$?
  if [ "$rc" -eq "$want" ] && { [ -z "$frag" ] || grep -qF -- "$frag" <<< "$out"; }; then
    pass=$((pass + 1))
    echo "ok   $name"
  else
    fail=$((fail + 1))
    echo "FAIL $name (rc=$rc want=$want fragment='$frag')"
    # shellcheck disable=SC2001
    sed 's/^/     /' <<< "$out"
  fi
}

# tn NAME CMD...: succeeds if CMD's output does NOT contain the annotation
# fragment given in $NOT (used for "no GitHub annotation outside Actions").
tn() {
  local name=$1 out
  shift
  out=$("$@" 2>&1)
  if grep -qF -- "$NOT" <<< "$out"; then
    fail=$((fail + 1)); echo "FAIL $name (found '$NOT')"
  else
    pass=$((pass + 1)); echo "ok   $name"
  fi
}

reset() { git reset -q --hard "$BASE"; }
# c [--author=X] MESSAGE: commit with the given message
c() {
  local author=""
  case "$1" in --author=*) author=$1; shift ;; esac
  if [ -n "$author" ]; then
    git commit -q --allow-empty "$author" -m "$1"
  else
    git commit -q --allow-empty -m "$1"
  fi
}
range() { "$SCRIPT" "$@" "$BASE..HEAD"; }
msgfile() { printf '%b' "$1" > "$MSG"; }

# --- range mode: basics ------------------------------------------------------
reset; t empty-range 0 "No commits to check" range
reset; c plain; t human-ok 0 "✅" range

reset; c $'x\n\nAssisted-by: Claude Sonnet 5.5 <noreply@anthropic.com>'
t assisted-by-info 0 "discloses AI assistance" range
export GITHUB_ACTIONS=true
t assisted-by-notice-annotation 0 "::notice title=AI assistance disclosed" range
unset GITHUB_ACTIONS
NOT="::notice" tn no-annotation-outside-actions range

reset; c $'x\n\nAssisted-by: Jane Doe'
t assisted-by-any-value-info 0 "discloses" range

# --- range mode: trailers ----------------------------------------------------
reset; c $'x\n\nCo-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>'
t coauthor-claude-fails 1 "Co-Authored-By" range
GITHUB_ACTIONS=true t error-annotation 1 "::error title=AI tool policy" range
NOT="::error" tn no-error-annotation-outside-actions range
reset; c $'x\n\nSigned-off-by: Copilot'; t signoff-bare-copilot 1 "cannot sign off" range
reset; c $'x\n\nSigned-Off-By: Claude <noreply@anthropic.com>'; t signoff-mixed-case-key 1 "cannot sign off" range
reset; c $'x\n\nCO-AUTHORED-BY: Claude <noreply@anthropic.com>'; t upper-case-key 1 "'CO-AUTHORED-BY:'" range
reset; c $'x\n\nASSISTED-BY: Claude Sonnet 5.5'; t upper-case-assisted-by 0 "discloses" range
reset; c $'x\n\nCo-authored-by: Anna <a@b.c>\nco-authored-by: Claude Sonnet 5.5'; t second-trailer-checked 1 "Offending line: co-authored-by: Claude Sonnet 5.5" range

# Any trailer key except Assisted-by is checked.
reset; c $'x\n\nReviewed-by: Claude <noreply@anthropic.com>'; t reviewed-by-ai-fails 1 "'Reviewed-by:'" range
reset; c $'x\n\nGenerated-by: Claude <noreply@anthropic.com>'; t generated-by-ai-undisclosed-fails 1 "not disclosed in an 'Assisted-by:' trailer" range
reset; c $'x\n\nAuthorized-by: Copilot'; t authorized-by-ai-fails 1 "'Authorized-by:'" range
reset; c $'x\n\nReviewed-by: Ada Lovelace <ada@example.org>'; t reviewed-by-human-ok 0 "✅" range

# --- range mode: identities --------------------------------------------------
reset; c --author="Claude <noreply@anthropic.com>" x; t author-claude-email 1 "author of a commit" range
reset; c --author="Copilot <198982749+Copilot@users.noreply.github.com>" x; t author-copilot-noreply 1 "author of a commit" range
reset; c --author="Codex <noreply@openai.com>" x; t author-openai-email 1 "author of a commit" range
reset; c --author="Some Agent <inbox42@agentmail.to>" x; t author-agentmail 1 "author of a commit" range
reset; c $'x\n\nCo-authored-by: Any Name <whatever@agentmail.to>'; t coauthor-agentmail 1 "Co-authored-by" range
reset; c --author="Ann <ann@agentmail.to.example.org>" x; t agentmail-longer-domain-ok 0 "✅" range
reset; c --author="Ann <ann@notagentmail.com>" x; t agentmail-unrelated-domain-ok 0 "✅" range
reset; c --author="Cursor Agent <cursoragent@cursor.com>" x; t author-cursor-agent 1 "author of a commit" range
reset; c --author="Dana Dev <dana@cursor.com>" x; t human-at-cursor-ok 0 "✅" range
reset; c --author="Devin <devin@devin.ai>" x; t author-devin-email 1 "author of a commit" range
reset; c --author="devin-ai-integration[bot] <158243242+devin-ai-integration[bot]@users.noreply.github.com>" x; t author-devin-bot 1 "author of a commit" range
reset; c --author="google-labs-jules[bot] <161369871+google-labs-jules[bot]@users.noreply.github.com>" x; t author-jules-bot 1 "author of a commit" range
reset; c --author="google-labs-jules <a@example.org>" x; t author-jules-marker-without-bot-suffix 1 "author of a commit" range
reset; c --author="devin-ai-integration <a@example.org>" x; t author-devin-marker-without-bot-suffix 1 "author of a commit" range
reset; c --author="Pat Fasano (aider) <pat@example.org>" x; t author-aider-suffix 1 "author of a commit" range
reset; c $'x\n\nCo-authored-by: aider (gpt-4o) <noreply@aider.chat>'; t coauthor-aider-email 1 "Co-authored-by" range
reset; c $'x\n\nCo-authored-by: GPT-5'; t coauthor-bare-gpt 1 "Co-authored-by" range
reset; c $'x\n\nCo-authored-by: Jules'; t bare-jules-ok 0 "✅" range

# --- range mode: bots --------------------------------------------------------
reset; c --author="dependabot[bot] <49699333+dependabot[bot]@users.noreply.github.com>" $'build(deps): bump\n\nSigned-off-by: dependabot[bot] <support@github.com>'
t dependabot-ok 0 "✅" range
reset; c --author="pre-commit-ci[bot] <66853113+pre-commit-ci[bot]@users.noreply.github.com>" x; t precommit-ci-ok 0 "✅" range
reset; c --author="Dependabot[bot] <support@github.com>" $'x\n\nCo-authored-by: Dependabot[bot] <support@github.com>'; t allowlist-case-insensitive-ok 0 "✅" range
reset; c --author="renovate[bot] <a@b.c>" x; t unlisted-bot-author-fails 1 "author of a commit" range
reset; c $'x\n\nCo-authored-by: renovate[bot] <a@b.c>'; t unlisted-bot-coauthor-fails 1 "Co-authored-by" range
reset; c --author="dependabot[bot] <support@github.com>" $'x\n\nCo-authored-by: renovate[bot] <a@b.c>'; t allowed-author-unlisted-trailer-fails 1 "Co-authored-by" range
reset; c --author="my-dependabot[bot] <a@b.c>" x; t allowlist-is-anchored 1 "author of a commit" range
reset; c --author="claude[bot] <209825114+claude[bot]@users.noreply.github.com>" x; t author-claude-app 1 "author of a commit" range
reset; c --author="copilot-swe-agent[bot] <198982749+Copilot@users.noreply.github.com>" x; t author-copilot-agent 1 "author of a commit" range

# --- range mode: humans must pass ---------------------------------------------
reset; c --author="Jim Talbot <1+jt@users.noreply.github.com>" $'x\n\nCo-authored-by: Abbott Github <ab@github.example>\nSigned-off-by: Jim Talbot <jt@x.com>'
t no-substring-false-positives 0 "✅" range
reset; c --author="Claude Martin <claude.martin@example.org>" $'x\n\nCo-authored-by: Devin Smith <devin.smith@example.org>\nSigned-off-by: Gemini Jones <gj@example.org>'
t human-agent-firstnames-ok 0 "✅" range
reset; c --author="Claude <claude@humansonly.com>" $'x\n\nCo-authored-by: Claude <claude@humansonly.com>'; t claude-with-human-email-ok 0 "✅" range
reset; c $'x\n\nCo-authored-by: Claude Martin'; t bare-human-fullname-ok 0 "✅" range
reset; c $'x\n\nCo-authored-by: Devin Smith'; t bare-human-devin-ok 0 "✅" range
reset; c $'x\n\nCo-authored-by: Claude is just prose here'; t trailer-like-prose-ok 0 "" range

# --- range mode: bare agent names ----------------------------------------------
reset; c $'x\n\nCo-authored-by: Claude Sonnet 5.5'; t bare-claude-model 1 "Co-authored-by" range
reset; c $'x\n\nCo-authored-by: Claude'; t bare-claude 1 "Co-authored-by" range
reset; c $'x\n\nCo-authored-by: Copilot'; t bare-copilot 1 "Co-authored-by" range
reset; c $'x\n\nCo-authored-by: Codex 5'; t bare-versioned 1 "Co-authored-by" range

# --- range mode: generated-by footers ------------------------------------------
reset; c $'Fix thing\n\n🤖 Generated with [Claude Code](https://claude.com/claude-code)'
t footer-without-trailer-fails 1 "Generated-by footer" range
reset; c $'Fix thing\n\n🤖 Generated with [Claude Code](https://claude.com/claude-code)\n\nAssisted-by: Claude Sonnet 5.5'
t footer-with-assisted-by-ok 0 "discloses" range
reset; c $'Fix thing\n\nGenerated with Cursor'; t cursor-footer-fails 1 "Generated-by footer" range
reset; c $'Fix thing\n\nSee https://claude.ai/code/session_123'; t claude-ai-code-link-fails 1 "Generated-by footer" range
reset; c $'Add Claude API integration\n\nImplements support for the Claude Messages endpoint.'; t prose-mention-ok 0 "✅" range

# --- range mode: structure -------------------------------------------------------
reset; c one; c $'two\n\nCo-authored-by: Claude <noreply@anthropic.com>'; c three
t violation-in-middle-commit 1 "Co-authored-by" range
reset; git checkout -q -b side; c --author="Claude <noreply@anthropic.com>" side
git checkout -q -; git merge -q --no-ff side -m merge 2> /dev/null
t merge-skipped-side-checked 1 "author of a commit" range
git branch -q -D side 2> /dev/null; reset

# --- descriptive trailers need a matching Assisted-by ---------------------------------
CLAUDE_ID='Claude <noreply@anthropic.com>'
for k in Generated-by Tested-by Reported-by Suggested-by Debugged-by Analyzed-by Found-by Helped-by Proposed-by; do
  reset; c "x

$k: $CLAUDE_ID
Assisted-by: Claude:claude-sonnet-5-5"
  t "descriptive-$k-disclosed-ok" 0 "covered by Assisted-by" range
  reset; c "x

$k: $CLAUDE_ID"
  t "descriptive-$k-undisclosed-fails" 1 "not disclosed in an 'Assisted-by:' trailer" range
done
reset; c $'x\n\nAssisted-by: Claude:claude-sonnet-5-5\nGenerated-by: Claude <noreply@anthropic.com>'
t descriptive-assisted-by-first-ok 0 "covered by Assisted-by" range
reset; c $'x\n\ngenerated-by: Claude <noreply@anthropic.com>\nASSISTED-BY: Claude'
t descriptive-mixed-case-keys-ok 0 "covered by Assisted-by" range
reset; c $'x\n\nGenerated-by: Claude <noreply@anthropic.com>\nAssisted-by: Copilot:gpt-4o'
t descriptive-other-agent-disclosed-fails 1 "not disclosed" range
reset; c $'x\n\nGenerated-by: Claude <noreply@anthropic.com>\nTested-by: Copilot\nAssisted-by: Claude:x'
t only-one-of-two-agents-disclosed 1 "'Tested-by:'" range

# Matching: the agent name must be a leading, word-boundary prefix (or equal).
reset; c $'x\n\nGenerated-by: Claude Sonnet 5.5\nAssisted-by: Claude'
t match-prefix-of-long-name 0 "covered" range
reset; c $'x\n\nGenerated-by: Claude Sonnet 5.5\nAssisted-by: Claude Sonnet 5.5:xyz'
t match-equal-long-name 0 "covered" range
reset; c $'x\n\nGenerated-by: copilot-swe-agent[bot] <198982749+Copilot@users.noreply.github.com>\nAssisted-by: Copilot:gpt-4o'
t match-hyphen-boundary 0 "covered" range
reset; c $'x\n\nSuggested-by: Some Agent <x@agentmail.to>\nAssisted-by: Some Agent:v1'
t multiword-same-words 0 "covered" range
reset; c $'x\n\nSuggested-by: Some Agent <x@agentmail.to>\nAssisted-by: Some'
t multiword-leading-prefix 0 "covered" range
reset; c $'x\n\nSuggested-by: Some Agent <x@agentmail.to>\nAssisted-by: Agent:v1'
t multiword-trailing-word-only-fails 1 "not disclosed" range
reset; c $'x\n\nSuggested-by: Some Agent <x@agentmail.to>\nAssisted-by: Somebody'
t multiword-not-word-boundary-fails 1 "not disclosed" range
reset; c $'x\n\nSuggested-by: Some Agent <x@agentmail.to>'
t multiword-no-assisted-by-fails 1 "starts with 'some agent'" range
reset; c $'x\n\nGenerated-by: <x@agentmail.to>\nAssisted-by: Claude'
t nameless-identity-never-matches 1 "<tool name>" range
# A bare address has no tool name, but a handle ("@copilot") does.
reset; c $'x\n\nGenerated-by: someone@agentmail.to\nAssisted-by: someone@agentmail.to'
t bare-address-never-matches 1 "<tool name>" range
reset; c $'x\n\nGenerated-by: @copilot\nAssisted-by: @copilot'
t handle-disclosed-ok 0 "covered by Assisted-by" range
reset; c $'x\n\nGenerated-by: @copilot\nAssisted-by: Copilot:gpt-4o'
t handle-disclosed-by-tool-name-ok 0 "covered by Assisted-by" range
reset; c $'x\n\nGenerated-by: Copilot\nAssisted-by: @copilot'
t tool-name-disclosed-by-handle-ok 0 "covered by Assisted-by" range
reset; c $'x\n\nGenerated-by: @copilot'
t handle-undisclosed-fails 1 "starts with 'copilot'" range

# Human-only trailers reject an AI even when it is disclosed in Assisted-by.
for k in Signed-off-by Co-authored-by Co-developed-by Acked-by Approved-by Authorized-by Reviewed-by; do
  reset; c "x

$k: $CLAUDE_ID
Assisted-by: Claude:claude-sonnet-5-5"
  t "human-only-$k-ai-fails-even-if-disclosed" 1 "$k" range
  reset; c "x

$k: Ada Lovelace <ada@example.org>"
  t "human-only-$k-human-ok" 0 "✅" range
done
reset; c $'x\n\nCc: Claude <noreply@anthropic.com>\nAssisted-by: Claude'
t unlisted-key-fails-closed 1 "human-only" range
reset; c $'x\n\nCc: Ada Lovelace <ada@example.org>'
t unlisted-key-human-ok 0 "✅" range

# Allowlisted bots: no requirements, with or without Assisted-by.
for bot in "dependabot[bot] <support@github.com>" "pre-commit-ci[bot] <66853113+pre-commit-ci[bot]@users.noreply.github.com>"; do
  for k in Signed-off-by Co-authored-by Reviewed-by Generated-by Tested-by Cc; do
    reset; c --author="$bot" "x

$k: $bot"
    t "allowlisted-bot-${bot%%\[*}-$k-no-requirements" 0 "✅" range
  done
done
reset; c $'x\n\nGenerated-by: renovate[bot] <a@b.c>'
t unlisted-bot-descriptive-undisclosed-fails 1 "not disclosed" range
reset; c $'x\n\nGenerated-by: renovate[bot] <a@b.c>\nAssisted-by: renovate'
t unlisted-bot-descriptive-disclosed-ok 0 "covered" range
reset; c --author="renovate[bot] <a@b.c>" $'x\n\nGenerated-by: renovate[bot] <a@b.c>'
t extra-allowlist-needed-for-bot 1 "author of a commit" range
t extra-allowlist-bot-needs-no-assisted-by 0 "✅" range --extra-bot-allowlist '^renovate\[bot\] <'

# Trailer-list options.
reset; c $'x\n\nFoo-by: Claude <noreply@anthropic.com>\nAssisted-by: Claude'
t extra-descriptive-trailer-default-fails 1 "human-only" range
t extra-descriptive-trailer 0 "covered" range --extra-descriptive-trailer Foo-by
t extra-descriptive-trailer-case-insensitive 0 "covered" range --extra-descriptive-trailer FOO-BY
reset; c $'x\n\nTested-by: Claude <noreply@anthropic.com>\nAssisted-by: Claude'
t tested-by-default-ok 0 "covered" range
t extra-human-only-trailer 1 "human-only" range --extra-human-only-trailer Tested-by
reset; c $'x\n\nReviewed-by: Claude <noreply@anthropic.com>\nAssisted-by: Claude'
t human-only-wins-over-descriptive 1 "human-only" range --extra-descriptive-trailer Reviewed-by
t invalid-trailer-key-space 2 "invalid trailer key" range --extra-descriptive-trailer 'a b'
t invalid-trailer-key-empty 2 "invalid trailer key" range --extra-human-only-trailer ''
t invalid-trailer-key-colon 2 "invalid trailer key" range --extra-descriptive-trailer 'Foo:'

# Empty / match-everything regexes are usage errors, not silent catch-alls.
reset; c plain
t empty-ai-regex 2 "matches the empty string" range --extra-ai-identity-regex ''
# BSD grep (macOS) calls "foo|" invalid instead of empty-matching; both are rejected.
t trailing-alt-ai-regex 2 "regular expression for --extra-ai-identity-regex" range --extra-ai-identity-regex 'foo|'
t empty-allowlist-regex 2 "matches the empty string" range --extra-bot-allowlist ''
t star-allowlist-regex 2 "matches the empty string" range --extra-bot-allowlist 'x*'

# The bot allowlist is anchored on the email too: the name alone is free text.
reset; c --author="dependabot[bot] <evil@example.org>" x
t spoofed-dependabot-author-fails 1 "author of a commit" range
reset; c $'x\n\nSigned-off-by: dependabot[bot] <evil@example.org>'
t spoofed-dependabot-trailer-fails 1 "Signed-off-by" range
reset; c --author="pre-commit-ci[bot] <evil@example.org>" x
t spoofed-precommit-ci-author-fails 1 "author of a commit" range

# Email-only AI identities have no name to match: say how to fix it.
reset; c $'x\n\nReported-by: <noreply@anthropic.com>\nAssisted-by: Claude'
t email-only-angle-fails-with-hint 1 "Name the tool in the trailer value" range
reset; c $'x\n\nReported-by: noreply@anthropic.com\nAssisted-by: Claude'
t email-only-bare-fails-with-hint 1 "Name the tool in the trailer value" range

# --- an "email" without an address is no email ---------------------------------------
reset; c --author="Claude <>" x; t author-empty-email-fails 1 "author of a commit" range
reset; c --author="Claude <nobody>" x; t author-addressless-email-fails 1 "author of a commit" range
reset; c $'x\n\nCo-authored-by: Claude Sonnet 5.5 <>'; t coauthor-empty-email-fails 1 "Co-authored-by" range
reset; c $'x\n\nSigned-off-by: Copilot <not an email>'; t signoff-garbage-email-fails 1 "cannot sign off" range
reset; c --author="Ada Lovelace <>" x; t human-empty-email-ok 0 "✅" range
reset; c --author="Claude Martin <>" x; t human-claude-empty-email-ok 0 "✅" range

# --- bare agent names ---------------------------------------------------------------
for name in 'GitHub Copilot' 'Claude 3.5 Sonnet' 'Gemini 2.5 Pro' 'ChatGPT 4o' 'Claude (AI)' 'Claude.' \
            '@copilot' 'claude-code' 'OpenAI Codex' 'Cursor Agent' 'Google Gemini' 'Claude Opus 4.5' \
            ChatGPT Gemini Cursor Devin Aider Codex Copilot 'GPT-4o mini' 'Anthropic Claude'; do
  reset; c $'x\n\nSigned-off-by: '"$name"
  t "bare-name-agent[$name]" 1 "cannot sign off" range
done
for name in 'Claude Martin' 'Devin Smith' 'Gemini Rossi' 'Aider Ahmed' 'Cursor Smith' 'Copilot Jones' \
            'Codex Hernandez' 'Google Smith' 'Anthropic Smith' 'Claude Debussy' 'Github Smith'; do
  reset; c $'x\n\nCo-authored-by: '"$name"
  t "bare-name-human[$name]" 0 "✅" range
done
# A name is only matched when there is no email; a real address means a person.
reset; c $'x\n\nCo-authored-by: Claude 3.5 Sonnet <someone@humansonly.com>'; t named-agent-with-human-email-ok 0 "✅" range

# --- patterns that were never exercised -------------------------------------------------
reset; c --author="Copilot <copilot@github.com>" x; t author-copilot-github-email 1 "author of a commit" range
reset; c --author="Pat Fasano [aider] <pat@example.org>" x; t author-aider-bracket 1 "author of a commit" range
reset; c --author="Ann <ann@devin.ai>" x; t author-devin-ai-domain 1 "author of a commit" range
reset; c --author="Ann <ann@devin.ai.example.org>" x; t devin-ai-longer-domain-ok 0 "✅" range
reset; c --author="Ann <ann@notdevin.ai>" x; t devin-ai-prefix-domain-ok 0 "✅" range
reset; c $'x\n\nGenerated with Copilot'; t copilot-footer-fails 1 "Generated-by footer" range
reset; c $'x\n\n🤖 Generated'; t robot-generated-footer-fails 1 "Generated-by footer" range
reset; c $'x\n\nSee https://claude.com/claude-code for details'; t claude-code-link-footer-fails 1 "Generated-by footer" range
reset; c $'x\n\nGenerated-by: Claude <noreply@anthropic.com>\nAssisted-by: Claude Sonnet 5.5'
t assisted-by-longer-than-trailer-ok 0 "covered by Assisted-by" range
reset; c $'x\n\nGenerated-by: Claude <noreply@anthropic.com>\nAssisted-by: Claude (Sonnet 5.5)'
t assisted-by-parenthesis-ok 0 "covered by Assisted-by" range
reset; c $'x\n\nGenerated-by: Claude <noreply@anthropic.com>\nAssisted-by: Claude'
t assisted-by-notice-printed-once 0 "discloses AI assistance: Assisted-by: Claude" range
out=$("$SCRIPT" "$BASE..HEAD" 2>&1); n=$(grep -c 'discloses AI assistance' <<< "$out")
if [ "$n" -eq 1 ]; then pass=$((pass + 1)); echo "ok   assisted-by-single-notice"; else fail=$((fail + 1)); echo "FAIL assisted-by-single-notice (n=$n)"; fi

# --- an Assisted-by with no value discloses nothing --------------------------------------
reset; c $'x\n\n🤖 Generated with Claude Code\n\nAssisted-by:'; t empty-assisted-by-footer-fails 1 "Generated-by footer" range
reset; c $'x\n\n🤖 Generated with Claude Code\n\nAssisted-by:   '; t blank-assisted-by-footer-fails 1 "Generated-by footer" range
reset; c $'x\n\nGenerated-by: Claude <noreply@anthropic.com>\nAssisted-by:'; t empty-assisted-by-descriptive-fails 1 "not disclosed" range

# --- merge commits: author and trailers are checked, footers are not ----------------------
reset; git checkout -q -b side; c side; git checkout -q -
git merge -q --no-ff side -m merge 2> /dev/null
git -c core.hooksPath=/dev/null commit -q --amend --author="Claude <noreply@anthropic.com>" -m $'Merge branch side\n\nCo-authored-by: Claude <noreply@anthropic.com>'
t merge-ai-author-fails 1 "author of a commit" range
t merge-ai-trailer-fails 1 "Co-authored-by" range
git -c core.hooksPath=/dev/null commit -q --amend --author="Pat F <p@n.com>" -m $'Merge branch side\n\nGenerated with Claude Code'
t merge-footer-not-checked 0 "✅" range
git -c core.hooksPath=/dev/null commit -q --amend --author="Pat F <p@n.com>" -m $'Merge branch side\n\nSigned-off-by: Pat F <p@n.com>'
t merge-human-ok 0 "✅" range
git branch -q -D side 2> /dev/null; reset

# --- trailer lists given as one multi-line or comma-separated value (the Action) ----------
reset; c $'x\n\nFoo-by: Claude <noreply@anthropic.com>\nBar-by: Claude <noreply@anthropic.com>\nAssisted-by: Claude'
t descriptive-list-comma-space 0 "covered" range --extra-descriptive-trailers 'Foo-by, Bar-by'
t descriptive-list-newlines 0 "covered" range --extra-descriptive-trailers $'Foo-by\nBar-by\n'
t descriptive-list-trailing-comma 0 "covered" range --extra-descriptive-trailers 'Foo-by,Bar-by,'
t descriptive-list-empty-entries 0 "covered" range --extra-descriptive-trailers ',, Foo-by ,,Bar-by, ,'
t descriptive-list-one-missing-fails 1 "'Bar-by:'" range --extra-descriptive-trailers 'Foo-by'
t descriptive-list-empty-value 1 "human-only" range --extra-descriptive-trailers ''
t descriptive-list-inner-space 2 "invalid trailer key" range --extra-descriptive-trailers 'Foo by'
reset; c $'x\n\nTested-by: Claude <noreply@anthropic.com>\nAssisted-by: Claude'
t human-only-list-newlines 1 "'Tested-by:'" range --extra-human-only-trailers $'Foo-by,\nTested-by\n'
t human-only-list-inner-space 2 "invalid trailer key" range --extra-human-only-trailers 'Tested by'
t trailer-list-flag-needs-value 2 "usage" "$SCRIPT" "$BASE..HEAD" --extra-descriptive-trailers
# Regex values from a YAML block scalar end in a newline.
reset; c --author="Acme <acme-agent@example.org>" x
t regex-trailing-newline 1 "author of a commit" range --extra-ai-identity-regex $'acme-agent\n'
reset; c --author="renovate[bot] <a@b.c>" x
t allowlist-trailing-newline 0 "✅" range --extra-bot-allowlist $'^renovate\\[bot\\] <\n'

# --- options and usage -----------------------------------------------------------
reset; c --author="Acme <acme-agent@example.org>" x
t extra-identity-off-by-default 0 "✅" range
t extra-identity-regex 1 "author of a commit" range --extra-ai-identity-regex 'acme-agent'
reset; c --author="renovate[bot] <a@b.c>" x
t extra-bot-allowlist 0 "✅" range --extra-bot-allowlist '^renovate\[bot\] <'
reset; c $'x\n\nCo-authored-by: Claude <noreply@anthropic.com>'
t policy-url-printed 1 "See policy at https://example.org/p" range --policy-url https://example.org/p
NOT="See policy" tn policy-url-absent-by-default range
reset; c ok; NOT="See policy" tn policy-url-not-printed-when-ok range --policy-url https://example.org/p
t invalid-regex 2 "invalid regular expression" range --extra-ai-identity-regex '('
t invalid-allowlist-regex 2 "invalid regular expression" range --extra-bot-allowlist '['
t flag-missing-value 2 "usage" "$SCRIPT" "$BASE..HEAD" --extra-bot-allowlist
t unknown-flag 2 "usage" "$SCRIPT" --nope "$BASE..HEAD"
t no-args 2 "usage" "$SCRIPT"
t two-targets 2 "usage" "$SCRIPT" "$BASE..HEAD" "$BASE..HEAD"
t bad-range 2 "unknown revision" "$SCRIPT" nonexistent..HEAD
t commit-msg-missing-file-arg 2 "usage" "$SCRIPT" --commit-msg

# --- commit-msg mode ---------------------------------------------------------------
msgfile 'fix\n\nAssisted-by: Claude <noreply@anthropic.com>\n'
t cm-assisted-ok 0 "discloses" "$SCRIPT" --commit-msg "$MSG"
msgfile 'fix\n\nCo-authored-by: Claude <noreply@anthropic.com>\n'
t cm-coauthor-fails 1 "Co-authored-by" "$SCRIPT" --commit-msg "$MSG"
msgfile 'fix\n\nSigned-off-by: Pat F <p@n.com>\n# Co-authored-by: Claude <noreply@anthropic.com>\n'
t cm-comment-lines-ignored 0 "✅" "$SCRIPT" --commit-msg "$MSG"
msgfile 'fix\n\n🤖 Generated with [Claude Code](https://claude.com/claude-code)\n'
t cm-footer-fails 1 "Generated-by footer" "$SCRIPT" --commit-msg "$MSG"
msgfile 'fix\n\nGenerated-by: Claude <noreply@anthropic.com>\nAssisted-by: Claude:claude-sonnet-5-5\n'
t cm-descriptive-disclosed-ok 0 "covered by Assisted-by" "$SCRIPT" --commit-msg "$MSG"
msgfile 'fix\n\nGenerated-by: Claude <noreply@anthropic.com>\n'
t cm-descriptive-undisclosed-fails 1 "not disclosed" "$SCRIPT" --commit-msg "$MSG"
# The hook predicts what the Action will see in the stored message, so it applies
# git's own cleanup. Which cleanup git applies depends on how the commit was made,
# and the file only shows that through the editor template, which always contains
# a line that is just the comment string: with an editor, git strips comment lines
# (and `commit -v` cuts at the scissors line); with `commit -m/-F` git keeps them.
GITBLOCK='# ------------------------ >8 ------------------------\n# Do not modify or remove the line above.\n# Everything below it will be ignored.\n'
VDIFF='diff --git a/f b/f\nindex 1234567..abcdef0 100644\n--- a/f\n+++ b/f\n@@ -1 +1 @@\n-old\n+new\n'
TPL='\n# Please enter the commit message for your changes. Lines starting\n# with '"'#'"' will be ignored, and an empty message aborts the commit.\n#\n# On branch main\n#\n# Changes to be committed:\n#\tmodified:   f\n#\n'

# -- editor flow ---------------------------------------------------------------------
msgfile "fix\n\nGenerated with Claude Code\n\nAssisted-by: Claude\n$TPL"
t cm-editor-disclosed-footer-ok 0 "discloses AI assistance" "$SCRIPT" --commit-msg "$MSG"
msgfile "fix\n\nGenerated with Claude Code\n$TPL"
t cm-editor-undisclosed-footer-fails 1 "Generated-by footer" "$SCRIPT" --commit-msg "$MSG"
msgfile "fix\n\nCo-authored-by: Claude <noreply@anthropic.com>\n$TPL"
t cm-editor-trailer-above-template-fails 1 "Co-authored-by" "$SCRIPT" --commit-msg "$MSG"
msgfile "fix\n\nGenerated-by: Claude <noreply@anthropic.com>\nAssisted-by: Claude\n$TPL"
t cm-editor-descriptive-disclosed-ok 0 "covered by Assisted-by" "$SCRIPT" --commit-msg "$MSG"
# Comment lines the user typed in the editor are stripped by git, so they do not count.
msgfile "fix\n\n# Generated with Claude Code\n# Co-authored-by: Claude <noreply@anthropic.com>\n$TPL"
t cm-editor-comment-lines-stripped-ok 0 "✅" "$SCRIPT" --commit-msg "$MSG"

# -- `git commit -v`: cut at the scissors line --------------------------------------
msgfile "fix\n\nGenerated with Claude Code\n\nAssisted-by: Claude\n$TPL$GITBLOCK$VDIFF"
t cm-verbose-disclosed-footer-ok 0 "discloses AI assistance" "$SCRIPT" --commit-msg "$MSG"
msgfile "fix\n\nGenerated with Claude Code\n$TPL$GITBLOCK$VDIFF"
t cm-verbose-undisclosed-footer-fails 1 "Generated-by footer" "$SCRIPT" --commit-msg "$MSG"
msgfile "fix\n\nCo-authored-by: Claude <noreply@anthropic.com>\n$TPL$GITBLOCK$VDIFF"
t cm-verbose-trailer-above-fails 1 "Co-authored-by" "$SCRIPT" --commit-msg "$MSG"
msgfile "fix\n\nGenerated with Claude Code\n\nAssisted-by: Claude\n$TPL$GITBLOCK$VDIFF\\\\ No newline at end of file\n"
t cm-verbose-no-newline-marker-ok 0 "discloses AI assistance" "$SCRIPT" --commit-msg "$MSG"
# Diff lines quoting footer or trailer text are not part of the message.
msgfile "fix\n$TPL${GITBLOCK}diff --git a/f b/f\n+Generated with Claude Code\n+Co-authored-by: Claude <noreply@anthropic.com>\n"
t cm-verbose-quoted-footer-and-trailer-ok 0 "✅" "$SCRIPT" --commit-msg "$MSG"
# A diff that deletes a trailer-shaped line (blank context line, then "-Co-authored-by").
msgfile "fix\n$TPL${GITBLOCK}diff --git a/f b/f\n@@ -1,3 +1,2 @@\n x\n \n-Co-authored-by: Claude <noreply@anthropic.com>\n"
t cm-verbose-deleted-trailer-line-ok 0 "✅" "$SCRIPT" --commit-msg "$MSG"

# -- `git commit -m/-F`: comments and scissors lines are kept ----------------------
msgfile 'fix\n\n# Generated with Claude Code\n'
t cm-message-comment-footer-fails 1 "Generated-by footer" "$SCRIPT" --commit-msg "$MSG"
msgfile 'fix\n\n# Generated with Claude Code\n\nAssisted-by: Claude\n'
t cm-message-comment-footer-disclosed-ok 0 "discloses AI assistance" "$SCRIPT" --commit-msg "$MSG"
msgfile 'fix\n\nSigned-off-by: Pat F <p@n.com>\n# Co-authored-by: Claude <noreply@anthropic.com>\n'
t cm-message-comment-trailer-lookalike-ok 0 "✅" "$SCRIPT" --commit-msg "$MSG"
# The scissors line is kept as text, but `git interpret-trailers` (which the Action runs)
# ignores everything from that line on, so trailer-shaped lines after it are not checked.
msgfile "fix\n\n${GITBLOCK}\nCo-authored-by: Claude <noreply@anthropic.com>\n"
t cm-message-trailer-after-scissors-ignored-ok 0 "✅" "$SCRIPT" --commit-msg "$MSG"
msgfile 'fix\n\n# ------------------------ >8 ------------------------\n\n-Co-authored-by: Claude <noreply@anthropic.com>\n'
t cm-message-dash-trailer-after-scissors-ignored-ok 0 "✅" "$SCRIPT" --commit-msg "$MSG"
msgfile 'fix\n\n# ------------------------ >8 ------------------------\nCo-authored-by: Claude <noreply@anthropic.com>\n'
t cm-message-adjacent-scissors-trailer-ignored-ok 0 "✅" "$SCRIPT" --commit-msg "$MSG"
# A trailer above the scissors line is still checked.
msgfile "fix\n\nCo-authored-by: Claude <noreply@anthropic.com>\n${GITBLOCK}"
t cm-message-trailer-before-scissors-fails 1 "Co-authored-by" "$SCRIPT" --commit-msg "$MSG"
# git ignores a trailing comment paragraph when it looks for the trailer block, so the
# paragraph above it is still the trailer block...
msgfile 'fix\n\nCo-authored-by: Claude <noreply@anthropic.com>\n\n# note\n'
t cm-message-trailer-then-comment-paragraph-fails 1 "Co-authored-by" "$SCRIPT" --commit-msg "$MSG"
# ...so an Assisted-by above it still discloses a footer.
msgfile 'fix\n\nGenerated with Claude Code\n\nAssisted-by: Claude\n\n# note\n'
t cm-message-assisted-then-comment-paragraph-ok 0 "discloses AI assistance" "$SCRIPT" --commit-msg "$MSG"

# -- commit.cleanup overrides the guess ----------------------------------------------
git config commit.cleanup strip
msgfile 'fix\n\n# Generated with Claude Code\n'
t cm-cleanup-strip-drops-comments 0 "✅" "$SCRIPT" --commit-msg "$MSG"
git config commit.cleanup verbatim
msgfile "fix\n\n# Generated with Claude Code\n#\n"
t cm-cleanup-verbatim-keeps-bare-comment-lines 1 "Generated-by footer" "$SCRIPT" --commit-msg "$MSG"
git config commit.cleanup whitespace
t cm-cleanup-whitespace-keeps-comments 1 "Generated-by footer" "$SCRIPT" --commit-msg "$MSG"
git config commit.cleanup scissors
# Git cuts at the scissors line only when an editor ran (the template shows that),
# and for scissors keeps comment lines. With -m/-F nothing is cut, whatever the mode.
msgfile "fix\n\n# Generated with Claude Code\n${TPL}${GITBLOCK}Co-authored-by: Claude <noreply@anthropic.com>\n"
t cm-cleanup-scissors-editor-cuts-and-keeps-comments 1 "Generated-by footer" "$SCRIPT" --commit-msg "$MSG"
msgfile "fix\n${TPL}${GITBLOCK}Generated with Claude Code\n"
t cm-cleanup-scissors-editor-ignores-below 0 "✅" "$SCRIPT" --commit-msg "$MSG"
msgfile "fix\n\n${GITBLOCK}Generated with Claude Code\n"
t cm-cleanup-scissors-message-flag-not-cut 1 "Generated-by footer" "$SCRIPT" --commit-msg "$MSG"
git config commit.cleanup strip
t cm-cleanup-strip-message-flag-not-cut 1 "Generated-by footer" "$SCRIPT" --commit-msg "$MSG"
msgfile "fix\n${TPL}${GITBLOCK}Generated with Claude Code\n"
t cm-cleanup-strip-editor-verbose-cut 0 "✅" "$SCRIPT" --commit-msg "$MSG"
git config commit.cleanup whitespace
t cm-cleanup-whitespace-editor-verbose-cut 0 "✅" "$SCRIPT" --commit-msg "$MSG"
# verbatim keeps the message as typed, even from an editor, so nothing is cut.
git config commit.cleanup verbatim
t cm-cleanup-verbatim-editor-not-cut 1 "Generated-by footer" "$SCRIPT" --commit-msg "$MSG"
git config commit.cleanup default
msgfile 'fix\n\n# Generated with Claude Code\n'
t cm-cleanup-default-guesses 1 "Generated-by footer" "$SCRIPT" --commit-msg "$MSG"
git config --unset commit.cleanup

# -- core.commentChar / core.commentString ---------------------------------------------
for cc in ';' '//' '%%'; do
  git config core.commentString "$cc"
  TPLC=${TPL//\#/$cc}
  GBC=${GITBLOCK//\#/$cc}
  msgfile "fix\n\nGenerated with Claude Code\n\nAssisted-by: Claude\n$TPLC$GBC$VDIFF"
  t "cm-commentstring-$cc-verbose-disclosed-ok" 0 "discloses AI assistance" "$SCRIPT" --commit-msg "$MSG"
  msgfile "fix\n\nCo-authored-by: Claude <noreply@anthropic.com>\n$TPLC$GBC$VDIFF"
  t "cm-commentstring-$cc-verbose-trailer-fails" 1 "Co-authored-by" "$SCRIPT" --commit-msg "$MSG"
  msgfile "fix\n\n$cc Generated with Claude Code\n$TPLC"
  t "cm-commentstring-$cc-editor-comment-stripped" 0 "✅" "$SCRIPT" --commit-msg "$MSG"
  msgfile "fix\n\n$cc Generated with Claude Code\n"
  t "cm-commentstring-$cc-message-comment-kept" 1 "Generated-by footer" "$SCRIPT" --commit-msg "$MSG"
done
git config --unset core.commentString
git config core.commentChar ';'
msgfile "fix\n\nCo-authored-by: Claude <noreply@anthropic.com>\n${TPL//\#/;}${GITBLOCK//\#/;}$VDIFF"
t cm-commentchar-semicolon-verbose-trailer-fails 1 "Co-authored-by" "$SCRIPT" --commit-msg "$MSG"
git config core.commentChar auto
msgfile "fix\n\nGenerated with Claude Code\n\nAssisted-by: Claude\n$TPL$GITBLOCK$VDIFF"
t cm-commentchar-auto-is-hash 0 "discloses AI assistance" "$SCRIPT" --commit-msg "$MSG"
git config --unset core.commentChar

# -- failures of helper tools must not pass the commit ----------------------------------
mkdir "$WORK/shim"
printf '#!/bin/sh\nexit 2\n' > "$WORK/shim/awk"
chmod +x "$WORK/shim/awk"
msgfile "fix\n\nGenerated with Claude Code\n$TPL$GITBLOCK$VDIFF"
PATH="$WORK/shim:$PATH" t cm-awk-failure-is-an-error 2 "" "$SCRIPT" --commit-msg "$MSG"

# -- basics --------------------------------------------------------------------------
msgfile 'fix\n\nAssisted-by: Claude <noreply@anthropic.com>\n'
t cm-assisted-ok 0 "discloses" "$SCRIPT" --commit-msg "$MSG"
msgfile 'fix\n\nCo-authored-by: Claude <noreply@anthropic.com>\n'
t cm-coauthor-fails 1 "Co-authored-by" "$SCRIPT" --commit-msg "$MSG"
msgfile 'fix\n\n🤖 Generated with [Claude Code](https://claude.com/claude-code)\n'
t cm-footer-fails 1 "Generated-by footer" "$SCRIPT" --commit-msg "$MSG"
msgfile 'fix\n\nGenerated-by: Claude <noreply@anthropic.com>\nAssisted-by: Claude:claude-sonnet-5-5\n'
t cm-descriptive-disclosed-ok 0 "covered by Assisted-by" "$SCRIPT" --commit-msg "$MSG"
msgfile 'fix\n\nGenerated-by: Claude <noreply@anthropic.com>\n'
t cm-descriptive-undisclosed-fails 1 "not disclosed" "$SCRIPT" --commit-msg "$MSG"
msgfile 'fix\n\nGenerated-by: Claude <noreply@anthropic.com>\n'
t cm-violation-reported-once 1 "Offending line" "$SCRIPT" --commit-msg "$MSG"
out=$("$SCRIPT" --commit-msg "$MSG" 2>&1); n=$(grep -c 'Offending line' <<< "$out")
if [ "$n" -eq 1 ]; then pass=$((pass + 1)); echo "ok   cm-single-report"; else fail=$((fail + 1)); echo "FAIL cm-single-report (n=$n)"; fi
msgfile 'plain\n'
t cm-human-ok 0 "✅" "$SCRIPT" --commit-msg "$MSG"
GIT_AUTHOR_NAME=Claude GIT_AUTHOR_EMAIL=noreply@anthropic.com \
  t cm-author-from-env 1 "author of a commit" "$SCRIPT" --commit-msg "$MSG"
t cm-extra-flag-after-file 0 "✅" "$SCRIPT" --commit-msg "$MSG" --extra-ai-identity-regex x
t cm-unreadable-file 2 "cannot read" "$SCRIPT" --commit-msg "$WORK/nope"

# The real thing: git runs the script as a commit-msg hook.
# shellcheck disable=SC2016
printf '#!/bin/sh\nexec "%s" --commit-msg "$1"\n' "$SCRIPT" > .git/hooks/commit-msg
chmod +x .git/hooks/commit-msg
t hook-blocks-commit 1 "" git commit -q --allow-empty -m $'x\n\nCo-authored-by: Claude <noreply@anthropic.com>'
t hook-allows-assisted-by 0 "" git commit -q --allow-empty -m $'x\n\nAssisted-by: Claude Sonnet 5.5'

# Real editor flows, so the "bare comment line means an editor ran" guess is checked
# against what git really writes. The "editor" puts a message above the template.
reset
cat > "$WORK/editor" <<'EOF'
#!/bin/sh
printf '%b\n' "$EDITOR_MESSAGE" | cat - "$1" > "$1.new" && mv "$1.new" "$1"
EOF
chmod +x "$WORK/editor"
echo staged > f; git add f
export GIT_EDITOR=$WORK/editor
FOOTER_MSG='fix\n\nGenerated with Claude Code'
EDITOR_MESSAGE="$FOOTER_MSG\n\nAssisted-by: Claude" t real-editor-disclosed-footer-commits 0 "" git commit -q
reset; echo staged > f; git add f
EDITOR_MESSAGE="$FOOTER_MSG" t real-editor-undisclosed-footer-blocked 1 "Generated-by footer" git commit -q
EDITOR_MESSAGE="$FOOTER_MSG\n\nAssisted-by: Claude" t real-editor-verbose-disclosed-footer-commits 0 "" git commit -q -v
reset; echo staged > f; git add f
EDITOR_MESSAGE="$FOOTER_MSG" t real-editor-verbose-undisclosed-footer-blocked 1 "Generated-by footer" git commit -q -v
# A staged change whose diff quotes the footer text must not trip `commit -v`.
reset; echo 'Generated with Claude Code' > f; git add f
EDITOR_MESSAGE='fix' t real-editor-verbose-diff-quotes-footer-commits 0 "" git commit -q -v
git commit -q -a --amend --no-edit 2> /dev/null; reset
echo staged > f; git add f
EDITOR_MESSAGE="fix\n\n# Generated with Claude Code" t real-editor-comment-stripped-commits 0 "" git commit -q
unset GIT_EDITOR
printf 'fix\n\n# Generated with Claude Code\n' > "$WORK/m"
reset; echo staged > f; git add f
t real-message-file-keeps-comment-blocked 1 "Generated-by footer" git commit -q -F "$WORK/m"
reset; echo staged > f; git add f
t real-message-flag-keeps-comment-blocked 1 "Generated-by footer" git commit -q -m $'fix\n\n# Generated with Claude Code'
printf 'fix\n\n# ------------------------ >8 ------------------------\n# Do not modify or remove the line above.\n\nCo-authored-by: Claude <noreply@anthropic.com>\n' > "$WORK/m"
# git ignores trailers after the scissors line, so neither the hook nor the range check sees it.
t real-message-file-with-scissors-trailer-ignored 0 "" git commit -q -F "$WORK/m"
# commit.cleanup=strip or scissors with -F: git cuts nothing, so a footer below the
# scissors line is stored and must be seen.
printf 'fix\n\n# ------------------------ >8 ------------------------\n# c\nGenerated with Claude Code\n' > "$WORK/m"
for cl in strip scissors; do
  git config commit.cleanup "$cl"
  reset; echo staged > f; git add f
  t "real-cleanup-$cl-file-keeps-below-scissors-blocked" 1 "Generated-by footer" git commit -q -F "$WORK/m"
done
git config --unset commit.cleanup
rm -f .git/hooks/commit-msg; git reset -q --hard "$BASE"

# --- pre-push mode: the range check on what is about to be pushed ---------------------
git init -q --bare "$WORK/remote.git"
git remote add origin "$WORK/remote.git"
git push -q origin "$BASE:refs/heads/main"
ZERO=0000000000000000000000000000000000000000
reset; c $'one\n\nCo-authored-by: Claude <noreply@anthropic.com>'; FIRST=$(git rev-parse HEAD); c two; HEAD_SHA=$(git rev-parse HEAD)
PRE_COMMIT_FROM_REF=$BASE PRE_COMMIT_TO_REF=$HEAD_SHA t prepush-violation-in-range 1 "Co-authored-by" "$SCRIPT" --pre-push
PRE_COMMIT_FROM_REF=$FIRST PRE_COMMIT_TO_REF=$HEAD_SHA t prepush-only-pushed-commits-checked 0 "✅" "$SCRIPT" --pre-push
PRE_COMMIT_FROM_REF=$ZERO PRE_COMMIT_TO_REF=$HEAD_SHA t prepush-new-branch-zero-from 1 "Co-authored-by" "$SCRIPT" --pre-push
PRE_COMMIT_FROM_REF='' PRE_COMMIT_TO_REF=$HEAD_SHA t prepush-new-branch-empty-from 1 "Co-authored-by" "$SCRIPT" --pre-push
git push -q origin "$FIRST:refs/heads/main"
PRE_COMMIT_FROM_REF=$ZERO PRE_COMMIT_TO_REF=$HEAD_SHA t prepush-new-branch-skips-remote-commits 0 "✅" "$SCRIPT" --pre-push
PRE_COMMIT_FROM_REF=$BASE PRE_COMMIT_TO_REF=$ZERO t prepush-branch-deletion-nothing-to-check 0 "Nothing to check" "$SCRIPT" --pre-push
# pre-commit gives no refs for an initial push (or when run by hand): check what no
# remote has yet, from HEAD.
git push -q -f origin "$BASE:refs/heads/main"
t prepush-no-refs-checks-head 1 "Co-authored-by" "$SCRIPT" --pre-push
git push -q origin "$FIRST:refs/heads/main"
t prepush-no-refs-skips-remote-commits 0 "✅" "$SCRIPT" --pre-push
# Git's own pre-push input (stdin) can carry several updates; every one is checked.
git push -q -f origin "$BASE:refs/heads/main"
# The input is redirected into t (not piped), so t runs in this shell and its
# failures count.
NL=$'\n'
t prepush-stdin-later-update-checked 1 "Co-authored-by" "$SCRIPT" --pre-push-stdin \
  <<< "refs/heads/a $BASE refs/heads/a $BASE${NL}refs/heads/b $FIRST refs/heads/b $BASE"
t prepush-stdin-clean-updates-ok 0 "✅" "$SCRIPT" --pre-push-stdin \
  <<< "refs/heads/a $BASE refs/heads/a $BASE${NL}refs/heads/b $HEAD_SHA refs/heads/b $FIRST"
t prepush-stdin-deletion-skipped 0 "✅" "$SCRIPT" --pre-push-stdin \
  <<< "refs/heads/a $BASE refs/heads/a $BASE${NL}refs/heads/b $ZERO refs/heads/b $BASE"
t prepush-stdin-new-branch-checked 1 "Co-authored-by" "$SCRIPT" --pre-push-stdin \
  <<< "refs/heads/new $FIRST refs/heads/new $ZERO"
t prepush-stdin-empty-ok 0 "Nothing to check" "$SCRIPT" --pre-push-stdin < /dev/null
# pre-commit names the branch being pushed; an initial push of a branch that is not
# checked out must check that branch, not HEAD.
git push -q -f origin "$HEAD_SHA:refs/heads/main"
SIDE=$(git commit-tree "$HEAD_SHA^{tree}" -p "$BASE" -m $'bad\n\nCo-authored-by: Claude <noreply@anthropic.com>')
git branch -f side "$SIDE"
t prepush-no-refs-head-clean-ok 0 "✅" "$SCRIPT" --pre-push
PRE_COMMIT_LOCAL_BRANCH=refs/heads/side t prepush-local-branch-checked 1 "Co-authored-by" "$SCRIPT" --pre-push
PRE_COMMIT_LOCAL_BRANCH=refs/heads/side PRE_COMMIT_TO_REF=$HEAD_SHA PRE_COMMIT_FROM_REF=$FIRST \
  t prepush-to-ref-wins-over-local-branch 0 "✅" "$SCRIPT" --pre-push
git branch -D -q side
t prepush-takes-no-target 2 "usage" env PRE_COMMIT_TO_REF="$HEAD_SHA" "$SCRIPT" --pre-push "$BASE..HEAD"
git remote remove origin; reset

echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
