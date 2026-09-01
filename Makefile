SHELL := /usr/bin/env bash
.SHELLFLAGS := -eu -o pipefail -c
PATH := $(CURDIR)/.tools/bin:$(PATH)

.PHONY: tools tool-versions bootstrap fmt validate-terraform validate-kubernetes validate-shell validate-workflows validate-grafana security-scan validate

tools:
	./scripts/install-tools.sh

tool-versions:
	terraform version
	kubectl version --client=true --output=yaml | awk '/^[[:space:]]*gitVersion:/ { print $$2; found = 1; exit } END { exit !found }'
	kustomize version
	kubeconform -v
	jq --version
	shellcheck --version
	actionlint -version
	crane version

bootstrap:
	./scripts/bootstrap.sh --project-id "$(PROJECT_ID)" --state-bucket "$(STATE_BUCKET)" \
	  --github-repository "$(GITHUB_REPOSITORY)" --github-owner-id "$(GITHUB_OWNER_ID)" \
	  --github-repository-id "$(GITHUB_REPOSITORY_ID)"

fmt:
	terraform fmt -check -recursive infra

validate-terraform:
	@for root in infra/bootstrap infra/foundation infra/platform; do \
	  terraform -chdir=$$root init -backend=false; \
	  terraform -chdir=$$root validate; \
	done

validate-kubernetes:
	@for overlay in k8s/access/us-central1 k8s/access/us-east1 k8s/access/config-us-central1 k8s/overlays/us-central1 k8s/overlays/us-east1 k8s/overlays/config-us-central1/http k8s/overlays/config-us-central1/tls k8s/overlays/config-us-central1/https; do \
	  kustomize build $$overlay | kubeconform -strict -summary -ignore-missing-schemas; \
	done

validate-shell:
	bash -n scripts/*.sh
	shellcheck scripts/*.sh

validate-workflows:
	actionlint .github/workflows/*.yml

validate-grafana:
	@find k8s/base/grafana/files/dashboards -type f -name '*.json' -print0 | \
	  xargs -0 -n1 jq empty

security-scan:
	@if ! command -v trivy >/dev/null; then \
	  echo "Trivy is optional and not installed; skipping advisory security scan."; \
	  exit 0; \
	fi; \
	trivy config --severity HIGH,CRITICAL infra; \
	trivy config --severity HIGH,CRITICAL k8s; \
	set -a; source tools/images.env; set +a; \
	  for image in "$$APP_A_IMAGE" "$$APP_B_IMAGE" "$$GRAFANA_IMAGE"; do \
	    trivy image --ignore-unfixed --severity HIGH,CRITICAL "$$image"; \
	  done

validate: fmt validate-terraform validate-kubernetes validate-shell validate-workflows validate-grafana
