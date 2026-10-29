# lint only parses config, so a placeholder token is enough when none is set.
COMPOSE := OTEL_AUTH_TOKEN=$${OTEL_AUTH_TOKEN:-lint-placeholder} docker compose -f compose.yaml

.PHONY: test lint smoke

test: lint smoke

lint:
	$(COMPOSE) run --rm --no-deps otel-collector validate --config=/etc/otelcol-contrib/config.yaml
	$(COMPOSE) run --rm --no-deps --entrypoint promtool prometheus check config /etc/prometheus/prometheus.yml

smoke:
	tests/smoke.sh
