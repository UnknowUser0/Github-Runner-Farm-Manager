FROM ubuntu:24.04

ARG DEBIAN_FRONTEND=noninteractive
ARG MANAGER_VERSION=1.0.0
ARG TARGETARCH=amd64

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

LABEL org.opencontainers.image.title="GitHub Runner Farm Universal Ubuntu Worker" \
      org.opencontainers.image.description="Ephemeral universal GitHub Actions self-hosted runner with isolated Docker-in-Docker" \
      org.opencontainers.image.source="https://github.com/SkyTeamExec/Github-Runner-Farm-Manager" \
      org.opencontainers.image.version="${MANAGER_VERSION}" \
      org.opencontainers.image.licenses="MIT"

ENV TZ=Etc/UTC \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    HOME=/home/runner \
    RUNNER_TOOL_CACHE=/opt/hostedtoolcache \
    AGENT_TOOLSDIRECTORY=/opt/hostedtoolcache \
    ANDROID_HOME=/opt/android-sdk \
    ANDROID_SDK_ROOT=/opt/android-sdk \
    DOTNET_ROOT=/opt/dotnet \
    RUSTUP_HOME=/opt/rustup \
    CARGO_HOME=/opt/cargo \
    BUN_INSTALL=/opt/bun \
    DENO_INSTALL=/opt/deno \
    PATH=/opt/android-sdk/cmdline-tools/latest/bin:/opt/android-sdk/platform-tools:/opt/dotnet:/opt/cargo/bin:/opt/bun/bin:/opt/deno/bin:/opt/go/bin:/opt/gradle/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

RUN test "$TARGETARCH" = "amd64" || (echo "v1.0.0 currently supports linux/amd64 only" >&2; exit 2)

