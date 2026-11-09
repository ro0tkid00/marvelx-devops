FROM alpine:3.22

ARG TARGETARCH
ARG TOFU_VERSION=1.13.8
ARG KUBECTL_VERSION=1.37.2
ARG HELM_VERSION=4.3.1

RUN apk add --no-cache bash ca-certificates curl docker-cli git jq

WORKDIR /tmp/tools
RUN set -eux; \
    tofu="tofu_${TOFU_VERSION}_linux_${TARGETARCH}.tar.gz"; \
    curl -fsSLO "https://github.com/opentofu/opentofu/releases/download/v${TOFU_VERSION}/${tofu}"; \
    curl -fsSLO "https://github.com/opentofu/opentofu/releases/download/v${TOFU_VERSION}/tofu_${TOFU_VERSION}_SHA256SUMS"; \
    grep " ${tofu}\$" "tofu_${TOFU_VERSION}_SHA256SUMS" | sha256sum -c -; \
    tar -xzf "${tofu}" -C /usr/local/bin tofu; \
    \
    curl -fsSLo /usr/local/bin/kubectl "https://dl.k8s.io/release/v${KUBECTL_VERSION}/bin/linux/${TARGETARCH}/kubectl"; \
    echo "$(curl -fsSL "https://dl.k8s.io/release/v${KUBECTL_VERSION}/bin/linux/${TARGETARCH}/kubectl.sha256")  /usr/local/bin/kubectl" | sha256sum -c -; \
    chmod +x /usr/local/bin/kubectl; \
    \
    helm="helm-v${HELM_VERSION}-linux-${TARGETARCH}.tar.gz"; \
    curl -fsSLO "https://get.helm.sh/${helm}"; \
    echo "$(curl -fsSL "https://get.helm.sh/${helm}.sha256sum" | cut -d' ' -f1)  ${helm}" | sha256sum -c -; \
    tar -xzf "${helm}" --strip-components=1 -C /usr/local/bin "linux-${TARGETARCH}/helm"; \
    \
    cd / && rm -rf /tmp/tools; \
    tofu version; kubectl version --client; helm version

WORKDIR /
