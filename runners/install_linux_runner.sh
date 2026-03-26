#!/usr/bin/env bash
# Install all CI tools + GitHub Actions runner on Ubuntu 24.04
# Runs inside the VM as root. Mirrors GitHub-hosted ubuntu-24.04.
#
# Usage: sudo ./install_linux_runner.sh [runner_version]

set -Eeuo pipefail

RUNNER_VERSION="${1:-2.322.0}"
RUNNER_USER="ci"

export DEBIAN_FRONTEND=noninteractive

log() { echo "[$(date '+%H:%M:%S')] $*"; }

log "Installing CI tools on $(lsb_release -ds)..."

########################################
# System packages
########################################

apt-get update && apt-get upgrade -y
apt-get install -y --no-install-recommends \
    ca-certificates curl wget git git-lfs gnupg sudo lsb-release \
    software-properties-common apt-transport-https \
    openssh-server locales tzdata \
    build-essential gcc g++ gfortran make autoconf automake \
    libtool bison flex pkg-config gettext \
    zip unzip p7zip-full tar zstd pigz aria2 \
    vim jq rsync parallel patchelf shellcheck yamllint \
    libssl-dev libffi-dev libcurl4-openssl-dev libxml2-dev \
    libsqlite3-dev libpq-dev libmysqlclient-dev \
    libreadline-dev libyaml-dev libgdbm-dev libncurses5-dev \
    libz-dev libbz2-dev liblzma-dev libgmp-dev \
    libgd-dev libzip-dev libonig-dev libicu-dev \
    mediainfo imagemagick fakeroot rpm xvfb \
    python3 python3-venv python3-dev python3-pip python3-setuptools \
    net-tools dnsutils iproute2 \
    sqlite3 postgresql-client mysql-client \
    ninja-build ant ruby-full \
    apache2 nginx && \
    systemctl disable --now apache2 || true && \
    systemctl disable --now nginx || true

locale-gen en_US.UTF-8

# Git latest
add-apt-repository ppa:git-core/ppa -y
apt-get update && apt-get install -y git

########################################
# Docker CE
########################################

log "Installing Docker..."
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
chmod a+r /etc/apt/keyrings/docker.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
    $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
apt-get update
apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
usermod -aG docker "$RUNNER_USER"

########################################
# Node.js 20 + 22
########################################

log "Installing Node.js..."
curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
apt-get install -y nodejs
npm install -g yarn corepack n
corepack enable
n 22

########################################
# PHP 8.3 + 8.4
########################################

log "Installing PHP..."
add-apt-repository ppa:ondrej/php -y
apt-get update
apt-get install -y --no-install-recommends \
    php8.3 php8.3-cli php8.3-common \
    php8.3-curl php8.3-mbstring php8.3-xml php8.3-zip \
    php8.3-pgsql php8.3-sqlite3 php8.3-mysql \
    php8.3-bcmath php8.3-gd php8.3-intl php8.3-readline \
    php8.4 php8.4-cli php8.4-common \
    php8.4-curl php8.4-mbstring php8.4-xml php8.4-zip \
    php8.4-pgsql php8.4-sqlite3 php8.4-mysql \
    php8.4-bcmath php8.4-gd php8.4-intl php8.4-readline
curl -sS https://getcomposer.org/installer | php -- --install-dir=/usr/local/bin --filename=composer

########################################
# Java 8, 11, 17, 21, 25
########################################

log "Installing Java..."
apt-get install -y --no-install-recommends \
    openjdk-8-jdk openjdk-11-jdk openjdk-17-jdk openjdk-21-jdk

# Java 25 via Adoptium
mkdir -p /usr/lib/jvm/java-25-temurin-amd64
curl -fsSL "https://api.adoptium.net/v3/binary/latest/25/ga/linux/x64/jdk/hotspot/normal/eclipse" \
    | tar -C /usr/lib/jvm/java-25-temurin-amd64 --strip-components=1 -xz

