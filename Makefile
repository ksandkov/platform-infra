# platform-infra — local environment tasks
.PHONY: up down cluster image secrets deploy run-pipeline status lint

CLUSTER   := platform
NAMESPACE := job-pipeline
RELEASE   := job-pipeline
CHART     := charts/job-pipeline
VALUES    := environments/local/values.yaml
APP_REPO  := https://github.com/ksandkov/job-pipeline.git
APP_SHA   := $(shell awk -F'"' '/^appVersion:/ {print $$2}' $(CHART)/Chart.yaml)
IMAGE     := ghcr.io/ksandkov/job-pipeline:$(APP_SHA)
KUBECTL   := kubectl --context k3d-$(CLUSTER)

up: cluster image secrets deploy  ## Create the cluster and deploy job-pipeline

cluster:  ## Create the k3d cluster (no-op if it exists)
	@k3d cluster list $(CLUSTER) >/dev/null 2>&1 || k3d cluster create --config k3d/cluster.yaml

image:  ## Build the pinned job-pipeline commit for this machine's arch and load it into k3d
	rm -rf .build/job-pipeline
	git clone --quiet $(APP_REPO) .build/job-pipeline
	git -C .build/job-pipeline checkout --quiet $(APP_SHA)
	docker build -t $(IMAGE) .build/job-pipeline
	k3d image import $(IMAGE) --cluster $(CLUSTER)

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

deploy:  ## Install or upgrade the Helm release
	helm upgrade --install $(RELEASE) $(CHART) --kube-context k3d-$(CLUSTER) \
		-n $(NAMESPACE) -f $(VALUES) --wait --timeout 5m

run-pipeline:  ## Trigger one pipeline run now
	$(KUBECTL) -n $(NAMESPACE) create job --from=cronjob/$(RELEASE)-run $(RELEASE)-manual-$$(date +%s)

status:  ## Show what is running
	$(KUBECTL) -n $(NAMESPACE) get pods,svc,ingress,cronjob,pvc

lint:  ## Lint and render the chart
	helm lint $(CHART) -f $(VALUES)
	helm template $(RELEASE) $(CHART) -f $(VALUES) >/dev/null

down:  ## Delete the cluster and everything in it
	k3d cluster delete $(CLUSTER)
