#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
# SPDX-FileCopyrightText: Copyright Contributors to the Kokkos project
#
# Enforce a policy on AI attribution in commits:
#   - AI agents/bots must not be the commit author,
#   - AI agents/bots must not appear in human-only trailers ('Signed-off-by:',
#     'Co-authored-by:', 'Reviewed-by:', ...), nor in any trailer not known to
#     be descriptive,
#   - AI agents/bots may appear in descriptive trailers ('Generated-by:',
#     'Tested-by:', ...) only if the same agent is also named in an
#     'Assisted-by:' trailer (e.g. 'Assisted-by: Claude:claude-sonnet-5-5'),
#   - a generated-by footer in the message ("Generated with Claude Code", ...)
#     requires an 'Assisted-by:' trailer,
#   - AI assistance is disclosed with 'Assisted-by:' (reported, never an error).
#
# Allowlisted bots (dependabot, ...) are not AI agents here: nothing is
# required of them, as author or in any trailer.
#
# Usage:
#   check_ai_attribution.sh [options] <base>..<head>
#       check all commits in the range (merge commits: author and trailers
#       only, since their message is generated)
#   check_ai_attribution.sh --pre-push [options]
#       check the commits about to be pushed (PRE_COMMIT_FROM_REF and
#       PRE_COMMIT_TO_REF, as set by pre-commit/prek, which give only the first
#       updated ref; without them, the commits of PRE_COMMIT_LOCAL_BRANCH, else
#       HEAD, that no remote has); the
#       same check as the range mode, so it gives the result the Action will give
#   check_ai_attribution.sh --pre-push-stdin [options]
#       the same for every update in git's own pre-push input on stdin (for a
#       native .git/hooks/pre-push, which pre-commit cannot be)
#   check_ai_attribution.sh --commit-msg [options] FILE
#       check the commit being created (for a commit-msg hook); the author is
#       taken from `git var GIT_AUTHOR_IDENT`. The message is read the way git
#       will store it, which is what the range mode checks later.
#
# Options:
#   --extra-ai-identity-regex REGEX  also treat identities matching this ERE as AI agents
#   --extra-bot-allowlist REGEX      also allow "[bot]" identities matching this ERE
#   --extra-descriptive-trailer KEY  also treat trailer KEY as descriptive (repeatable)
#   --extra-human-only-trailer KEY   also treat trailer KEY as human-only (repeatable;
#                                    wins over a descriptive listing)
#   --extra-descriptive-trailers LIST, --extra-human-only-trailers LIST
#                                    the same, as a comma- or newline-separated list
#   --policy-url URL                 print this link after a violation
#
# An "identity" is the string "Name <email>" (or the bare value of a trailer).
#
# Exit status: 0 = compliant, 1 = policy violation, 2 = usage or tool error.

set -u

# Substrings of an identity (name or email) that unambiguously denote an AI
# agent. Deliberately narrow: a bare substring like "bot" or "github" would
# flag humans (e.g. "Talbot", "12345+user@users.noreply.github.com"), and a
# bare "@cursor.com" would flag people who work at Cursor.
AI_IDENTITY_REGEX='noreply@anthropic\.com|noreply@openai\.com|@agentmail\.to([>[:space:]]|$)|copilot@github\.com|\+copilot@users\.noreply\.github\.com|cursoragent@cursor\.com|@devin\.ai([>[:space:]]|$)|devin-ai-integration|google-labs-jules|noreply@aider\.chat|\(aider\)|\[aider\]'

