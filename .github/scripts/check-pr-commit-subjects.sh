#!/usr/bin/env bash
#
# Check that a pull request to a percona-server version branch follows the
# commit-subject convention: every commit subject names a ticket key and
# carries the base branch tag, for example "PS-11435 [8.4] Add ...". The tag
# is what survives the upward null-merges (8.0 -> 8.4 -> 9.7 -> trunk) and
# what release tooling greps for, so a squash merged under a rewritten
# subject loses the change for both.
#
# Inputs (environment):
#   REPO       owner/name, default percona/percona-server
#   PR_NUMBER  pull request number
#   BASE_REF   base branch name
#   PR_TITLE   pull request title
#   GH_TOKEN   GitHub API token, read access is enough
#
# Exit 0 when the PR conforms or is out of scope (non-version base branch,
# merge-style PR). Exit 1 with one ::error:: line per violation otherwise.

# has_key and has_tag are predicates, so they run inside if conditions on purpose.
# shellcheck disable=SC2310
set -euo pipefail

# A ticket key with word boundaries that do not depend on the locale.
readonly KEY_RE='(^|[^[:alnum:]_])(PS|PXB|PXC|DISTMYSQL)-[0-9]+([^[:alnum:]_]|$)'
readonly REPO="${REPO:-percona/percona-server}"
: "${PR_NUMBER:?PR_NUMBER is required}"
: "${BASE_REF:?BASE_REF is required}"
: "${PR_TITLE:?PR_TITLE is required}"

# Tags accepted per base branch, one per line. trunk history carries both.
tags_for_base() {
  case "$1" in
    8.0) echo '[8.0]' ;;
    8.4) echo '[8.4]' ;;
    9.7) echo '[9.7]' ;;
    trunk) printf '%s\n' '[trunk]' '[10.x]' ;;
    *) ;;
  esac
}

note() { echo "::notice::$*"; }
fail() { echo "::error::$*"; }

has_key() { grep -Eq "${KEY_RE}" <<<"$1"; }

# True when the subject carries one of the accepted tags.
has_tag() {
  local subject="$1" tag
  shift
  for tag in "$@"; do
    if [[ "${subject}" == *"${tag}"* ]]; then
      return 0
    fi
  done
  return 1
}

main() {
  local tags_raw
  tags_raw="$(tags_for_base "${BASE_REF}")"
  if [[ -z "${tags_raw}" ]]; then
    note "base branch ${BASE_REF} is not a version branch, nothing to check"
    return 0
  fi
  local -a tags
  mapfile -t tags <<<"${tags_raw}"
  local tag_list="${tags[*]}"
  local expected="<KEY>-<n> ${tags[0]} <what changed>"

  if [[ "${PR_TITLE}" =~ ^(Null[-\ ]merge|Merge\ ) ]]; then
    note "merge-style PR title, its commits come from another branch, nothing to check"
    return 0
  fi

  # The list endpoint stops at 250 commits, so compare against the PR's own count.
  local total
  total="$(gh api "repos/${REPO}/pulls/${PR_NUMBER}" --jq '.commits')"

  # One line per commit, unit-separator delimited so tabs in a subject survive:
  # sha<US>parent count<US>subject.
  local commits
  commits="$(gh api --paginate "repos/${REPO}/pulls/${PR_NUMBER}/commits" \
    --jq '.[] | "\(.sha[0:12])\u001f\(.parents | length)\u001f\(.commit.message | split("\n")[0])"')"
  if [[ -z "${commits}" ]]; then
    fail "no commits found on PR ${PR_NUMBER}"
    return 1
  fi
  if awk -F$'\x1f' '$2 > 1 { found = 1 } END { exit !found }' <<<"${commits}"; then
    note "PR contains a merge commit (upstream or null merge), nothing to check"
    return 0
  fi
  local fetched
  fetched="$(wc -l <<<"${commits}")"
  if (( fetched < total )); then
    fail "PR has ${total} commits but only ${fetched} could be listed, split it or check the subjects by hand"
    return 1
  fi

  local violations=0
  if ! has_key "${PR_TITLE}"; then
    fail "PR title lacks a ticket key (PS-<n>, PXB-<n>, PXC-<n> or DISTMYSQL-<n>): ${PR_TITLE}"
    violations=$((violations + 1))
  fi
  # A squash merge of several commits takes the PR title as its subject, so
  # the title needs the tag whenever there is more than one commit.
  if (( fetched > 1 )) && ! has_tag "${PR_TITLE}" "${tags[@]}"; then
    fail "PR has ${fetched} commits, so a squash merge would use the title as the subject, and the title lacks the ${tag_list// / or } tag: ${PR_TITLE}"
    violations=$((violations + 1))
  fi

  local sha subject
  while IFS=$'\x1f' read -r sha _ subject; do
    # A plain git revert or reapply keeps the original subject by design.
    if [[ "${subject}" == 'Revert "'* || "${subject}" == 'Reapply "'* ]]; then
      continue
    fi
    if ! has_key "${subject}"; then
      fail "${sha}: subject lacks a ticket key: ${subject}"
      violations=$((violations + 1))
      continue
    fi
    if ! has_tag "${subject}" "${tags[@]}"; then
      fail "${sha}: subject lacks the ${tag_list// / or } branch tag: ${subject}"
      violations=$((violations + 1))
    fi
  done <<<"${commits}"

  if (( violations > 0 )); then
    echo
    echo "Expected subject form: ${expected}"
    echo "Reword the commits (git rebase -i, reword) and force-push the PR branch."
    return 1
  fi
  note "PR title and every commit subject carry a ticket key and the ${tags[0]} tag"
}

main "$@"
