#!/usr/bin/env bash
# Install all CI tools + GitHub Actions runner on macOS
# Run on the macOS VM as an admin user.
#
# Usage: ./install_macos_runner.sh [runner_version]

set -Eeuo pipefail

RUNNER_VERSION="${1:-2.322.0}"

log() { echo "[$(date '+%H:%M:%S')] $*"; }

log "Installing CI tools on macOS $(sw_vers -productVersion)..."

########################################
# Xcode Command Line Tools
########################################

if ! xcode-select -p >/dev/null 2>&1; then
    log "Installing Xcode CLT..."
    xcode-select --install
    # Wait for install to complete
    until xcode-select -p >/dev/null 2>&1; do sleep 5; done
fi

########################################
# Homebrew
########################################

if ! command -v brew >/dev/null 2>&1; then
    log "Installing Homebrew..."
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
fi

eval "$(/opt/homebrew/bin/brew shellenv 2>/dev/null || /usr/local/bin/brew shellenv 2>/dev/null)"

########################################
# Languages and runtimes
########################################

log "Installing languages..."
brew install \
    node@20 \
    node@22 \
    php@8.3 \
    php@8.4 \
    python@3.12 \
    go \
    ruby \
    rust \
    openjdk@17 \
    openjdk@21

# Link default versions
brew link --overwrite node@20

# Corepack + Yarn
corepack enable
npm install -g yarn

# Composer
brew install composer

# .NET
brew install --cask dotnet-sdk

########################################
# Build tools
########################################

log "Installing build tools..."
brew install \
    cmake \
    ninja \
    gradle \
    maven \
    ant

########################################
# Android SDK
########################################

log "Installing Android SDK..."
brew install --cask android-commandlinetools

export ANDROID_HOME="$HOME/Library/Android/sdk"
mkdir -p "$ANDROID_HOME"

yes | sdkmanager --licenses > /dev/null 2>&1
sdkmanager \
    "platform-tools" \
    "platforms;android-34" "platforms;android-35" "platforms;android-36" \
    "build-tools;34.0.0" "build-tools;35.0.0" "build-tools;35.0.1" \
    "build-tools;36.0.0" "build-tools;36.1.0" \
    "ndk;27.3.13750724" "ndk;28.2.13676358" "ndk;29.0.14206865"

########################################
# CLI tools
########################################

log "Installing CLI tools..."
brew install \
    gh \
    awscli \
    azure-cli \
    kubernetes-cli \
    helm \
    packer \
    jq \
    yq

# Fastlane
brew install fastlane

########################################
# Browsers
########################################

log "Installing browsers..."
brew install --cask google-chrome firefox

########################################
# Docker
########################################

log "Installing Docker..."
brew install --cask docker
# Note: Docker Desktop must be started manually once to complete setup

########################################
# Shell environment
########################################

cat >> "$HOME/.zprofile" <<'ZEOF'
# NoMercy Runner environment
export ANDROID_HOME=$HOME/Library/Android/sdk
export ANDROID_SDK_ROOT=$ANDROID_HOME
export NDK_HOME=$ANDROID_HOME/ndk/29.0.14206865
export PATH=$PATH:$ANDROID_HOME/cmdline-tools/latest/bin:$ANDROID_HOME/platform-tools

export JAVA_HOME=$(/usr/libexec/java_home -v 17 2>/dev/null || echo "")
export DOTNET_ROOT=/usr/local/share/dotnet

eval "$(/opt/homebrew/bin/brew shellenv 2>/dev/null || /usr/local/bin/brew shellenv 2>/dev/null)"
ZEOF

########################################
# GitHub Actions runner
########################################

log "Installing GitHub Actions runner v${RUNNER_VERSION}..."
mkdir -p /opt/actions-runner
cd /opt/actions-runner

ARCH=$(uname -m)
case "$ARCH" in
    arm64) RUNNER_ARCH="osx-arm64" ;;
    x86_64) RUNNER_ARCH="osx-x64" ;;
    *) echo "Unsupported arch: $ARCH"; exit 1 ;;
esac

curl -fsSL "https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/actions-runner-${RUNNER_ARCH}-${RUNNER_VERSION}.tar.gz" \
    | tar -xz

log "macOS runner setup complete."
