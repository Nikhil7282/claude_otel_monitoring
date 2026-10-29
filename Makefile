# lint only parses config, so placeholders are enough when .env values aren't set.
COMPOSE := OTEL_AUTH_TOKEN=$${OTEL_AUTH_TOKEN:-lint-placeholder} \
	COMPANY_ACCOUNTS=$${COMPANY_ACCOUNTS:-lint@example.com} \
	GRAFANA_ADMIN_PASSWORD=$${GRAFANA_ADMIN_PASSWORD:-lint-placeholder} docker compose -f compose.yaml
SHELLCHECK := docker run --rm -v "$(CURDIR)":/mnt:ro -w /mnt koalaman/shellcheck:v0.10.0

.PHONY: test lint install-test smoke frontdoor

test: lint install-test smoke frontdoor

lint:
	$(COMPOSE) run --rm --no-deps otel-collector validate --config=/etc/otelcol-contrib/config.yaml
	$(COMPOSE) run --rm --no-deps --entrypoint promtool prometheus check config /etc/prometheus/prometheus.yml
	$(SHELLCHECK) install.sh tests/*.sh
	jq empty grafana/dashboards/*.json
	DOMAIN=example.com $(COMPOSE) -f compose.prod.yaml run --rm --no-deps caddy caddy validate --adapter caddyfile --config /etc/caddy/Caddyfile

install-test:
	tests/install_test.sh

smoke:
	tests/smoke.sh

frontdoor:
	tests/frontdoor.sh
