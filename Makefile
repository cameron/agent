SHELL := bash
.SHELLFLAGS := -eu -o pipefail -c
.ONESHELL:
.NOTPARALLEL:
.DEFAULT_GOAL := help

REPO_ROOT := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
CHECK_ROOT := $(if $(XDG_STATE_HOME),$(XDG_STATE_HOME),$(HOME)/.local/state)/agent/checks

.PHONY: help build check test

help:
	@printf '%s\n' \
		'Development targets:' \
		'  make build   Build the agent Nix package.' \
		'  make check   Run nix flake check (packages, Go tests, microVM tests).' \
		'  make test    Run native sandboxed specs and microVM checks.'

build:
	@nix build --no-link --print-out-paths "$(REPO_ROOT)#agent"

check:
	@nix flake check --no-build "$(REPO_ROOT)"
	mkdir -p "$(CHECK_ROOT)"
	nix build --impure --out-link "$(CHECK_ROOT)/result" --expr \
	  'let f = builtins.getFlake "$(REPO_ROOT)"; in builtins.attrValues f.checks.$${builtins.currentSystem}'

test: check
