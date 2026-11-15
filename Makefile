# lint only parses config, so placeholders are enough when .env values aren't set.
COMPOSE := OTEL_AUTH_TOKEN=$${OTEL_AUTH_TOKEN:-lint-placeholder} \
	COMPANY_ACCOUNTS=$${COMPANY_ACCOUNTS:-lint@example.com} \
	GRAFANA_ADMIN_PASSWORD=$${GRAFANA_ADMIN_PASSWORD:-lint-placeholder} docker compose -f compose.yaml
SHELLCHECK := docker run --rm -v "$(CURDIR)":/mnt:ro -w /mnt koalaman/shellcheck:v0.10.0
# PowerShell with Pester and PSScriptAnalyzer (tests/powershell.Dockerfile), built once.
PWSH_IMAGE := claude-otel-pwsh-test:pester-5.6.1
PWSH := docker run --rm -v "$(CURDIR)":/mnt:ro -w /mnt $(PWSH_IMAGE) pwsh -NoProfile -Command

.PHONY: test test-k8s lint mac-install-test windows-install-test pwsh-image smoke frontdoor-nginx

test: lint mac-install-test windows-install-test smoke frontdoor-nginx

lint: pwsh-image
	$(COMPOSE) run --rm --no-deps otel-collector validate --config=/etc/otelcol-contrib/config.yaml
	$(COMPOSE) run --rm --no-deps --entrypoint promtool prometheus check config /etc/prometheus/prometheus.yml
	$(SHELLCHECK) mac_install.sh tests/*.sh nginx/*.sh
	jq empty grafana/dashboards/*.json
	$(PWSH) '$$found = foreach ($$f in "windows_install.ps1", "tests/windows_install.Tests.ps1") { Invoke-ScriptAnalyzer -Path $$f -Settings tests/PSScriptAnalyzerSettings.psd1 }; if ($$found) { $$found | Format-Table -AutoSize | Out-String -Width 200; exit 1 }'
	DOMAIN=example.com $(COMPOSE) -f compose.nginx.yaml config --quiet
	tests/k8s_lint.sh

mac-install-test:
	tests/mac_install_test.sh

windows-install-test: pwsh-image
	$(PWSH) '$$c = New-PesterConfiguration; $$c.Run.Path = "tests/windows_install.Tests.ps1"; $$c.Run.Exit = $$true; $$c.Output.Verbosity = "Detailed"; Invoke-Pester -Configuration $$c'

pwsh-image:
	docker build -q -t $(PWSH_IMAGE) -f tests/powershell.Dockerfile tests >/dev/null

smoke:
	tests/smoke.sh

frontdoor-nginx:
	tests/frontdoor-nginx.sh

# The Kubernetes path end to end in a throwaway kind cluster. A few minutes; not in make test.
test-k8s:
	tests/k8s_e2e.sh
