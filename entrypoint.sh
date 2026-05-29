#!/bin/bash
set -e

# Seed $RANDOM from /dev/urandom. This container's entrypoint runs as PID 1, so
# bash's default PID-based RANDOM seed is IDENTICAL across concurrently-started
# containers -> the backoff jitter below would collapse and racers would retry
# in lockstep, defeating its purpose. (od + /dev/urandom exist in alpine.)
RANDOM=$(od -An -N2 -tu2 /dev/urandom 2>/dev/null | tr -dc 0-9); : "${RANDOM:=$$}"

# Positional params are safe to assign only when executed (not sourced for tests).
# The test harness sets ENTRYPOINT_TEST_SOURCE=1 under `set -u`; using plain "$1"
# here would cause "unbound variable" because bash sees $1..$6 as unset when
# sourced without arguments. Use ${N-} (dash, not colon-dash) so that an explicit
# empty arg is still preserved in normal execution, while sourcing gets "".
GITOPS_REPO_NAME="${1-}"
GITOPS_REPO_URL="${2-}"
GH_ACCESS_TOKEN="${3-}"
IMAGE_NAME="${4-}"
APP_ID="${5-}"
GITHUB_ACTOR="${6-}"

# --- Logging helpers ---
log_header() { printf "\033[0;36m=> %s\033[0m\n" "$1"; }
log_step()   { printf "\033[0;32m=> %s\033[0m\n" "$1"; }
log_error()  { printf "\033[0;31m=> %s\033[0m\n" "$1"; }
log_warn()   { printf "\033[0;33m=> %s\033[0m\n" "$1"; }

# --- Reusable functions ---
clone_repo() {
  local branch="$1"
  log_step "Cloning ${GITOPS_REPO_NAME} - Branch: ${branch}"
  git clone "https://x-access-token:${GH_ACCESS_TOKEN}@${GITOPS_REPO_URL}" -b "$branch"
  cd "${GITOPS_REPO_NAME}"
  git config --local user.email "action@finaya.tech"
  git config --local user.name "GitHub Action"
  echo "Repo ${GITOPS_REPO_NAME} cloned!!!"
  REPO_ROOT="$(pwd)"
}

apply_kustomize() {
  local overlay="$1"
  local overlay_dir="k8s/${APP_ID}/overlays/${overlay}"
  if [ ! -d "$overlay_dir" ]; then
    log_error "Error: Directory ${overlay_dir} does not exist"
    exit 1
  fi
  cd "$overlay_dir"

  if grep -rql "kind: FinayaApplication" . >/dev/null 2>&1; then
    log_step "FinayaApplication detected - updating image directly"
    local app_file
    app_file=$(grep -rl "kind: FinayaApplication" .)
    yq -i '.spec.image.repository = "'"${IMAGE_NAME}"'" | .spec.image.tag = "'"${RELEASE_VERSION}"'"' "$app_file"
  else
    kustomize edit set image "IMAGE=${IMAGE_NAME}:${RELEASE_VERSION}"
    yq -i 'del(.labels[] | select(.pairs."app.kubernetes.io/version")) | .labels += [{"pairs": {"app.kubernetes.io/version": "'"${RELEASE_VERSION}"'"}, "includeSelectors": false, "includeTemplates": true}]' kustomization.yaml
    kustomize edit set label "app.kubernetes.io/name:${APP_ID}"
    kustomize edit set label "app.kubernetes.io/managed-by:kustomize"
    kustomize edit set label "app.kubernetes.io/created-by-repo:${GITOPS_REPO_NAME}"
    kustomize edit set annotation "finaya.tech/origin:${GITHUB_REPOSITORY}@${GITHUB_REF#refs/*/}"
  fi
  echo "Done!!"
  cd "$REPO_ROOT"
}

create_pr() {
  local head="$1" base="$2" env_name="$3" env_display="$4"
  export GITHUB_TOKEN="${GH_ACCESS_TOKEN}"
  if gh pr create --head "$head" --base "$base" \
    -t "[${env_display}] Deploy ${APP_ID}" \
    --body "**Microservice:** ${APP_ID}
**Environment:** ${env_name}
**Deployed by:** ${GITHUB_ACTOR}
**Branch:** ${head}
**Release version:** ${RELEASE_VERSION}

This PR updates only the ${APP_ID} microservice in the ${env_name,,} environment."; then
    log_step "PR created successfully"
  else
    log_warn "PR already exists or an error occurred, skipping..."
  fi
}

