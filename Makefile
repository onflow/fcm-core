.PHONY: snapshot
snapshot:
	FOUNDRY_PROFILE=ci forge snapshot --match-path "test/gas/*.sol"

.PHONY: coverage
coverage:
	forge coverage --report lcov --report summary
	genhtml lcov.info -o coverage --branch-coverage --ignore-errors inconsistent --ignore-errors corrupt
	open coverage/index.html

# CI pipeline

.PHONY: ci
ci: ci-fmt ci-lint ci-snapshot ci-build ci-test

.PHONY: solidity-fmt
ci-fmt:
	FOUNDRY_PROFILE=ci forge fmt --check

.PHONY: solidity-lint
ci-lint:
	FOUNDRY_PROFILE=ci forge lint

.PHONY: solidity-snapshot
ci-snapshot:
	FOUNDRY_PROFILE=ci forge snapshot --match-path "test/gas/*.sol" --check --tolerance 1

.PHONY: solidity-build
ci-build:
	FOUNDRY_PROFILE=ci forge build --sizes

.PHONY: solidity-test
ci-test:
	FOUNDRY_PROFILE=ci forge test
