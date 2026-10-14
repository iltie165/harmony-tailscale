SHELL := /bin/bash
.DEFAULT_GOAL := test
.PHONY: lint doctor version test test-ui check build verify-hap

lint:
	./scripts/check-source.sh
	python3 scripts/check-project.py
	python3 scripts/version.py check
	python3 -m unittest discover -s tests -p 'version_test.py'

version:
	python3 scripts/version.py show

doctor:
	./scripts/doctor.sh

test: lint
	./scripts/test-server.sh

test-ui:
	./scripts/test-ui.sh

# Required before release/PR: offline tests plus actual target compilation.
check: test build

build:
	./scripts/build-hap.sh

verify-hap:
	./scripts/verify-hap.sh
