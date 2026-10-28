# platform-infra

Infrastructure that runs [job-pipeline](https://github.com/ksandkov/job-pipeline) on Kubernetes.
job-pipeline builds and publishes a container image; this repo decides where and how that image runs.

```
job-pipeline repo                      platform-infra repo (this one)
─────────────────                      ──────────────────────────────
push → CI: test → build image  ──────► Helm chart pins the image tag (a commit SHA)
       ghcr.io/ksandkov/job-pipeline        │
                                            ▼
                                       k3d cluster (local)
                                        ├─ Deployment   api (uvicorn), probes on /healthz and /readyz
                                        ├─ CronJob      `jobpipeline run` every 6h
                                        ├─ Job          `alembic upgrade head` after each release
                                        ├─ StatefulSet  Postgres 16 with a persistent volume (demo only, see below)
                                        └─ Ingress      http://job-pipeline.localhost:8080
```

## Roadmap

Progress is tracked by working checkpoints, not dates. Each stage ends with its own commit, checks and a README update.

| Stage | Checkpoint | State |
|---|---|---|
| 1 | Local cluster: `make up` builds everything from scratch, `make down` removes it | done |
| 2 | Helm + Postgres: app reachable, probes correct, migrations run, data survives a Postgres restart | done |
| 3 | CI: a broken chart cannot pass; the real GHCR image deploys into a throwaway cluster | done |
| 4 | Argo CD: changing the image version in Git deploys it, `git revert` rolls back, manual changes are reverted | planned |
| 5 | Monitoring: Prometheus and Grafana show API metrics, one alert fires in a test scenario | planned |
| 6 | Terraform: one EC2 instance with k3s on AWS, `apply` and `destroy` | planned |

## Run it

Requires Docker, `k3d`, `helm` and `kubectl`.

```bash
make up                      # cluster + secrets + Helm release, image pulled from GHCR
make status                  # what is running
open http://job-pipeline.localhost:8080/
make run-pipeline            # trigger one pipeline run now
make lint                    # the same chart checks as CI
make down                    # delete the cluster
```

Set `ANTHROPIC_API_KEY` in your shell before `make up` (or re-run `make secrets`) to let pipeline runs score jobs.

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

## Design decisions

- **No secrets in Git.** The chart only references Secrets by name (`existingSecret`).
  `make secrets` creates them: database credentials with a random password and a ready-made `DATABASE_URL`,
  and, if present, the Anthropic key from the environment. In production this would be Sealed Secrets or External Secrets.
- **Image pinned by commit SHA**, not `latest`. A new app version is a one-line change to `appVersion` in a PR,
  and rolling back is a `git revert`.
- **Migrations as a post-install/post-upgrade hook.** Post, not pre, because the in-cluster Postgres is part of the same release and has to exist first. An init container waits for the database.
- **Liveness vs readiness.** `/healthz` never touches the database, so a database outage does not restart the API; `/readyz` does, so traffic only arrives once Postgres is reachable.
- **Hardened app pods.** Non-root UID 10001 (matching the image), read-only root filesystem with an `emptyDir` for `/tmp`, all capabilities dropped, `RuntimeDefault` seccomp.
- **`concurrencyPolicy: Forbid`** on the CronJob, so a slow scrape never overlaps with the next run.

## Postgres: demo, not production

The in-cluster Postgres is a single pod with a local-path volume and no backups. That is fine for a local
cluster and a demo, and it is **not** production-ready.

For the cloud stage the options are a managed database (RDS) or keeping Postgres in the cluster with scheduled
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
