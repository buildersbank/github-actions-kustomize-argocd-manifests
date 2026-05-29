# Container image that runs your code
FROM alpine:3.10

#install all dependencies
ENV KUSTOMIZE_VER 5.3.0
RUN apk add --update --no-cache bash
RUN apk add git curl --update --no-cache bash
RUN curl -L --silent https://github.com/kubernetes-sigs/kustomize/releases/download/kustomize%2Fv${KUSTOMIZE_VER}/kustomize_v${KUSTOMIZE_VER}_linux_amd64.tar.gz -o ./kustomize.tar.gz
RUN tar -xf kustomize.tar.gz -C /usr/bin/ && chmod +x /usr/bin/kustomize
# yq pinned + checksum-verified (was releases/latest = non-reproducible). See build-deploy#53.
ENV YQ_VERSION 4.44.3
ENV YQ_SHA256 a2c097180dd884a8d50c956ee16a9cec070f30a7947cf4ebf87d5f36213e9ed7
RUN wget -q https://github.com/mikefarah/yq/releases/download/v${YQ_VERSION}/yq_linux_amd64 -O /usr/local/bin/yq \
 && echo "${YQ_SHA256}  /usr/local/bin/yq" | sha256sum -c - \
 && chmod +x /usr/local/bin/yq
                    
RUN wget https://github.com/cli/cli/releases/download/v1.0.0/gh_1.0.0_linux_386.tar.gz -O ghcli.tar.gz
RUN tar --strip-components=1 -xf ghcli.tar.gz

# Copies your code file from your action repository to the filesystem path `/` of the container
COPY entrypoint.sh /entrypoint.sh

# Code file to execute when the docker container starts up (`entrypoint.sh`)
ENTRYPOINT ["/entrypoint.sh"]
