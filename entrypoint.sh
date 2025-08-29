#!/bin/bash

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
    cd k8s/$5/overlays/dev

    kustomize edit set image IMAGE=$4:$RELEASE_VERSION
    echo "Done!!"

    printf "\033[0;32m============> Git push: Branch develop \033[0m\n"
    cd ../..
    git commit -am "$6 has Built a new version: $RELEASE_VERSION"
    git push origin develop

    printf "\033[0;32m============> Merge develop in to release branch \033[0m\n"
    git checkout release
    git merge develop
    git push origin release

elif [[ "$GITOPS_BRANCH" == "homolog" ]]; then
    printf "\033[0;36m================================================================================================================> Condition 2: Homolog environment \033[0m\n"
    printf "\033[0;32m============> Cloning $1 - Branch: release \033[0m\n"
    GITOPS_REPO_FULL_URL="https://$3:x-oauth-basic@$2"
    git clone $GITOPS_REPO_FULL_URL -b develop
    cd $1
    git config --local user.email "action@github.com"
    git config --local user.name "GitHub Action"
    echo "Repo $1 cloned!!!"

    printf "\033[0;32m============> Develop branch Kustomize step - HML Overlay \033[0m\n"
    cd k8s/$5/overlays/homolog

    kustomize edit set image IMAGE=$4:$RELEASE_VERSION
    echo "Done!!"

    printf "\033[0;32m============> Git commit and push \033[0m\n"
    cd ../..
    git commit -am "$6 has Built a new version: $RELEASE_VERSION"
    git push origin develop

    printf "\033[0;32m============> Open PR: develop -> release \033[0m\n"
    export GITHUB_TOKEN=$3
    if gh pr create --head develop --base release -t "[Homolog] Bump $5 to $RELEASE_VERSION by $6" --body "GitHub Actions: Bump $5 to $RELEASE_VERSION by $6"; then
        printf "\033[0;32mPR created successfully\033[0m\n"
    else
        printf "\033[0;33mPR already exists or an error occurred, skipping...\033[0m\n"
    fi

elif [[ "$GITOPS_BRANCH" == "release" ]]; then
    printf "\033[0;36m================================================================================================================> Condition 3: New release (HML and PRD environment) \033[0m\n"
    printf "\033[0;32m============> Cloning $1 - Branch: $GITOPS_BRANCH \033[0m\n"
    GITOPS_REPO_FULL_URL="https://$3:x-oauth-basic@$2"
    git clone $GITOPS_REPO_FULL_URL -b develop
    cd $1
    git config --local user.email "action@github.com"
    git config --local user.name "GitHub Action"
    echo "Repo $1 cloned!!!"

    printf "\033[0;32m============> Develop branch Kustomize step - HML Overlay \033[0m\n"
    cd k8s/$5/overlays/homolog

    kustomize edit set image IMAGE=$4:$RELEASE_VERSION
    echo "Done!!"

    printf "\033[0;32m============> Develop branch Kustomize step - PRD Overlay \033[0m\n"
    cd ../prod

    kustomize edit set image IMAGE=$4:$RELEASE_VERSION
    echo "Done!!"

    printf "\033[0;32m============> Git commit and push: Branch develop \033[0m\n"
    cd ../..
    git commit -am "$6 has Built a new version: $RELEASE_VERSION"
    git push origin develop

    printf "\033[0;32m============> Open PR: develop -> release \033[0m\n"
    export GITHUB_TOKEN=$3
    if gh pr create --head develop --base release -t "[Homolog] Bump $5 to $RELEASE_VERSION by $6" --body "GitHub Actions: Bump $5 to $RELEASE_VERSION by $6"; then
        printf "\033[0;32mPR created successfully\033[0m\n"
    else
        printf "\033[0;33mPR already exists or an error occurred, skipping...\033[0m\n"
    fi

    printf "\033[0;32m============> Open PR: develop -> master \033[0m\n"
    export GITHUB_TOKEN=$3
    if gh pr create --head develop --base master -t "[Production] Bump $5 to $RELEASE_VERSION by $6" --body "GitHub Actions: Bump $5 to $RELEASE_VERSION by $6"; then
        printf "\033[0;32mPR created successfully\033[0m\n"
    else
        printf "\033[0;33mPR already exists or an error occurred, skipping...\033[0m\n"
    fi

fi
