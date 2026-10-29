# platform-infra — local environment tasks
.PHONY: up down cluster secrets argocd apps argocd-ui grafana run-pipeline status lint

CLUSTER   := platform
NAMESPACE := job-pipeline
RELEASE   := job-pipeline
CHART     := charts/job-pipeline
VALUES    := environments/local/values.yaml
KUBECTL   := kubectl --context k3d-$(CLUSTER)
ARGOCD_CHART_VERSION := 10.10.3

up: cluster secrets argocd apps  ## Create the cluster, install Argo CD and let it deploy everything else

cluster:  ## Create the k3d cluster (no-op if it exists)
	@k3d cluster list $(CLUSTER) >/dev/null 2>&1 || k3d cluster create --config k3d/cluster.yaml

secrets:  ## Create namespace and secrets (never stored in Git)
	$(KUBECTL) create namespace $(NAMESPACE) --dry-run=client -o yaml | $(KUBECTL) apply -f -
	@$(KUBECTL) -n $(NAMESPACE) get secret job-pipeline-postgres >/dev/null 2>&1 || { \
		PASSWORD=$$(openssl rand -hex 16); \
		$(KUBECTL) -n $(NAMESPACE) create secret generic job-pipeline-postgres \
			--from-literal=POSTGRES_USER=jobpipeline \
			--from-literal=POSTGRES_PASSWORD=$$PASSWORD \
			--from-literal=POSTGRES_DB=jobpipeline \
			--from-literal=DATABASE_URL=postgresql+psycopg://jobpipeline:$$PASSWORD@$(RELEASE)-postgres:5432/jobpipeline; \
	}
	@if [ -n "$$ANTHROPIC_API_KEY" ]; then \
		$(KUBECTL) -n $(NAMESPACE) create secret generic job-pipeline-anthropic \
			--from-literal=ANTHROPIC_API_KEY="$$ANTHROPIC_API_KEY" --dry-run=client -o yaml | $(KUBECTL) apply -f -; \
	else \
		echo "ANTHROPIC_API_KEY not set: API will run, pipeline runs cannot score jobs"; \
	fi

argocd:  ## Install Argo CD
	helm upgrade --install argocd oci://ghcr.io/argoproj/argo-helm/argo-cd --version $(ARGOCD_CHART_VERSION) \
		--kube-context k3d-$(CLUSTER) -n argocd --create-namespace --wait --timeout 5m

apps:  ## Register monitoring and job-pipeline with Argo CD (Argo CD then deploys them)
	$(KUBECTL) apply -f argocd/monitoring.yaml
	@echo "Waiting for the Prometheus CRDs (job-pipeline uses ServiceMonitor and PrometheusRule)..."
	@until $(KUBECTL) get crd servicemonitors.monitoring.coreos.com prometheusrules.monitoring.coreos.com >/dev/null 2>&1; do sleep 5; done
	$(KUBECTL) wait --for condition=established --timeout=60s \
		crd/servicemonitors.monitoring.coreos.com crd/prometheusrules.monitoring.coreos.com
	$(KUBECTL) apply -f argocd/job-pipeline.yaml

argocd-ui:  ## Open the Argo CD UI on https://localhost:8443 (user: admin)
	@echo "password: $$($(KUBECTL) -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d)"
	$(KUBECTL) -n argocd port-forward svc/argocd-server 8443:443

grafana:  ## Open Grafana on http://localhost:3000 (user: admin)
	@echo "password: $$($(KUBECTL) -n monitoring get secret monitoring-grafana -o jsonpath='{.data.admin-password}' | base64 -d)"
	$(KUBECTL) -n monitoring port-forward svc/monitoring-grafana 3000:80

run-pipeline:  ## Trigger one pipeline run now
	$(KUBECTL) -n $(NAMESPACE) create job --from=cronjob/$(RELEASE)-run $(RELEASE)-manual-$$(date +%s)

status:  ## Show what is running
	$(KUBECTL) -n $(NAMESPACE) get pods,svc,ingress,cronjob,pvc

lint:  ## Lint and render the chart
	helm lint $(CHART) -f $(VALUES)
	helm template $(RELEASE) $(CHART) -f $(VALUES) >/dev/null

down:  ## Delete the cluster and everything in it
	k3d cluster delete $(CLUSTER)
