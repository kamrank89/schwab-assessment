SHELL := /usr/bin/env bash
.SHELLFLAGS := -eu -o pipefail -c
PATH := $(CURDIR)/.tools/bin:$(PATH)

.PHONY: tools tool-versions bootstrap configure-github-variables render-manifests deploy-foundation deploy-platform deploy-workloads verify-smoke verify-hpa verify-failover teardown fmt validate-terraform validate-kubernetes validate-shell validate-workflows validate-grafana validate-tests security-scan validate

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

configure-github-variables:
	./scripts/configure-github-variables.sh --repository "$(GITHUB_REPOSITORY)" --outputs "$(OUTPUTS_FILE)"

render-manifests:
	./scripts/render-manifests.sh --project-id "$(GCP_PROJECT_ID)" --project-number "$(GCP_PROJECT_NUMBER)" \
	  --deployer-email "$(GCP_DEPLOYER_SERVICE_ACCOUNT)" --cluster-admin-email "$(GCP_CLUSTER_ADMIN_EMAIL)" \
	  --app-a-gsa-email "$(APP_A_GSA_EMAIL)" \
	  --grafana-gsa-email "$(GRAFANA_GSA_EMAIL)" --global-ipv4-address "$(GLOBAL_IPV4_ADDRESS)" \
	  --cloud-armor-policy-name "$(CLOUD_ARMOR_POLICY_NAME)" --bigquery-dataset "$(BIGQUERY_DATASET)" \
	  --tls-certificate-name "$(TLS_CERTIFICATE_NAME)"

deploy-foundation:
	./scripts/deploy.sh foundation

deploy-platform:
	./scripts/deploy.sh platform

deploy-workloads:
	./scripts/deploy.sh workloads

verify-smoke:
	./scripts/verify.sh smoke

verify-hpa:
	./scripts/verify.sh hpa --region "$(REGION)" --confirm "$(CONFIRMATION)"

verify-failover:
	./scripts/verify.sh failover --region "$(REGION)" --confirm "$(CONFIRMATION)"

teardown:
	./scripts/teardown.sh --project-id "$(PROJECT_ID)" --confirmation "$(CONFIRMATION)"

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
	bash -n scripts/*.sh tests/*.sh tests/fixtures/*/*
	shellcheck scripts/*.sh tests/*.sh tests/fixtures/*/*

validate-workflows:
	actionlint .github/workflows/*.yml

validate-grafana:
	@find k8s/base/grafana/files/dashboards -type f -name '*.json' -print0 | \
	  xargs -0 -n1 jq empty

validate-tests:
	tests/access-grafana-test.sh
	tests/teardown-preflight-test.sh
	tests/render-manifests-make-test.sh

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

validate: fmt validate-terraform validate-kubernetes validate-shell validate-workflows validate-grafana validate-tests
