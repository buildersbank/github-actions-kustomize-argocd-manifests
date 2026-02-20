#!/bin/bash
set -e

GITOPS_REPO_NAME="$1"
GITOPS_REPO_URL="$2"
GH_ACCESS_TOKEN="$3"
IMAGE_NAME="$4"
APP_ID="$5"
GITHUB_ACTOR="$6"

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

# --- Main logic ---

if [[ "$GITOPS_BRANCH" == "develop" ]]; then
  log_header "Condition 1: Develop environment"
  clone_repo develop

  log_step "Develop branch Kustomize step - DEV Overlay"
  apply_kustomize dev

  log_step "Git commit and push directly to develop"
  git add .
  git commit -m "Deploy ${APP_ID} to DEV - version ${RELEASE_VERSION} by ${GITHUB_ACTOR}"
  git push origin develop

  log_step "Merge develop into release branch"
  git checkout release
  git merge develop
  git push origin release

elif [[ "$GITOPS_BRANCH" == "homolog" ]] || [[ "$GITOPS_BRANCH" == "release" ]]; then
  BRANCH_NAME="deploy/homolog/${APP_ID}"
  log_header "Condition 2: Homolog environment"
  clone_repo release

  log_step "Creating individual branch: ${BRANCH_NAME}"
  git checkout -b "${BRANCH_NAME}"

  log_step "Homolog branch Kustomize step - HML Overlay"
  apply_kustomize homolog

  log_step "Git commit and push individual branch"
  git add .
  git commit -m "Deploy ${APP_ID} to HOMOLOG - version ${RELEASE_VERSION} by ${GITHUB_ACTOR}"
  git push origin "${BRANCH_NAME}"

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

  log_step "Creating branch for PRODUCTION: ${BRANCH_NAME}"
  git checkout -b "${BRANCH_NAME}"

  log_step "Release branch Kustomize step - PRD Overlay"
  apply_kustomize prod

  log_step "Git commit and push PRODUCTION branch"
  git add "k8s/${APP_ID}/overlays/prod"
  git commit -m "Deploy ${APP_ID} to PRD - version ${RELEASE_VERSION} by ${GITHUB_ACTOR}"
  git push origin "${BRANCH_NAME}"

  log_step "Open PR for PRODUCTION: ${BRANCH_NAME} -> master"
  create_pr "${BRANCH_NAME}" master "Production" "PRODUCTION"
fi
