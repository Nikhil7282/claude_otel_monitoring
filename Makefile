COMPOSE := docker compose -f compose.yaml
SHELLCHECK := docker run --rm -v "$(CURDIR)":/mnt:ro -w /mnt koalaman/shellcheck:v0.10.0

.PHONY: test lint install-test smoke

test: lint install-test smoke

lint:
	$(COMPOSE) run --rm --no-deps otel-collector validate --config=/etc/otelcol-contrib/config.yaml
	$(COMPOSE) run --rm --no-deps --entrypoint promtool prometheus check config /etc/prometheus/prometheus.yml
	$(SHELLCHECK) install.sh tests/*.sh

install-test:
	tests/install_test.sh

smoke:
	tests/smoke.sh