# An identity with no email address is also an AI agent if its name is a bare
# agent name: an optional "@" and vendor ("GitHub Copilot", "OpenAI Codex"), the
# agent, then any mix of versions and model words ("Codex 5", "Claude 3.5
# Sonnet", "Gemini 2.5 Pro", "ChatGPT 4o", "claude-code", "Cursor Agent"),
# optionally followed by "." or a parenthesis ("Claude (AI)"); or "GPT-<n>...".
# A name is never matched when there is an address, so humans such as "Claude
# Martin <claude.martin@example.org>" or "Devin Smith <...>" pass, and a person
# whose bare name is "Devin Smith" passes because "smith" is no model word.
# "Jules" is deliberately absent: it is a common first name, and the Jules agent
# is caught by its bot identity.
# Known gap: an agent with a non-standard email and a non-"[bot]" name is not caught.
AI_NAME_WORD='([0-9][0-9a-z.]*|code|opus|sonnet|haiku|fable|pro|flash|ultra|nano|mini|max|agent|ai|bot|assistant|swe-agent)'
AI_NAME_REGEX='^(@?((github|openai|google|anthropic)[ -])?(claude|copilot|chatgpt|codex|gemini|cursor|devin|aider)([ -]'"$AI_NAME_WORD"')*[[:space:]]*(\([^)]*\))?\.?|gpt-[0-9][^ <]*( .*)?)[[:space:]]*$'

# Any other "[bot]" identity (e.g. "claude[bot]", "copilot-swe-agent[bot]") is
# rejected unless it is non-AI automation listed here. Entries are matched
# against the whole "Name <email>", since a name alone is free text anyone can
# claim; dependabot signs off with support@github.com.
BOT_ALLOWLIST_REGEX='^dependabot\[bot\] <([0-9]+\+dependabot\[bot\]@users\.noreply\.github\.com|support@github\.com)>[[:space:]]*$|^pre-commit-ci\[bot\] <[0-9]+\+pre-commit-ci\[bot\]@users\.noreply\.github\.com>[[:space:]]*$'

# Generated-by footers that agents add to commit messages.
FOOTER_REGEX='Generated with \[?(Claude Code|Cursor|Copilot)|🤖 Generated|claude\.ai/code|claude\.com/claude-code'

# Trailer keys (lowercase, space-delimited). An AI identity is never allowed
# under a human-only key: these assert accountability or authorship, which a
# tool cannot take on (e.g. an AI cannot sign a Developer Certificate of
# Origin). It is allowed under a descriptive key if an 'Assisted-by:' trailer
# discloses the same agent. Keys on neither list are treated as human-only.
HUMAN_ONLY_TRAILERS="signed-off-by co-authored-by co-developed-by acked-by approved-by authorized-by reviewed-by"
DESCRIPTIVE_TRAILERS="generated-by tested-by reported-by suggested-by debugged-by analyzed-by found-by helped-by proposed-by"

POLICY_URL=""
FAILURE_DETECTED=false

# is_descriptive_trailer KEY: human-only overrides descriptive membership.
is_descriptive_trailer() {
  case " $HUMAN_ONLY_TRAILERS " in *" $1 "*) return 1 ;; esac
  case " $DESCRIPTIVE_TRAILERS " in *" $1 "*) return 0 ;; esac
  return 1
}

