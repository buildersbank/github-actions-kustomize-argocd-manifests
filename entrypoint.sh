#!/bin/bash
set -e

GITOPS_REPO_NAME="$1"
GITOPS_REPO_URL="$2"
GH_ACCESS_TOKEN="$3"
IMAGE_NAME="$4"
APP_ID="$5"
GITHUB_ACTOR="$6"

# Extract owner and repo from URL (format: github.com/owner/repo)
REPO_OWNER=$(echo "$GITOPS_REPO_URL" | cut -d'/' -f2)
REPO_NAME=$(echo "$GITOPS_REPO_URL" | cut -d'/' -f3 | sed 's/\.git$//')

export GITHUB_TOKEN="${GH_ACCESS_TOKEN}"

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

# Creates a verified commit via GitHub API (commits via API are automatically verified by GitHub Apps).
# Must be called from REPO_ROOT after `git add` has staged the desired changes.
commit_via_api() {
  local branch="$1"
  local message="$2"

  # Parent is the current local HEAD (works for both existing and new branches)
  local parent_sha
  parent_sha=$(git rev-parse HEAD)

  # Get the tree SHA of the parent commit
  local base_tree_sha
  base_tree_sha=$(gh api "repos/${REPO_OWNER}/${REPO_NAME}/git/commits/${parent_sha}" --jq '.tree.sha')

  # Collect staged files
  local changed_files deleted_files
  changed_files=$(git diff --cached --name-only)
  deleted_files=$(git diff --cached --name-only --diff-filter=D)

  # Build tree entries array
  local tree_entries="[]"
  while IFS= read -r file; do
    [ -z "$file" ] && continue
    if echo "$deleted_files" | grep -qx "$file"; then
      # Deletion: set sha to null
      tree_entries=$(echo "$tree_entries" | jq ". + [{\"path\": \"$file\", \"mode\": \"100644\", \"type\": \"blob\", \"sha\": null}]")
    else
      local blob_sha
      blob_sha=$(gh api "repos/${REPO_OWNER}/${REPO_NAME}/git/blobs" \
        -f content="$(base64 -w 0 "$file")" \
        -f encoding="base64" \
        --jq '.sha')
      tree_entries=$(echo "$tree_entries" | jq ". + [{\"path\": \"$file\", \"mode\": \"100644\", \"type\": \"blob\", \"sha\": \"$blob_sha\"}]")
    fi
  done <<< "$changed_files"

  # Create new tree on top of the parent tree
  local new_tree_sha
  new_tree_sha=$(jq -n \
    --arg base "$base_tree_sha" \
    --argjson tree "$tree_entries" \
    '{"base_tree": $base, "tree": $tree}' \
    | gh api "repos/${REPO_OWNER}/${REPO_NAME}/git/trees" --input - --jq '.sha')

  # Create the commit (GitHub App token = automatically verified signature)
  local commit_date new_commit_sha
  commit_date=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  new_commit_sha=$(jq -n \
    --arg msg "$message" \
    --arg tree "$new_tree_sha" \
    --arg parent "$parent_sha" \
    --arg date "$commit_date" \
    '{
      "message": $msg,
      "tree": $tree,
      "parents": [$parent],
      "author":    {"name": "GitHub Action", "email": "action@finaya.tech", "date": $date},
      "committer": {"name": "GitHub Action", "email": "action@finaya.tech", "date": $date}
    }' \
    | gh api "repos/${REPO_OWNER}/${REPO_NAME}/git/commits" --input - --jq '.sha')

  log_step "Verified commit created: ${new_commit_sha}"

  # Create or update the remote ref
  if git ls-remote --exit-code --heads origin "$branch" >/dev/null 2>&1; then
    gh api "repos/${REPO_OWNER}/${REPO_NAME}/git/refs/heads/${branch}" \
      -X PATCH \
      -f sha="$new_commit_sha" \
      -F force=false
  else
    gh api "repos/${REPO_OWNER}/${REPO_NAME}/git/refs" \
      -f ref="refs/heads/${branch}" \
      -f sha="$new_commit_sha"
  fi

  log_step "Branch ${branch} updated on remote"
}

commit_and_push() {
  local branch="$1" message="$2"
  shift 2
  local add_paths=("$@")

  git add "${add_paths[@]:-.}"

  if git diff --cached --quiet; then
    log_warn "No changes to commit - already up to date"
    return 0
  fi

  commit_via_api "$branch" "$message"
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

# --- Main logic ---

if [[ "$GITOPS_BRANCH" == "develop" ]]; then
  log_header "Condition 1: Develop environment"
  clone_repo develop

  log_step "Develop branch Kustomize step - DEV Overlay"
  apply_kustomize dev

  log_step "Git commit and push directly to develop"
  commit_and_push develop "Deploy ${APP_ID} to DEV - version ${RELEASE_VERSION} by ${GITHUB_ACTOR}"

  log_step "Merge develop into release branch via API"
  merge_http_code=$(gh api "repos/${REPO_OWNER}/${REPO_NAME}/merges" \
    -f base="release" \
    -f head="develop" \
    -f commit_message="Merge develop into release after deploying ${APP_ID} ${RELEASE_VERSION}" \
    -w "%{http_code}" -o /dev/null 2>&1 || true)
  if [[ "$merge_http_code" == "409" ]]; then
    log_error "Merge conflict between develop and release - manual resolution required"
    exit 1
  fi
  log_step "develop merged into release (HTTP ${merge_http_code})"

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
