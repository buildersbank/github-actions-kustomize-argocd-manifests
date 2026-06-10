# Container image that runs your code
FROM alpine:3.20

#install all dependencies
ENV KUSTOMIZE_VER=5.3.0
ENV GH_VER=2.62.0

RUN apk add --update --no-cache bash git curl wget jq

RUN curl -L --silent https://github.com/kubernetes-sigs/kustomize/releases/download/kustomize%2Fv${KUSTOMIZE_VER}/kustomize_v${KUSTOMIZE_VER}_linux_amd64.tar.gz -o ./kustomize.tar.gz \
  && tar -xf kustomize.tar.gz -C /usr/bin/ && chmod +x /usr/bin/kustomize && rm kustomize.tar.gz

RUN wget -q https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64 -O /usr/local/bin/yq \
  && chmod +x /usr/local/bin/yq

RUN wget -q https://github.com/cli/cli/releases/download/v${GH_VER}/gh_${GH_VER}_linux_amd64.tar.gz -O ghcli.tar.gz \
  && tar --strip-components=1 -xf ghcli.tar.gz -C /usr/local \
  && rm ghcli.tar.gz

# Copies your code file from your action repository to the filesystem path `/` of the container
COPY entrypoint.sh /entrypoint.sh

# Code file to execute when the docker container starts up (`entrypoint.sh`)
ENTRYPOINT ["/entrypoint.sh"]