commit_and_push() {
  local branch="$1" message="$2"
  shift 2
  local add_paths=("$@")

  # Explicit `|| return 1` on every step: this function is now invoked from an
  # `if !` in the DEV path, which DISABLES `set -e` inside it and its callees.
  # Without explicit checks a failed add/commit would fall through to a no-op
  # "success". Hardened so it is correct in any calling context.
  git add "${add_paths[@]:-.}" || return 1

  if git diff --cached --quiet; then
    log_warn "No changes to commit - already up to date"   # idempotent: rerun-safe
    return 0
  fi

  git commit -m "$message" || return 1
  git_push_with_retry "$branch" || return 1   # explicit so a later inserted line can't mask it
}

git_push_with_retry() {
  local branch="$1"
  local max_attempts="${GIT_PUSH_MAX_ATTEMPTS:-8}"   # env-overridable for tests
  local attempt base jitter wait_time rebase_exit
  if [ "$max_attempts" -lt 1 ]; then
    log_error "GIT_PUSH_MAX_ATTEMPTS must be >= 1 (got '${max_attempts}')"; return 1
  fi

  for attempt in $(seq 1 "$max_attempts"); do
    if git push origin "$branch"; then
      log_step "Push to '${branch}' succeeded on attempt ${attempt}."
      return 0
    fi
    if [ "$attempt" -lt "$max_attempts" ]; then
      base=$(( 1 << (attempt - 1) )); [ "$base" -gt 16 ] && base=16   # 1,2,4,8,16,16,16
      jitter=$(( RANDOM % 5 ))                                        # 0..4s de-sync racers
      wait_time=$(( base + jitter ))
      log_warn "Push to '${branch}' failed (attempt ${attempt}/${max_attempts}); rebase+retry in ${wait_time}s."
      sleep "$wait_time"
      # Replay our commit on top of the remote tip. `-X theirs`: on a content
      # conflict (only when the SAME service is deployed twice concurrently) keep
      # our replayed commit's value. (During rebase, "theirs" == the commits being
      # replayed == ours.) Different services edit different overlay files -> no
      # conflict -> clean auto-merge. RESIDUAL: same-service concurrent deploys
      # become last-pusher-wins; fully solved only by the single-writer batch
      # (tracked separately). Without a strategy the rebase would CONFLICT and the
      # loop would burn every attempt -> a hard false failure.
      rebase_exit=0
      git pull --rebase -X theirs origin "$branch" || rebase_exit=$?
      if [ "$rebase_exit" -ne 0 ]; then
        log_warn "Rebase failed (exit ${rebase_exit}); aborting to retry from a clean tree."
        # Three non-zero rebase outcomes: (1) network/fetch failure -> no rebase in
        # progress, --abort exits 128 (suppressed), tree unchanged, next attempt retries;
        # (2) mid-rebase conflict -> --abort exits 0, tree restored; (3) other -> same as (2).
        git rebase --abort 2>/dev/null || true
      fi
    fi
  done

  log_error "Push to '${branch}' failed after ${max_attempts} attempts."
  return 1
}

delete_remote_branch_if_exists() {
  local branch="$1"

  if git ls-remote --exit-code --heads origin "$branch" >/dev/null 2>&1; then
    log_warn "Remote branch ${branch} already exists. Deleting..."
    git push origin --delete "$branch"
    log_step "Remote branch ${branch} deleted"
  else
    log_step "Remote branch ${branch} does not exist. Continuing..."
  fi
}

# Mirror develop -> release (a convenience mirror for the next homolog promotion;
# ArgoCD watches develop, NOT release). Returns 0/1. Called inside `if`, so set -e
# is suspended in its body — every step is guarded explicitly.
# `release` is a tracking checkout (no unique local commits), so REBUILD it from
# origin each time (fetch + checkout -B) instead of rebasing -> branch-tip
# conflicts impossible; `-X theirs` resolves the per-file kustomize tag merge.
# HAZARD (pre-existing, accepted): -X theirs makes develop win, so a release-only
# hotfix not yet in develop would be clobbered. In this GitOps flow release tracks
# develop, so this is acceptable; documented so it is not a surprise.
sync_develop_to_release() {
  git fetch origin release                 || { log_warn "fetch release failed";   return 1; }
  git checkout -B release origin/release   || { log_warn "checkout release failed"; return 1; }
  if ! git merge develop -X theirs --no-edit; then
    log_warn "merge develop->release failed; aborting."
    git merge --abort 2>/dev/null || true
    return 1
  fi
  git_push_with_retry release
}