# Set env vars in profile
cat > /etc/profile.d/java.sh <<'JEOF'
export JAVA_HOME=/usr/lib/jvm/java-17-openjdk-amd64
export JAVA_HOME_8_X64=/usr/lib/jvm/java-8-openjdk-amd64
export JAVA_HOME_11_X64=/usr/lib/jvm/java-11-openjdk-amd64
export JAVA_HOME_17_X64=/usr/lib/jvm/java-17-openjdk-amd64
export JAVA_HOME_21_X64=/usr/lib/jvm/java-21-openjdk-amd64
export JAVA_HOME_25_X64=/usr/lib/jvm/java-25-temurin-amd64
JEOF

########################################
# .NET SDK 8, 9, 10
########################################

log "Installing .NET..."
curl -fsSL https://dot.net/v1/dotnet-install.sh -o /tmp/dotnet-install.sh
chmod +x /tmp/dotnet-install.sh
/tmp/dotnet-install.sh --channel 8.0 --install-dir /usr/share/dotnet
/tmp/dotnet-install.sh --channel 9.0 --install-dir /usr/share/dotnet
/tmp/dotnet-install.sh --channel 10.0 --install-dir /usr/share/dotnet
ln -sf /usr/share/dotnet/dotnet /usr/local/bin/dotnet
rm /tmp/dotnet-install.sh

cat > /etc/profile.d/dotnet.sh <<'DEOF'
export DOTNET_ROOT=/usr/share/dotnet
DEOF

########################################
# Go 1.24
########################################

log "Installing Go..."
curl -fsSL "https://go.dev/dl/go1.24.13.linux-amd64.tar.gz" | tar -C /usr/local -xz

cat > /etc/profile.d/go.sh <<'GEOF'
export GOROOT=/usr/local/go
export GOPATH=$HOME/go
export PATH=$PATH:$GOROOT/bin:$GOPATH/bin
GEOF

########################################
# Rust
########################################

log "Installing Rust..."
sudo -u "$RUNNER_USER" bash -c 'curl --proto "=https" --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --default-toolchain stable'

########################################
# Build tools
########################################

log "Installing build tools..."

# CMake
curl -fsSL "https://github.com/Kitware/CMake/releases/download/v3.31.6/cmake-3.31.6-linux-x86_64.tar.gz" \
    | tar -C /usr/local --strip-components=1 -xz

# Gradle
curl -fsSL "https://services.gradle.org/distributions/gradle-8.14-bin.zip" -o /tmp/gradle.zip
unzip -q /tmp/gradle.zip -d /opt
ln -s /opt/gradle-8.14/bin/gradle /usr/local/bin/gradle
rm /tmp/gradle.zip

# Maven
curl -fsSL "https://dlcdn.apache.org/maven/maven-3/3.9.14/binaries/apache-maven-3.9.14-bin.tar.gz" \
    | tar -C /opt -xz
ln -s /opt/apache-maven-3.9.14/bin/mvn /usr/local/bin/mvn

########################################
# Android SDK
########################################

log "Installing Android SDK..."
export ANDROID_HOME=/usr/local/lib/android/sdk
mkdir -p "${ANDROID_HOME}/cmdline-tools"
curl -fsSL https://dl.google.com/android/repository/commandlinetools-linux-11076708_latest.zip \
    -o /tmp/cmdline-tools.zip
unzip -q /tmp/cmdline-tools.zip -d /tmp/cmdline-tools-extract
mv /tmp/cmdline-tools-extract/cmdline-tools "${ANDROID_HOME}/cmdline-tools/latest"
rm -rf /tmp/cmdline-tools.zip /tmp/cmdline-tools-extract

export PATH="${PATH}:${ANDROID_HOME}/cmdline-tools/latest/bin:${ANDROID_HOME}/platform-tools"
yes | sdkmanager --licenses > /dev/null 2>&1
sdkmanager \
    "platform-tools" \
    "platforms;android-34" "platforms;android-35" "platforms;android-36" \
    "build-tools;34.0.0" "build-tools;35.0.0" "build-tools;35.0.1" \
    "build-tools;36.0.0" "build-tools;36.1.0" \
    "ndk;27.3.13750724" "ndk;28.2.13676358" "ndk;29.0.14206865"