RUN apt-get update && apt-get install -y --no-install-recommends \
    apt-transport-https bash bc bison build-essential ca-certificates ccache clang clang-format clang-tidy \
    cmake coreutils curl dnsutils file flex g++ gcc gettext git git-lfs gnupg gzip iproute2 iputils-ping \
    jq less libbz2-dev libffi-dev libgdbm-dev libicu-dev liblzma-dev libncurses-dev libreadline-dev \
    libsqlite3-dev libssl-dev libtool libxml2-dev libxslt1-dev libyaml-dev lld llvm locales make meson \
    netcat-openbsd ninja-build openssh-client openssl patch pkg-config procps protobuf-compiler rsync \
    shellcheck socat sqlite3 sudo tar time tzdata unzip uuid-runtime wget xz-utils zip zlib1g-dev \
    python3 python3-dev python3-pip python3-venv pipx \
    openjdk-17-jdk openjdk-21-jdk maven \
    php-cli php-curl php-mbstring php-xml php-zip \
    ruby-full \
    postgresql-client redis-tools default-mysql-client \
    ffmpeg imagemagick \
    fuse-overlayfs iptables uidmap dbus-user-session slirp4netns \
    && locale-gen en_US.UTF-8 \
    && git lfs install --system \
    && rm -rf /var/lib/apt/lists/*

# Docker Engine + Compose + Buildx inside every disposable worker.
RUN install -m 0755 -d /etc/apt/keyrings \
    && curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc \
    && chmod a+r /etc/apt/keyrings/docker.asc \
    && echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu noble stable" > /etc/apt/sources.list.d/docker.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin \
    && rm -rf /var/lib/apt/lists/*

# GitHub CLI.
RUN curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg -o /usr/share/keyrings/githubcli-archive-keyring.gpg \
    && chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=amd64 signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" > /etc/apt/sources.list.d/github-cli.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends gh \
    && rm -rf /var/lib/apt/lists/*

# Node.js current patch from the v24 LTS line + npm/pnpm/yarn.
RUN NODE_VERSION="$(curl -fsSL https://nodejs.org/dist/index.json | jq -r '[.[] | select((.version | startswith("v24.")) and (.lts != false))][0].version')" \
    && test -n "$NODE_VERSION" -a "$NODE_VERSION" != "null" \
    && cd /tmp \
    && curl -fsSLO "https://nodejs.org/dist/${NODE_VERSION}/node-${NODE_VERSION}-linux-x64.tar.xz" \
    && curl -fsSLO "https://nodejs.org/dist/${NODE_VERSION}/SHASUMS256.txt" \
    && grep " node-${NODE_VERSION}-linux-x64.tar.xz$" SHASUMS256.txt | sha256sum -c - \
    && tar -xJf "node-${NODE_VERSION}-linux-x64.tar.xz" -C /usr/local --strip-components=1 \
    && rm -f node-*.tar.xz SHASUMS256.txt \
    && npm install -g npm@latest pnpm@latest yarn@latest corepack@latest \
    && corepack enable

# Bun and Deno.
RUN curl -fsSL https://bun.sh/install | bash \
    && ln -sf /opt/bun/bin/bun /usr/local/bin/bun \
    && curl -fsSL https://deno.land/install.sh | sh \
    && ln -sf /opt/deno/bin/deno /usr/local/bin/deno

# Latest stable Go.
RUN GO_VERSION="$(curl -fsSL 'https://go.dev/VERSION?m=text' | head -n1)" \
    && test -n "$GO_VERSION" \
    && curl -fsSL "https://go.dev/dl/${GO_VERSION}.linux-amd64.tar.gz" -o /tmp/go.tar.gz \
    && rm -rf /opt/go \
    && tar -C /opt -xzf /tmp/go.tar.gz \
    && ln -sf /opt/go/bin/go /usr/local/bin/go \
    && ln -sf /opt/go/bin/gofmt /usr/local/bin/gofmt \
    && rm -f /tmp/go.tar.gz

# Rust stable + Cargo + rustfmt + clippy.
RUN mkdir -p /opt/rustup /opt/cargo \
    && curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs -o /tmp/rustup.sh \
    && RUSTUP_HOME=/opt/rustup CARGO_HOME=/opt/cargo sh /tmp/rustup.sh -y --profile default --default-toolchain stable \
    && rm -f /tmp/rustup.sh \
    && chmod -R a+rX /opt/rustup /opt/cargo

# .NET 10 LTS.
RUN mkdir -p /opt/dotnet \
    && curl -fsSL https://dot.net/v1/dotnet-install.sh -o /tmp/dotnet-install.sh \
    && bash /tmp/dotnet-install.sh --channel 10.0 --architecture x64 --install-dir /opt/dotnet \
    && rm -f /tmp/dotnet-install.sh \
    && ln -sf /opt/dotnet/dotnet /usr/local/bin/dotnet

# Current Gradle release.
RUN GRADLE_JSON="$(curl -fsSL https://services.gradle.org/versions/current)" \
    && GRADLE_URL="$(jq -r '.downloadUrl' <<<"$GRADLE_JSON")" \
    && GRADLE_VERSION="$(jq -r '.version' <<<"$GRADLE_JSON")" \
    && curl -fsSL "$GRADLE_URL" -o /tmp/gradle.zip \
    && unzip -q /tmp/gradle.zip -d /opt \
    && mv "/opt/gradle-${GRADLE_VERSION}" /opt/gradle \
    && ln -sf /opt/gradle/bin/gradle /usr/local/bin/gradle \
    && rm -f /tmp/gradle.zip

# Composer + Bundler.
RUN curl -fsSL https://getcomposer.org/installer -o /tmp/composer-setup.php \
    && php /tmp/composer-setup.php --quiet --install-dir=/usr/local/bin --filename=composer \
    && rm -f /tmp/composer-setup.php \
    && gem install bundler --no-document

# Android command-line SDK, platform tools, stable API 36 and build tools.
RUN mkdir -p /opt/android-sdk/cmdline-tools /tmp/android-cmdline \
    && curl -fsSL https://dl.google.com/android/repository/commandlinetools-linux-15859902_latest.zip -o /tmp/android-tools.zip \
    && unzip -q /tmp/android-tools.zip -d /tmp/android-cmdline \
    && mv /tmp/android-cmdline/cmdline-tools /opt/android-sdk/cmdline-tools/latest \
    && yes | /opt/android-sdk/cmdline-tools/latest/bin/sdkmanager --licenses >/dev/null \
    && /opt/android-sdk/cmdline-tools/latest/bin/sdkmanager \
         "platform-tools" \
         "platforms;android-36" \
         "build-tools;36.0.0" \
    && rm -rf /tmp/android-tools.zip /tmp/android-cmdline

# Common cloud/infrastructure CLIs: kubectl, Helm, Terraform, AWS CLI v2 and yq.
RUN KUBECTL_VERSION="$(curl -fsSL https://dl.k8s.io/release/stable.txt)" \
    && curl -fsSL "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl" -o /usr/local/bin/kubectl \
    && curl -fsSL "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl.sha256" -o /tmp/kubectl.sha256 \
    && echo "$(cat /tmp/kubectl.sha256)  /usr/local/bin/kubectl" | sha256sum -c - \
    && chmod +x /usr/local/bin/kubectl \
    && rm -f /tmp/kubectl.sha256 \
    && HELM_VERSION="$(curl -fsSL https://api.github.com/repos/helm/helm/releases/latest | jq -r '.tag_name')" \
    && curl -fsSL "https://get.helm.sh/helm-${HELM_VERSION}-linux-amd64.tar.gz" -o /tmp/helm.tar.gz \
    && tar -xzf /tmp/helm.tar.gz -C /tmp \
    && install -m 0755 /tmp/linux-amd64/helm /usr/local/bin/helm \
    && rm -rf /tmp/helm.tar.gz /tmp/linux-amd64 \
    && TERRAFORM_VERSION="$(curl -fsSL https://api.github.com/repos/hashicorp/terraform/releases/latest | jq -r '.tag_name' | sed 's/^v//')" \
    && curl -fsSL "https://releases.hashicorp.com/terraform/${TERRAFORM_VERSION}/terraform_${TERRAFORM_VERSION}_linux_amd64.zip" -o /tmp/terraform.zip \
    && unzip -q /tmp/terraform.zip -d /usr/local/bin \
    && rm -f /tmp/terraform.zip \
    && curl -fsSL https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip -o /tmp/awscliv2.zip \
    && unzip -q /tmp/awscliv2.zip -d /tmp \
    && /tmp/aws/install \
    && rm -rf /tmp/aws /tmp/awscliv2.zip \
    && YQ_VERSION="$(curl -fsSL https://api.github.com/repos/mikefarah/yq/releases/latest | jq -r '.tag_name')" \
    && curl -fsSL "https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}/yq_linux_amd64" -o /usr/local/bin/yq \
    && chmod +x /usr/local/bin/yq

# Google Chrome stable for browser/frontend CI.
RUN curl -fsSL https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb -o /tmp/google-chrome.deb \
    && apt-get update \
    && apt-get install -y --no-install-recommends /tmp/google-chrome.deb \
    && rm -f /tmp/google-chrome.deb \
    && rm -rf /var/lib/apt/lists/*

# Bake the latest GitHub Actions runner. The worker entrypoint can replace it at
# runtime when a target repo/org is still on a different progressive-rollout version.
RUN RUNNER_VERSION="$(curl -fsSL https://api.github.com/repos/actions/runner/releases/latest | jq -r '.tag_name' | sed 's/^v//')" \
    && test -n "$RUNNER_VERSION" \
    && mkdir -p /opt/actions-runner \
    && curl -fsSL "https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/actions-runner-linux-x64-${RUNNER_VERSION}.tar.gz" -o /tmp/runner.tar.gz \
    && tar -xzf /tmp/runner.tar.gz -C /opt/actions-runner \
    && printf '%s\n' "$RUNNER_VERSION" > /opt/actions-runner/.runner-version \
    && rm -f /tmp/runner.tar.gz

RUN useradd --create-home --shell /bin/bash runner \
    && usermod -aG docker runner \
    && echo 'runner ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/runner \
    && chmod 0440 /etc/sudoers.d/runner \
    && mkdir -p /opt/hostedtoolcache /home/runner/.cache \
    && chown -R runner:runner /opt/actions-runner /opt/hostedtoolcache /home/runner \
    && chmod -R a+rX /opt/android-sdk /opt/dotnet /opt/go /opt/gradle /opt/bun /opt/deno /opt/rustup /opt/cargo

COPY entrypoint.sh /usr/local/bin/runner-entrypoint
RUN chmod 0755 /usr/local/bin/runner-entrypoint

WORKDIR /runner
ENTRYPOINT ["/usr/local/bin/runner-entrypoint"]
