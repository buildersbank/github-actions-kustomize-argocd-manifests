#!/bin/bash

BRANCH_NAME="deploy/$GITOPS_BRANCH/$5"

if [[ "$GITOPS_BRANCH" == "develop" ]]; then
    printf "\033[0;36m================================================================================================================> Condition 1: Develop environment \033[0m\n"
    printf "\033[0;32m============> Cloning $1 - Branch: develop \033[0m\n"
    GITOPS_REPO_FULL_URL="https://$3:x-oauth-basic@$2"
    git clone $GITOPS_REPO_FULL_URL -b develop
    cd $1
    git config --local user.email "action@github.com"
    git config --local user.name "GitHub Action"
    echo "Repo $1 cloned!!!"

    printf "\033[0;32m============> Develop branch Kustomize step - DEV Overlay \033[0m\n"
    if [ ! -d "k8s/$5/overlays/dev" ]; then
        printf "\033[0;31mError: Directory k8s/$5/overlays/dev does not exist\033[0m\n"
        exit 1
    fi
    cd k8s/$5/overlays/dev

    kustomize edit set image IMAGE=$4:$RELEASE_VERSION
    echo "Done!!"

    printf "\033[0;32m============> Git commit and push directly to develop \033[0m\n"
    cd ../../../..
    git add .
    git commit -m "Deploy $5 to DEV - version $RELEASE_VERSION by $6"
    git push origin develop

    printf "\033[0;32m============> Merge develop into release branch \033[0m\n"
    git checkout release
    git merge develop
    git push origin release

elif [[ "$GITOPS_BRANCH" == "homolog" ]] || [[ "$GITOPS_BRANCH" == "release" ]]; then
    BRANCH_NAME="deploy/homolog/$5"
    printf "\033[0;36m================================================================================================================> Condition 2: Homolog environment \033[0m\n"
    printf "\033[0;32m============> Cloning $1 - Branch: release \033[0m\n"
    GITOPS_REPO_FULL_URL="https://$3:x-oauth-basic@$2"
    git clone $GITOPS_REPO_FULL_URL -b release
    cd $1
    git config --local user.email "action@github.com"
    git config --local user.name "GitHub Action"
    echo "Repo $1 cloned!!!"

    printf "\033[0;32m============> Creating individual branch: $BRANCH_NAME \033[0m\n"
    git checkout -b $BRANCH_NAME

    printf "\033[0;32m============> Homolog branch Kustomize step - HML Overlay \033[0m\n"
    if [ ! -d "k8s/$5/overlays/homolog" ]; then
        printf "\033[0;31mError: Directory k8s/$5/overlays/homolog does not exist\033[0m\n"
        exit 1
    fi
    cd k8s/$5/overlays/homolog

    kustomize edit set image IMAGE=$4:$RELEASE_VERSION
    echo "Done!!"

    printf "\033[0;32m============> Git commit and push individual branch \033[0m\n"
    cd ../../../..
    git add .
    git commit -m "Deploy $5 to HOMOLOG - version $RELEASE_VERSION by $6"
    git push origin $BRANCH_NAME

    printf "\033[0;32m============> Open individual PR: $BRANCH_NAME -> release \033[0m\n"
    export GITHUB_TOKEN=$3
    if gh pr create --head $BRANCH_NAME --base release -t "[HOMOLOG] Deploy $5" --body "**Microservice:** $5
**Environment:** Homolog
**Deployed by:** $6
**Branch:** $BRANCH_NAME
**Release version:** $RELEASE_VERSION

This PR updates only the $5 microservice in the homolog environment."; then
        printf "\033[0;32mIndividual PR created successfully\033[0m\n"
    else
        printf "\033[0;33mPR already exists or an error occurred, skipping...\033[0m\n"
    fi
fi

if [[ "$GITOPS_BRANCH" == "release" ]]; then # Alem do nome, isso significa que estamos em uma versao de release (HML e PRD) (eg 2.0.0)
    BRANCH_NAME="deploy/$GITOPS_BRANCH/$5"
    printf "\033[0;36m================================================================================================================> Condition 3: New release (HML and PRD environment) \033[0m\n"
    printf "\033[0;32m============> Cloning $1 - Branch: $GITOPS_BRANCH  \033[0m\n"
    GITOPS_REPO_FULL_URL="https://$3:x-oauth-basic@$2"
    git clone $GITOPS_REPO_FULL_URL -b master
    cd $1
    git config --local user.email "action@github.com"
    git config --local user.name "GitHub Action"
    echo "Repo $1 cloned!!!"

    export GITHUB_TOKEN=$3

    # ============ PR para PRODUÇÃO ============
    printf "\033[0;32m============> Returning to release branch for PRD PR \033[0m\n"
    git checkout master

    printf "\033[0;32m============> Creating branch for PRODUCTION: ${BRANCH_NAME} \033[0m\n"
    git checkout -b ${BRANCH_NAME}

    printf "\033[0;32m============> Release branch Kustomize step - PRD Overlay \033[0m\n"
    if [ ! -d "k8s/$5/overlays/prod" ]; then
        printf "\033[0;31mError: Directory k8s/$5/overlays/prod does not exist\033[0m\n"
        exit 1
    fi
    cd k8s/$5/overlays/prod

    kustomize edit set image IMAGE=$4:$RELEASE_VERSION
    echo "Done!!"

    printf "\033[0;32m============> Git commit and push PRODUCTION branch \033[0m\n"
    cd ../../../..
    git add k8s/$5/overlays/prod
    git commit -m "Deploy $5 to PRD - version $RELEASE_VERSION by $6"
    git push origin ${BRANCH_NAME}

    printf "\033[0;32m============> Open PR for PRODUCTION: ${BRANCH_NAME} -> release \033[0m\n"
    if gh pr create --head ${BRANCH_NAME} --base master -t "[PRODUCTION] Deploy $5" --body "**Microservice:** $5
**Environment:** Production
**Deployed by:** $6
**Branch:** ${BRANCH_NAME}
**Release version:** $RELEASE_VERSION

This PR updates only the $5 microservice in the production environment."; then
        printf "\033[0;32mPR for production created successfully\033[0m\n"
    else
        printf "\033[0;33mPR for production already exists or an error occurred, skipping...\033[0m\n"
    fi

fi