# agent_key VALUE: the lowercase name part of an identity or Assisted-by value,
# up to the first ':', '<', '(' or '[' ("Claude Sonnet 5.5 <a@b>" -> "claude
# sonnet 5.5", "Copilot:gpt-4o" -> "copilot").
agent_key() {
  local name=${1%%:*}
  name=${name%%<*}
  name=${name%%(*}
  name=${name%%\[*}
  name=$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]')
  name=${name#"${name%%[![:space:]]*}"}
  name=${name%"${name##*[![:space:]]}"}
  # A handle ("@copilot") names the same agent as "copilot".
  name=${name#@}
  printf '%s' "$name"
}

# keys_match A B: succeeds if two non-empty agent keys are equal, or one is a
# prefix of the other ending at a word boundary (space or '-'), so "claude"
# matches "claude sonnet 5.5" and "copilot" matches "copilot-swe-agent", but
# "agent" does not match "some agent" and "some" does not match "somebody".
keys_match() {
  [ -n "$1" ] && [ -n "$2" ] || return 1
  [ "$1" = "$2" ] && return 0
  case "$1" in "$2 "* | "$2-"*) return 0 ;; esac
  case "$2" in "$1 "* | "$1-"*) return 0 ;; esac
  return 1
}

# is_disclosed KEY ASSISTED_LINES: succeeds if any 'Assisted-by:' line names the
# agent KEY.
is_disclosed() {
  local line
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    keys_match "$1" "$(agent_key "${line#*:}")" && return 0
  done <<< "$2"
  return 1
}

# is_ai_identity "Name <email>": succeeds if the identity must not appear as an
# author, co-author or signer.
is_ai_identity() {
  local identity=$1 name
  grep -Eiq "$AI_IDENTITY_REGEX" <<< "$identity" && return 0
  # A name is matched only when there is no email address; "<>" and "<nobody>"
  # are not addresses, so they are dropped before the name is looked at.
  if ! grep -Eq '<[^<>@[:space:]]+@[^<>[:space:]]+>' <<< "$identity"; then
    # shellcheck disable=SC2001 # a bracket-class regex; ${var//pat/} only takes globs
    name=$(sed 's/<[^>]*>//g' <<< "$identity")
    grep -Eiq "$AI_NAME_REGEX" <<< "$name" && return 0
  fi
  grep -Eiq '\[bot\]' <<< "$identity" && ! grep -Eiq "$BOT_ALLOWLIST_REGEX" <<< "$identity"
}

# GitHub workflow annotations only make sense inside Actions.
annotate() {
  # $1 = level (error|notice), $2 = title, $3 = message
  if [ "${GITHUB_ACTIONS:-}" = "true" ]; then
    echo "::$1 title=$2::$3"
  fi
}

report_violation() {
  # $1 = commit label, $2 = title, $3 = offending line, $4... = hints
  local label=$1 title=$2 offending=$3
  shift 3
  FAILURE_DETECTED=true
  annotate error "AI tool policy" "${label:0:12}: ${title}"
  echo "❌ Commit $label: $title"
  echo "    Offending line: $offending"
  local hint
  for hint in "$@"; do
    echo "    $hint"
  done
}

# check_commit LABEL AUTHOR MESSAGE [merge]
# 'merge' skips the footer check: the message of a merge commit is generated,
# and quotes the names of the branches it joins.
check_commit() {
  local label=$1 author=$2 message=$3 merge=${4:-}

  # --- AI AGENTS MUST NOT BE THE COMMIT AUTHOR ---
  if is_ai_identity "$author"; then
    report_violation "$label" "AI agents cannot be the author of a commit." \
      "$author" \
      "Set the author to the human contributor responsible for the change."
  fi

  # --- TRAILERS ---
  local trailers assisted line trailer key lower_key identity agent
  trailers=$(git interpret-trailers --parse --no-divider <<< "$message")

  # 'Assisted-by:' is the sanctioned disclosure: informational only. The lines
  # are collected first because they may follow the trailers that rely on them.
  # One with no value names no tool and discloses nothing.
  assisted=$(grep -i '^Assisted-by:[[:space:]]*[^[:space:]]' <<< "$trailers") || assisted=""
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    annotate notice "AI assistance disclosed" "${label:0:12}: ${line}"
    echo "ℹ️  Commit $label discloses AI assistance: $line"
  done <<< "$assisted"

  while IFS= read -r trailer; do
    [ -n "$trailer" ] || continue

    # Split "Key: Name <email>" so the identity regex sees just the identity.
    key=${trailer%%:*}
    identity=${trailer#*:}
    identity=${identity#"${identity%%[![:space:]]*}"}
    # Lowercase portably; "${key,,}" needs Bash 4 and macOS ships Bash 3.2.
    lower_key=$(printf '%s' "$key" | tr '[:upper:]' '[:lower:]')

    [ "$lower_key" != "assisted-by" ] || continue
    is_ai_identity "$identity" || continue

    if [ "$lower_key" = "signed-off-by" ]; then
      report_violation "$label" "AI agents cannot sign off on contributions." \
        "$trailer" \
        "'Signed-off-by:' must carry the human contributor's identity."
    elif ! is_descriptive_trailer "$lower_key"; then
      report_violation "$label" "AI agents cannot be listed under '${key}:'." \
        "$trailer" \
        "'${key}:' is human-only; disclose AI assistance with 'Assisted-by:'."
    else
      agent=$(agent_key "$identity")
      # A bare address ("<a@b>" or "a@b") has no tool name to match.
      case "$agent" in ?*@*) agent="" ;; esac
      if is_disclosed "$agent" "$assisted"; then
        echo "ℹ️  Commit $label: AI identity under '${key}:' is covered by Assisted-by: $trailer"
      else
        local hint="Add 'Assisted-by: <Tool>[:model]' whose name starts with '${agent:-<tool name>}' (e.g. 'Assisted-by: Claude:claude-sonnet-5-5')."
        if [ -z "$agent" ]; then
          hint="Name the tool in the trailer value (e.g. '${key}: Claude <noreply@anthropic.com>'), then $hint"
        fi
        report_violation "$label" "AI identity under '${key}:' is not disclosed in an 'Assisted-by:' trailer." \
          "$trailer" \
          "$hint"
      fi
    fi
  done <<< "$trailers"

  # --- GENERATED-BY FOOTERS NEED A DISCLOSURE ---
  if [ -z "$assisted" ] && [ -z "$merge" ]; then
    local footer
    footer=$(grep -Eim1 "$FOOTER_REGEX" <<< "$message") || footer=""
    if [ -n "$footer" ]; then
      report_violation "$label" "Generated-by footer without an 'Assisted-by:' trailer." \
        "$footer" \
        "Add an 'Assisted-by:' trailer naming the tool, or remove the footer."
    fi
  fi
}

# check_range REV_LIST_ARG...: check every commit `git rev-list ARG...` lists.
check_range() {
  local commit commits parents merge

  commits=$(git rev-list "$@") || return 2

  if [ -z "$commits" ]; then
    echo "No commits to check."
    return 0
  fi

  for commit in $commits; do
    # A merge commit has several parents. Its author and trailers are checked
    # like any other (a conflict resolution has an author), but not its
    # generated message for footers.
    parents=$(git log -1 --format='%P' "$commit") || return 2
    merge=""
    case "$parents" in *" "*) merge=merge ;; esac
    check_commit "$commit" \
      "$(git log -1 --format='%an <%ae>' "$commit")" \
      "$(git log -1 --format='%B' "$commit")" \
      "$merge"
  done
}

# check_push_update TO FROM: check the commits one ref update pushes, with the
# range check the Action runs. All-zero or empty FROM is a new branch; all-zero
# TO is a deletion.
check_push_update() {
  local to=$1 from=${2:-}

  if [ -z "${to//0/}" ]; then
    echo "Nothing to check: the branch is being deleted."
    return 0
  fi
  if [ -z "${from//0/}" ]; then
    # A new branch: check the commits no remote branch has yet.
    check_range "$to" --not --remotes
  else
    check_range "$to" --not "$from"
  fi
}

# check_pre_push: check what a pre-commit/prek pre-push hook is about to push.
# They pass one ref pair in the environment (the first applicable update; they
# keep git's stdin, so `--pre-push-stdin` is the way to see every update). With
# no refs (an initial push, or run by hand) check what no remote has, from the
# branch pre-commit names in PRE_COMMIT_LOCAL_BRANCH, else HEAD.
check_pre_push() {
  check_push_update "${PRE_COMMIT_TO_REF:-${PRE_COMMIT_LOCAL_BRANCH:-HEAD}}" "${PRE_COMMIT_FROM_REF:-}"
}

# check_pre_push_stdin: check every update in git's own pre-push input, one
# "<local ref> <local sha> <remote ref> <remote sha>" line per updated ref.
check_pre_push_stdin() {
  local local_sha remote_sha rc=0 seen=""

  while read -r _ local_sha _ remote_sha; do
    [ -n "$local_sha" ] || continue
    seen=yes
    check_push_update "$local_sha" "$remote_sha" || rc=2
  done
  [ -n "$seen" ] || echo "Nothing to check: no refs are being pushed."
  return "$rc"
}

# comment_string: git's comment string. core.commentString (git 2.45) replaces
# core.commentChar; "auto" means "#" for our purposes.
comment_string() {
  local cs
  cs=$(git config core.commentString 2>/dev/null) \
    || cs=$(git config core.commentChar 2>/dev/null) || cs=""
  case "$cs" in "" | auto) cs='#' ;; esac
  printf '%s' "$cs"
}

# stored_message FILE: the message git will store for the commit-msg FILE, which
# is what the Action reads later. Git cleans the file up according to
# commit.cleanup, and on whether an editor ran (checked against real git):
#   - Editor: git cuts at a scissors line (`commit -v` appends one, and
#     commit.cleanup=scissors cuts at one too). By default comment lines are then
#     removed.
#   - -m/-F, no editor: nothing is cut, whatever the mode ("scissors" acts like
#     "whitespace"). By default only whitespace is tidied, so comment lines and
#     scissors lines stay as text.
# commit.cleanup chooses what happens to comment lines: strip removes them,
# whitespace and scissors keep them. verbatim leaves the message alone, and git
# then cuts only for `commit -v`, which the file cannot be told from a typed
# scissors line, so verbatim is never cut (a `commit -v` diff then counts).
# The file shows whether an editor ran: the editor template always contains a line
# that is just the comment string (it does not depend on the language).
stored_message() {
  local file=$1 cs cleanup text rc=0 editor=""
  cs=$(comment_string)
  awk -v c="$cs" '
    BEGIN { n = length(c) }
    substr($0, 1, n) == c && substr($0, n + 1) ~ /^[[:space:]]*$/ { found = 1; exit }
    END { exit !found }' "$file" || rc=$?
  case "$rc" in
    0) editor=yes ;;
    1) ;;
    *) return 2 ;;
  esac

  cleanup=$(git config commit.cleanup 2>/dev/null) || cleanup=""
  case "$cleanup" in
    strip | scissors | whitespace | verbatim) ;;
    *) if [ -n "$editor" ]; then cleanup="strip"; else cleanup="whitespace"; fi ;;
  esac

  if [ -n "$editor" ] && [ "$cleanup" != verbatim ]; then
    text=$(awk -v c="$cs" '
      BEGIN { n = length(c) }
      substr($0, 1, n) == c && substr($0, n + 1) ~ /^ -+ >8 -+$/ { exit }
      { print }' "$file") || return 2
  else
    text=$(cat "$file") || return 2
  fi

  case "$cleanup" in
    verbatim) printf '%s\n' "$text" ;;
    strip) git stripspace --strip-comments <<< "$text" ;;
    *) git stripspace <<< "$text" ;;
  esac
}

