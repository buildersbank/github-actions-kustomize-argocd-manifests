# Container image that runs your code
FROM alpine:3.10

#install all dependencies 
ENV KUSTOMIZE_VER 3.0.0
RUN apk add --update --no-cache bash
RUN apk add git curl --update --no-cache bash
RUN curl -L --silent https://github.com/kubernetes-sigs/kustomize/releases/download/v${KUSTOMIZE_VER}/kustomize_${KUSTOMIZE_VER}_linux_amd64  -o /usr/bin/kustomize && chmod +x /usr/bin/kustomize

# Copies your code file from your action repository to the filesystem path `/` of the container
COPY entrypoint.sh /entrypoint.sh

# Code file to execute when the docker container starts up (`entrypoint.sh`)
ENTRYPOINT ["/entrypoint.sh"]