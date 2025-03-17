FROM alpine:3.18

# Define versions
ARG HELM_VERSION="v3.12.2"
ARG AWS_CLI_VERSION="2.15.2"
ARG KUBECTL_VERSION="v1.28.3"
ARG JQ_VERSION="1.6"

# Install dependencies
RUN apk add --no-cache \
    curl \
    tar \
    gzip \
    bash \
    git \
    unzip \
    wget \
    jq

# Copy install script
COPY install.sh /install.sh
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /install.sh /entrypoint.sh && /install.sh

# Clean up
RUN rm -rf /var/cache/apk/*

# Set PATH
ENV PATH="/usr/local/bin:$PATH"

# Set entrypoint script
ENTRYPOINT ["/entrypoint.sh"]