check_commit_msg_file() {
  local file=$1 ident message

  if [ ! -r "$file" ]; then
    echo "error: cannot read commit message file '$file'" >&2
    return 2
  fi

  # "Name <email> <timestamp> <tz>" -> "Name <email>"
  ident=$(git var GIT_AUTHOR_IDENT) || return 2
  ident=${ident% * *}

  message=$(stored_message "$file") || return 2
  check_commit "commit-msg" "$ident" "$message"
}

usage() {
  cat >&2 <<EOF
usage: $0 [options] <base>..<head>
       $0 --pre-push [options]
       $0 --pre-push-stdin [options]
       $0 --commit-msg [options] FILE
options: --extra-ai-identity-regex REGEX  --extra-bot-allowlist REGEX
         --extra-descriptive-trailer KEY  --extra-human-only-trailer KEY
         --extra-descriptive-trailers LIST  --extra-human-only-trailers LIST
         --policy-url URL
EOF
  exit 2
}

# validate_trailer_key FLAG KEY: a malformed key (it is matched literally in
# space-delimited lists) is a usage error. Must run in the main shell, not in a
# command substitution, so that its exit ends the script.
validate_trailer_key() {
  case "$2" in
    "" | *[!A-Za-z0-9-]*)
      echo "error: invalid trailer key for $1: '$2'" >&2
      exit 2
      ;;
  esac
}

