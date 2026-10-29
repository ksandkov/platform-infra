# platform-infra

Infrastructure that runs [job-pipeline](https://github.com/ksandkov/job-pipeline) on Kubernetes.
job-pipeline builds and publishes a container image; this repo decides where and how that image runs.

```
job-pipeline repo                      platform-infra repo (this one)
─────────────────                      ──────────────────────────────
push → CI: test → build image  ──────► Helm chart pins the image tag (a commit SHA)
       ghcr.io/ksandkov/job-pipeline        │
                                            ▼
                                       Argo CD watches main and syncs the cluster
                                            │
                                            ▼
                                       k3d cluster (local)
                                        ├─ Deployment   api (uvicorn), probes on /healthz and /readyz
                                        ├─ CronJob      `jobpipeline run` every 6h
                                        ├─ Job          `alembic upgrade head` after each release
                                        ├─ StatefulSet  Postgres 16 with a persistent volume (demo only, see below)
                                        ├─ Ingress      http://job-pipeline.localhost:8080
                                        └─ monitoring   Prometheus, Grafana, Alertmanager (kube-prometheus-stack)
```

## Roadmap

Progress is tracked by working checkpoints, not dates. Each stage ends with its own commit, checks and a README update.

| Stage | Checkpoint | State |
|---|---|---|
| 1 | Local cluster: `make up` builds everything from scratch, `make down` removes it | done |
| 2 | Helm + Postgres: app reachable, probes correct, migrations run, data survives a Postgres restart | done |
| 3 | CI: a broken chart cannot pass; the real GHCR image deploys into a throwaway cluster | done |
| 4 | Argo CD: the app is deployed from Git, manual changes in the cluster are reverted | done |
| 5 | Monitoring: Prometheus and Grafana show API metrics, one alert fires in a test scenario | done |
| 6 | Terraform: one EC2 instance with k3s on AWS, `apply` and `destroy` | done |

## Run it

Requires Docker, `k3d`, `helm` and `kubectl`.

```bash
make up                      # cluster + secrets + Argo CD, which then deploys the app from Git
make status                  # what is running
make argocd-ui               # Argo CD UI on https://localhost:8443 (user: admin)
make grafana                 # Grafana on http://localhost:3000 (user: admin)
open http://job-pipeline.localhost:8080/
make run-pipeline            # trigger one pipeline run now
make lint                    # the same chart checks as CI
make down                    # delete the cluster
```

Set `ANTHROPIC_API_KEY` in your shell before `make up` (or re-run `make secrets`) to let pipeline runs score jobs.

Argo CD deploys what is on the `main` branch on GitHub, not local files: a chart change reaches the cluster after it is pushed.

## Cloud: k3s on EC2

`terraform/` creates one EC2 instance (`t3.small`, Ubuntu 24.04) in the default VPC of `us-east-1`. On first boot
it installs k3s. Requires Terraform, the AWS CLI with credentials (`aws configure`) and `~/.ssh/id_ed25519.pub`.

```bash
cd terraform
terraform init
terraform apply -var="my_ip=$(curl -s https://checkip.amazonaws.com)/32"
ssh ubuntu@<public_ip> kubectl get nodes     # the command is printed as the ssh_command output
terraform destroy -var="my_ip=$(curl -s https://checkip.amazonaws.com)/32"
```

Only SSH is open, and only from `my_ip`. `kubectl` is run on the instance over SSH; the Kubernetes API is not exposed.

## CI

`.github/workflows/ci.yml` runs on every push and pull request:

1. **lint**: `helm lint --strict`, then the rendered manifests are validated against Kubernetes schemas with `kubeconform -strict`.
2. **smoke**: installs the chart into a throwaway kind cluster using the real image from GHCR, waits for the
   migration hook, then checks `/healthz`, `/readyz` and `/jobs`.

The lint job was checked against deliberately broken charts. Each one was rejected:

| Broken chart | Caught by |
|---|---|
| Misspelled field (`contianerPort`) | kubeconform |
| Wrong type (`replicas: two`) | kubeconform |
| Template syntax error | helm lint |

## Verified behaviour

- `make down && make up` brings everything back from nothing with no manual steps.
- **Data survives a Postgres restart**: a row was inserted, the `postgres-0` pod was deleted and recreated
  (new UID), and the row was still returned by `/jobs`. The API reconnected on its own.
- **Argo CD reverts manual changes**: the API Deployment was scaled to 0 with `kubectl`, and Argo CD set it back to 1 replica within seconds.
- **Prometheus scrapes the API** (target `job-pipeline-api` is `up`), and its metrics can be queried in Grafana.
- **The alert fires**: the API process was killed with `kubectl exec ... kill 1`, the container restarted, and
  `JobPipelineApiRestarted` went to `firing` in Prometheus and reached Alertmanager. The only other firing alert is
  `Watchdog`, which is meant to fire all the time to show that alerting works.
- **Terraform creates and removes the cloud node**: `terraform apply` created the instance, security group and key pair;
  about two minutes later `kubectl get nodes` over SSH showed the node `Ready` with the system pods running;
  `terraform destroy` removed all three resources.

## Design decisions

- **GitOps with Argo CD.** The cluster state is described in Git; Argo CD applies it and undoes manual changes.
  The only things applied by hand are the cluster, the Secrets and the Argo CD Application itself (`make up`).
- **Monitoring with kube-prometheus-stack**, installed by Argo CD like the app. The chart adds a ServiceMonitor
  (scrape the API's `/metrics`) and one alert rule. k3s runs the scheduler, controller manager, proxy and etcd in a
  single process, so their scrape targets are disabled; otherwise their "target down" alerts would fire forever.
- **No secrets in Git.** The chart only references Secrets by name (`existingSecret`).
  `make secrets` creates them: database credentials with a random password and a ready-made `DATABASE_URL`,
  and, if present, the Anthropic key from the environment. In production this would be Sealed Secrets or External Secrets.
- **Image pinned by commit SHA**, not `latest`. A new app version is a one-line change to `appVersion` in a PR,
  and rolling back is a `git revert`.
- **Migrations as a post-install/post-upgrade hook.** Post, not pre, because the in-cluster Postgres is part of the same release and has to exist first. An init container waits for the database. Argo CD runs this hook after every sync (`PostSync`); `alembic upgrade head` is safe to repeat.
- **Liveness vs readiness.** `/healthz` never touches the database, so a database outage does not restart the API; `/readyz` does, so traffic only arrives once Postgres is reachable.
- **Hardened app pods.** Non-root UID 10001 (matching the image), read-only root filesystem with an `emptyDir` for `/tmp`, all capabilities dropped, `RuntimeDefault` seccomp.
- **`concurrencyPolicy: Forbid`** on the CronJob, so a slow scrape never overlaps with the next run.
- **Terraform kept minimal.** The default VPC instead of a custom network, and one variable (`my_ip`).
  State is a local file and is not committed (it can contain secrets); in a team it would live in an S3 bucket.
  Provider and k3s versions are pinned, and `.terraform.lock.hcl` is committed.

## Postgres: demo, not production

The in-cluster Postgres is a single pod with a local-path volume and no backups. That is fine for a local
cluster and a demo, and it is **not** production-ready.

For production the options are a managed database (RDS) or keeping Postgres in the cluster with scheduled
`pg_dump` backups to S3 and a documented restore.

## What broke and how I fixed it

- **The CI image was amd64-only**, so it could not run on an arm64 (Apple Silicon) k3d node.
  At first `make image` rebuilt the pinned commit locally and imported it into k3d. The proper fix was in
  job-pipeline CI: it now publishes a multi-arch image (amd64 + arm64), and every cluster pulls the same image from GHCR.
- **`jobpipeline run` failed in the container image** with `FileNotFoundError`: `scoring/prompts/system.md`
  was not included in the installed package. Fixed in job-pipeline by declaring it as package data.
- **Then `jobpipeline run` failed with `TypeError: ... unexpected keyword argument 'temperature'`.** The anthropic SDK
  dropped that argument in 1.0, and the unpinned dependency pulled 1.x into the image. Fixed in job-pipeline by
  pinning `anthropic<1`.
- **The migration Job hung in `Init`.** `pg_isready` printed `no attempt`: the pod runs as UID 10001,
  which has no `/etc/passwd` entry in the postgres image, so it could not derive a user name. Passing `-U` explicitly fixed it.

## Known issues (in job-pipeline, not fixed here)

- **Pipeline metrics are not scrapeable.** `jobs_fetched_total`, `pipeline_errors_total` and the other pipeline
  metrics live in the short-lived CronJob process; the API's `/metrics` only exposes default process metrics.
  Monitoring in stage 5 covers the API only.
- **Builds are not reproducible.** Dependencies use `>=` ranges without a lock file, so rebuilding the same commit
  later pulls newer versions. The anthropic break above is an example; a lock file would prevent it.