# Unit tests source this file to exercise the functions above WITHOUT running the
# deploy. `return` is valid in a sourced script; when executed normally
# ENTRYPOINT_TEST_SOURCE is unset so we fall through to the deploy logic below.
[ "${ENTRYPOINT_TEST_SOURCE:-0}" = "1" ] && return 0

# --- Main logic ---

if [[ "$GITOPS_BRANCH" == "develop" ]]; then
  log_header "DEV path: ${APP_ID} -> ${RELEASE_VERSION}"
  clone_repo develop
  apply_kustomize dev

  # Primary deployment. Explicit check (not bare under set -e) so we emit a
  # precise, UI-visible diagnostic. commit_and_push returns 0 also on "no
  # changes" (rerun-safe).
  if ! commit_and_push develop "Deploy ${APP_ID} to DEV - version ${RELEASE_VERSION} by ${GITHUB_ACTOR}"; then
    echo "::error title=DEV deploy failed::${APP_ID}: develop manifest NOT updated after retries."
    exit 1
  fi
  log_step "DEV manifest updated (or already current); ArgoCD will roll the image."

  # Secondary mirror. Fatal only on PERSISTENT failure — surfaced as a GitHub
  # annotation + job summary (not just a log line) so on-call can instantly tell
  # "DEV is live, release lagged, safe to rerun" from a real failure.
  if sync_develop_to_release; then
    log_step "develop -> release sync complete."
    exit 0
  fi
  MSG="DEV deploy for ${APP_ID} SUCCEEDED (develop updated; ArgoCD rolling). develop->release sync failed after retries. Safe to rerun (idempotent)."
  echo "::error title=Release-sync lagged (DEV is LIVE)::${MSG}"
  { echo "### ⚠️ ${APP_ID}: DEV is live, release-sync lagged"; echo "$MSG"; } >> "${GITHUB_STEP_SUMMARY:-/dev/null}"
  exit 1

elif [[ "$GITOPS_BRANCH" == "homolog" ]] || [[ "$GITOPS_BRANCH" == "release" ]]; then
  BRANCH_NAME="deploy/homolog/${APP_ID}"
  log_header "Condition 2: Homolog environment"
  clone_repo release

  delete_remote_branch_if_exists "${BRANCH_NAME}"
  
  log_step "Creating individual branch: ${BRANCH_NAME}"
  git checkout -b "${BRANCH_NAME}"

  log_step "Homolog branch Kustomize step - HML Overlay"
  apply_kustomize homolog

  log_step "Git commit and push individual branch"
  commit_and_push "${BRANCH_NAME}" "Deploy ${APP_ID} to HOMOLOG - version ${RELEASE_VERSION} by ${GITHUB_ACTOR}"

  log_step "Open individual PR: ${BRANCH_NAME} -> release"
  create_pr "${BRANCH_NAME}" release "Homolog" "HOMOLOG"
fi

if [[ "$GITOPS_BRANCH" == "release" ]]; then
  BRANCH_NAME="deploy/${GITOPS_BRANCH}/${APP_ID}"
  log_header "Condition 3: New release (HML and PRD environment)"
  clone_repo master

  export GITHUB_TOKEN="${GH_ACCESS_TOKEN}"

  log_step "Returning to release branch for PRD PR"
  git checkout master

  delete_remote_branch_if_exists "${BRANCH_NAME}"

  log_step "Creating branch for PRODUCTION: ${BRANCH_NAME}"
  git checkout -b "${BRANCH_NAME}"

  log_step "Release branch Kustomize step - PRD Overlay"
  apply_kustomize prod

  log_step "Git commit and push PRODUCTION branch"
  commit_and_push "${BRANCH_NAME}" "Deploy ${APP_ID} to PRD - version ${RELEASE_VERSION} by ${GITHUB_ACTOR}" "k8s/${APP_ID}/overlays/prod"

  log_step "Open PR for PRODUCTION: ${BRANCH_NAME} -> master"
  create_pr "${BRANCH_NAME}" master "Production" "PRODUCTION"
fi