# add_trailer_key FLAG KEY: add KEY, lowercased, to the list FLAG extends.
add_trailer_key() {
  local lower
  validate_trailer_key "$1" "$2"
  lower=$(printf '%s' "$2" | tr '[:upper:]' '[:lower:]')
  case "$1" in
    *descriptive*) DESCRIPTIVE_TRAILERS="$DESCRIPTIVE_TRAILERS $lower" ;;
    *) HUMAN_ONLY_TRAILERS="$HUMAN_ONLY_TRAILERS $lower" ;;
  esac
}

# add_trailer_keys FLAG LIST: add_trailer_key for each entry of a comma- or
# newline-separated LIST (an Action input may be either). Spaces around an
# entry are trimmed and empty entries skipped; a space inside one is an error.
add_trailer_keys() {
  local entry
  while IFS= read -r entry; do
    entry=${entry#"${entry%%[![:space:]]*}"}
    entry=${entry%"${entry##*[![:space:]]}"}
    [ -n "$entry" ] || continue
    add_trailer_key "$1" "$entry"
  done <<< "${2//,/$'\n'}"
}

# validate_regex FLAG REGEX: a typo in a user-supplied ERE must fail loudly
# instead of silently matching nothing (grep exits 2 on an invalid pattern).
validate_regex() {
  local rc=0
  grep -E -- "$2" < /dev/null > /dev/null 2>&1 || rc=$?
  if [ "$rc" -eq 2 ]; then
    echo "error: invalid regular expression for $1: $2" >&2
    exit 2
  fi
  # An empty alternative ('', 'foo|', 'x*') matches every identity.
  if grep -Eq -- "$2" <<< ""; then
    echo "error: regular expression for $1 matches the empty string: '$2'" >&2
    exit 2
  fi
}

MODE=range
TARGET=""
while [ $# -gt 0 ]; do
  case "$1" in
    --commit-msg)
      MODE="commit-msg"
      ;;
    --pre-push)
      MODE=pre-push
      ;;
    --pre-push-stdin)
      MODE=pre-push-stdin
      ;;
    --extra-ai-identity-regex|--extra-bot-allowlist|--extra-descriptive-trailer|--extra-human-only-trailer|--extra-descriptive-trailers|--extra-human-only-trailers|--policy-url)
      [ $# -ge 2 ] || usage
      case "$1" in
        --extra-ai-identity-regex)
          regex=$(printf '%s' "$2")
          validate_regex "$1" "$regex"
          AI_IDENTITY_REGEX="$AI_IDENTITY_REGEX|$regex"
          ;;
        --extra-bot-allowlist)
          regex=$(printf '%s' "$2")
          validate_regex "$1" "$regex"
          BOT_ALLOWLIST_REGEX="$BOT_ALLOWLIST_REGEX|$regex"
          ;;
        --extra-descriptive-trailer|--extra-human-only-trailer)
          add_trailer_key "$1" "$2"
          ;;
        --extra-descriptive-trailers|--extra-human-only-trailers)
          add_trailer_keys "$1" "$2"
          ;;
        --policy-url)
          POLICY_URL=$2
          ;;
      esac
      shift
      ;;
    -*)
      usage
      ;;
    *)
      [ -z "$TARGET" ] || usage
      TARGET=$1
      ;;
  esac
  shift
done

case "$MODE" in
  pre-push)
    [ -z "$TARGET" ] || usage
    check_pre_push || exit 2
    ;;
  pre-push-stdin)
    [ -z "$TARGET" ] || usage
    check_pre_push_stdin || exit 2
    ;;
  commit-msg)
    [ -n "$TARGET" ] || usage
    check_commit_msg_file "$TARGET" || exit 2
    ;;
  *)
    [ -n "$TARGET" ] || usage
    check_range "$TARGET" || exit 2
    ;;
esac

if [ "$FAILURE_DETECTED" = true ]; then
  if [ "${GITHUB_ACTIONS:-}" = "true" ]; then
    echo "::error::Commit validation failed. Human attribution rules were violated."
  fi
  if [ -n "$POLICY_URL" ]; then
    echo "See policy at $POLICY_URL"
  fi
  exit 1
fi
echo "✅ All commits follow the human authorship and AI attribution guidelines."