cat > /etc/profile.d/android.sh <<'AEOF'
export ANDROID_HOME=/usr/local/lib/android/sdk
export ANDROID_SDK_ROOT=$ANDROID_HOME
export NDK_HOME=$ANDROID_HOME/ndk/29.0.14206865
export NDK_LATEST_HOME=$ANDROID_HOME/ndk/29.0.14206865
export PATH=$PATH:$ANDROID_HOME/cmdline-tools/latest/bin:$ANDROID_HOME/platform-tools
AEOF

# Make Android SDK accessible to runner user
chown -R "$RUNNER_USER:$RUNNER_USER" "$ANDROID_HOME"

########################################
# CLI tools
########################################

log "Installing CLI tools..."

# GitHub CLI
curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
    | gpg --dearmor -o /etc/apt/keyrings/gh.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/gh.gpg] https://cli.github.com/packages stable main" \
    | tee /etc/apt/sources.list.d/github-cli.list > /dev/null
apt-get update && apt-get install -y gh

# Azure CLI
curl -sL https://aka.ms/InstallAzureCLIDeb | bash

# AWS CLI v2
curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o /tmp/awscli.zip
unzip -q /tmp/awscli.zip -d /tmp
/tmp/aws/install
rm -rf /tmp/awscli.zip /tmp/aws

# Kubectl
curl -fsSL "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl" \
    -o /usr/local/bin/kubectl && chmod +x /usr/local/bin/kubectl

# Helm
curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

# Packer
curl -fsSL https://releases.hashicorp.com/packer/1.15.0/packer_1.15.0_linux_amd64.zip -o /tmp/packer.zip
unzip -q /tmp/packer.zip -d /usr/local/bin
rm /tmp/packer.zip

# Fastlane
gem install fastlane --no-document

########################################
# Browsers
########################################

log "Installing browsers..."
curl -fsSL https://dl.google.com/linux/linux_signing_key.pub \
    | gpg --dearmor -o /etc/apt/keyrings/google-chrome.gpg
echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/google-chrome.gpg] https://dl.google.com/linux/chrome/deb/ stable main" \
    | tee /etc/apt/sources.list.d/google-chrome.list > /dev/null
apt-get update && apt-get install -y google-chrome-stable firefox

# ChromeDriver
CHROME_VERSION=$(google-chrome --version | grep -oP '\d+\.\d+\.\d+')
DRIVER_URL=$(curl -s "https://googlechromelabs.github.io/chrome-for-testing/LATEST_RELEASE_${CHROME_VERSION%%.*}")
curl -fsSL "https://storage.googleapis.com/chrome-for-testing-public/${DRIVER_URL}/linux64/chromedriver-linux64.zip" \
    -o /tmp/chromedriver.zip
unzip -q /tmp/chromedriver.zip -d /tmp
mv /tmp/chromedriver-linux64/chromedriver /usr/local/bin/chromedriver
chmod +x /usr/local/bin/chromedriver
rm -rf /tmp/chromedriver.zip /tmp/chromedriver-linux64

# Geckodriver
curl -fsSL "https://github.com/mozilla/geckodriver/releases/download/v0.36.0/geckodriver-v0.36.0-linux64.tar.gz" \
    | tar -C /usr/local/bin -xz
chmod +x /usr/local/bin/geckodriver

########################################
# Python extras
########################################

pip3 install --break-system-packages pipx ansible
pipx ensurepath

########################################
# GitHub Actions runner binary
########################################

log "Installing GitHub Actions runner v${RUNNER_VERSION}..."
mkdir -p /opt/actions-runner
cd /opt/actions-runner
curl -fsSL "https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/actions-runner-linux-x64-${RUNNER_VERSION}.tar.gz" \
    | tar -xz
chown -R "$RUNNER_USER:$RUNNER_USER" /opt/actions-runner
./bin/installdependencies.sh

########################################
# Cleanup
########################################

apt-get clean
rm -rf /var/lib/apt/lists/* /tmp/*

log "Linux runner setup complete."
