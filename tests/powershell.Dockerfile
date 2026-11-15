# PowerShell with Pester and PSScriptAnalyzer, for testing and linting windows_install.ps1
# on any machine. Built once by the Makefile and then served from Docker's cache.
# Microsoft's PowerShell images are amd64-only, and under emulation on Apple silicon module
# installs hang, so this installs the official release for the build machine's architecture.
FROM ubuntu:24.04
ARG TARGETARCH
ARG PWSH_VERSION=7.4.6
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl libicu74 unzip \
 && rm -rf /var/lib/apt/lists/* \
 && case "$TARGETARCH" in arm64) arch=arm64 ;; *) arch=x64 ;; esac \
 && mkdir -p /opt/microsoft/powershell \
 && curl -fsSL "https://github.com/PowerShell/PowerShell/releases/download/v${PWSH_VERSION}/powershell-${PWSH_VERSION}-linux-${arch}.tar.gz" \
    | tar -xz -C /opt/microsoft/powershell \
 && chmod +x /opt/microsoft/powershell/pwsh \
 && ln -s /opt/microsoft/powershell/pwsh /usr/local/bin/pwsh
# Modules straight from the PowerShell Gallery's package URLs, pinned, without PowerShellGet.
RUN for module in Pester/5.6.1 PSScriptAnalyzer/1.23.0; do \
      name=${module%/*}; version=${module#*/}; \
      dir=/opt/microsoft/powershell/Modules/$name/$version; mkdir -p "$dir"; \
      curl -fsSL -o /tmp/m.zip "https://www.powershellgallery.com/api/v2/package/$name/$version" \
      && unzip -q /tmp/m.zip -d "$dir" && rm /tmp/m.zip; \
    done \
 && pwsh -NoProfile -Command "Import-Module Pester -RequiredVersion 5.6.1; Import-Module PSScriptAnalyzer -RequiredVersion 1.23.0"
