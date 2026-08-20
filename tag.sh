#!/usr/bin/env bash
#
# Cut a release: bump the version tag, push it, and follow the CI build it starts.
#
#   ./tag.sh            # auto-bump; PATCH rolls over to the next MINOR after 99
#   ./tag.sh v0.4.0     # tag current HEAD as v0.4.0 and push
#   ./tag.sh 0.4.0      # leading "v" is added automatically
#
# THE TAG IS THE WHOLE RELEASE PROCESS. There is no "bump version" commit to make:
# .github/workflows/release.yml fires on `v*`, and its first step runs
# scripts/build/set-version.sh with the pushed tag, which stamps pubspec.yaml so
# the built app's version is the tag by construction. pubspec's committed
# `version:` is therefore not the source of truth and is not read here — the
# newest tag is.
#
# Must be run from 'main' (releases are cut from main only), on a clean tree, with
# HEAD already pushed. Those three are checked rather than assumed: a tag names one
# commit forever, and all three failures produce a release that quietly is not what
# the person cutting it was looking at.
#
# Standard SemVer: vMAJOR.MINOR.PATCH, no leading zeros, no upper bound. Auto-bump
# increments PATCH through 99, then increments MINOR and resets PATCH to 1 (for
# example, v0.0.99 -> v0.1.1) — the same rule as the release.sh in the sibling
# repos, so the version history reads the same way across all of them. Bump MAJOR
# by passing the version explicitly, e.g. `./tag.sh 1.0.0`.
#
# After the push, the workflow builds both macOS DMGs (signed + notarized, one per
# `grid` sidecar arch) and publishes a **DRAFT** GitHub Release. A draft ships to
# nobody: the last step is yours, on the Releases page.
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${REPO_ROOT}"

# gh cannot infer this from the remote: the URL is git@github-diego:... — an SSH
# host alias, not github.com — so every gh call has to name the repo.
GH_REPO="autonomous-ai/autonomous-grid-app"
WORKFLOW="release.yml"
BRANCH="main"

die() { echo "tag: $*" >&2; exit 1; }

# --- Guards -----------------------------------------------------------------

current_branch="$(git rev-parse --abbrev-ref HEAD)"
[ "${current_branch}" = "${BRANCH}" ] ||
  die "on '${current_branch}', but releases are cut from '${BRANCH}' only"

# Uncommitted work is not in the commit the tag will name, so it would not be in
# the release either — while looking, from this terminal, exactly like it was.
git diff --quiet && git diff --cached --quiet ||
  die "uncommitted changes — commit or stash them first, or they will not be in the release"

# Tags must come from the remote, not from whatever this clone happens to hold: a
# release cut on another machine (or in another session — several run these repos
# at once) would otherwise be invisible here and this would reuse its number.
echo "tag: fetching tags…"
git fetch --tags --force --quiet origin

git rev-parse --verify --quiet "origin/${BRANCH}" >/dev/null ||
  die "no origin/${BRANCH} — is the remote reachable?"

if [ -n "$(git rev-list "origin/${BRANCH}..HEAD")" ]; then
  die "HEAD is ahead of origin/${BRANCH} — push first, or the tag names a commit only this machine has"
fi
if [ -n "$(git rev-list "HEAD..origin/${BRANCH}")" ]; then
  die "origin/${BRANCH} is ahead of HEAD — pull first, or the release is cut from stale code"
fi

# --- Which version ----------------------------------------------------------

SEMVER='^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$'

if [ $# -gt 1 ]; then
  die "one argument at most (usage: ./tag.sh [v1.2.3])"
elif [ $# -eq 1 ]; then
  TAG="v${1#v}"
  printf '%s' "${TAG}" | grep -Eq "${SEMVER}" ||
    die "'${1}' is not vMAJOR.MINOR.PATCH (no leading zeros)"
else
  latest="$(git tag -l 'v[0-9]*' --sort=-v:refname | head -n 1)"
  if [ -z "${latest}" ]; then
    TAG="v0.0.1"                       # nothing released yet
  else
    printf '%s' "${latest}" | grep -Eq "${SEMVER}" ||
      die "newest tag '${latest}' is not vMAJOR.MINOR.PATCH — pass the next one explicitly"
    IFS=. read -r major minor patch <<<"${latest#v}"
    if [ "${patch}" -lt 99 ]; then
      patch=$((patch + 1))
    else
      minor=$((minor + 1))
      patch=1                          # the rollover lands on .1, not .0
    fi
    TAG="v${major}.${minor}.${patch}"
  fi
  echo "tag: newest is ${latest:-none} → ${TAG}"
fi

# `git tag` would refuse a duplicate anyway, but only after the guards above have
# run and with a message about refs rather than about releases.
git rev-parse --verify --quiet "refs/tags/${TAG}" >/dev/null &&
  die "${TAG} already exists locally"
[ -z "$(git ls-remote --tags origin "refs/tags/${TAG}")" ] ||
  die "${TAG} already exists on the remote"

# --- Cut it -----------------------------------------------------------------

echo "tag: ${TAG} → $(git rev-parse --short HEAD) ($(git log -1 --pretty=%s))"
git tag "${TAG}"

# Push the tag alone. If this fails the local tag is left behind and would block
# the next run with a confusing "already exists locally", so take it back.
if ! git push origin "refs/tags/${TAG}"; then
  git tag -d "${TAG}" >/dev/null
  die "pushing ${TAG} failed — the local tag has been removed, nothing was released"
fi
echo "tag: pushed ${TAG}"

RUNS_URL="https://github.com/${GH_REPO}/actions/workflows/${WORKFLOW}"

# --- Follow the build -------------------------------------------------------
#
# Everything above is the release. This part is a convenience and must never be
# what decides whether the tag was cut, so a missing or logged-out gh prints where
# to look and exits happy.

if ! command -v gh >/dev/null 2>&1; then
  echo "tag: gh is not installed — watch the build at ${RUNS_URL}"
  exit 0
fi
if ! gh auth status >/dev/null 2>&1; then
  echo "tag: gh is not logged in (\`gh auth login\`) — watch the build at ${RUNS_URL}"
  exit 0
fi

# The run is created a few seconds AFTER the push, not with it, so poll for it.
echo -n "tag: waiting for the build to appear"
run_id=""
for _ in $(seq 1 30); do
  run_id="$(gh run list --repo "${GH_REPO}" --workflow "${WORKFLOW}" --limit 20 \
              --json databaseId,headBranch \
              --jq "[.[] | select(.headBranch == \"${TAG}\")] | first | .databaseId" \
              2>/dev/null || true)"
  [ -n "${run_id}" ] && [ "${run_id}" != "null" ] && break
  run_id=""
  echo -n "."
  sleep 2
done
echo

if [ -z "${run_id}" ]; then
  echo "tag: no run for ${TAG} yet — it may still be queuing: ${RUNS_URL}"
  exit 0
fi

echo "tag: watching https://github.com/${GH_REPO}/actions/runs/${run_id}"
if gh run watch "${run_id}" --repo "${GH_REPO}" --exit-status; then
  echo
  echo "tag: ${TAG} built. The release is a DRAFT — publish it at"
  echo "     https://github.com/${GH_REPO}/releases"
else
  echo
  echo "tag: the build failed. The failing steps' logs:"
  gh run view "${run_id}" --repo "${GH_REPO}" --log-failed || true
  echo
  echo "tag: ${TAG} is still pushed. Fix, then cut the next tag — a pushed tag is"
  echo "     not moved (CI, the appcast and anyone who fetched it have seen it)."
  exit 1
fi
