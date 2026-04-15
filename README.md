# OpenMetadata + Airflow on Kubernetes (local)

Deploy **OpenMetadata 1.12.5** integrated with **Apache Airflow 3.1.7** on a local Kubernetes cluster for practising data quality, lineage, and governance features.

> Airflow 3.1.7 is the version pinned by OM's own `ingestion/setup.py` for the 1.12.x release line — guaranteeing full API and plugin compatibility.

**Docs:**
- [Portfolio — architecture, setup, UI walkthrough & challenges solved](docs/portfolio.md)
- [Study guide — Kubernetes concepts, Helm, Airflow, data quality](docs/openmetadata.md)

---

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│  Namespace: openmetadata                                  │
│                                                           │
│  ┌─────────────────┐   REST API   ┌───────────────────┐  │
│  │  OpenMetadata   │◄────────────►│  Apache Airflow   │  │
│  │  Server 1.12.5  │              │  3.1.7            │  │
│  │  :8585          │              │  (LocalExecutor)  │  │
│  └────────┬────────┘              └────────┬──────────┘  │
│           │                                │             │
│           ▼                                ▼             │
│  ┌────────────────┐              ┌─────────────────────┐ │
│  │  MySQL 8       │              │  MySQL 8            │ │
│  │  (OM metadata) │              │  (Airflow metadata) │ │
│  └────────────────┘              └─────────────────────┘ │
│                                                           │
│  ┌─────────────────────────────────────────────────────┐ │
│  │  OpenSearch 2  (search & lineage index)             │ │
│  └─────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────┘
```

All three backing services (MySQL, OpenSearch, Airflow) are deployed via the official **`openmetadata-dependencies`** Helm chart.

---

## Prerequisites

| Tool | Minimum version | Purpose |
|------|----------------|---------|
| `kubectl` | 1.25+ | Cluster management |
| `helm` | 3.10+ | Chart installation |
| Local K8s cluster | — | See options below |

### Local cluster options

**kind** (recommended — config file already in this repo):
```bash
make cluster
# uses k8s/kind-cluster.yaml
```

**minikube**:
```bash
minikube start --cpus 4 --memory 6144 --disk-size 30g
```

**Docker Desktop**: enable Kubernetes in _Settings → Kubernetes_.

> Minimum resources: **4 vCPU / 6 GB RAM** allocated to the cluster.

---

## Repository layout

```
.
├── helm/
│   ├── deps-values.yaml    # Overrides for openmetadata-dependencies chart
│   └── om-values.yaml      # Overrides for openmetadata chart
├── k8s/
│   ├── kind-cluster.yaml   # kind cluster definition (single node + port mappings)
│   ├── namespace.yaml      # Namespace definition
│   └── secrets.yaml        # Secret templates (edit passwords before applying)
└── Makefile                # Convenience targets
```

---

## Quick start

### 1. Create the kind cluster

```bash
make cluster
```

### 2. Edit the secrets

Open [k8s/secrets.yaml](k8s/secrets.yaml) and replace the example passwords with values of your choice before applying them.

### 3. Run the full setup

```bash
# Add the Helm repo, create the namespace, apply secrets, and deploy dependencies
make setup
```

### 4. Wait for dependency pods to be Ready

```bash
make status
# All pods in the openmetadata namespace should show STATUS=Running
```

This typically takes 3–5 minutes. Wait until you see:
- `openmetadata-dependencies-mysql-*` → Running
- `openmetadata-dependencies-opensearch-*` → Running
- `openmetadata-dependencies-web-*` (Airflow webserver) → Running
- `openmetadata-dependencies-scheduler-*` → Running

### 5. Deploy OpenMetadata

```bash
make om
```

### 6. Access the UIs

Open two separate terminals:

```bash
# Terminal 1 — OpenMetadata UI
make port-forward-om
# → http://localhost:8585   (admin / admin)

# Terminal 2 — Airflow UI
make port-forward-airflow
# → http://localhost:8080   (admin / admin)
```

---

## Data quality workflow

1. **Connect a data source** in the OM UI (Settings → Services → Add Service).
2. **Run metadata ingestion** — OM will create a DAG in Airflow automatically.
3. **Define data quality tests** on a table (Data Quality → Add Test).
4. **Schedule and run tests** — results flow back to the OM UI in real time.
5. **Monitor lineage and quality scores** in the OM Explore view.

---

## Useful commands

| Command | Description |
|---------|-------------|
| `make cluster` | Create the kind cluster |
| `make delete-cluster` | Destroy the kind cluster entirely |
| `make status` | Show all pods in the namespace |
| `make logs-om` | Stream OpenMetadata server logs |
| `make logs-airflow` | Stream Airflow webserver logs |
| `make upgrade-deps` | Upgrade the dependencies release |
| `make upgrade-om` | Upgrade the OpenMetadata release |
| `make clean` | Remove both Helm releases (keeps cluster) |

---

## Version compatibility matrix

| OpenMetadata | Airflow | Helm chart | OM ingestion image |
|-------------|---------|------------|-------------------|
| **1.12.5** | **3.1.7** | `openmetadata-dependencies` latest | `docker.open-metadata.org/openmetadata/ingestion:1.12.5` |

The Airflow version is locked in OM's own [ingestion/setup.py](https://github.com/open-metadata/OpenMetadata/blob/main/ingestion/setup.py) — do not change it independently.

---

## Troubleshooting

**Pods stuck in `Pending`**
- Check node resources: `kubectl describe node`
- Lower resource requests in `helm/deps-values.yaml`

**OM server `CrashLoopBackOff`**
- Check logs: `make logs-om`
- Most common cause: dependencies not yet Ready when OM started. Run `make clean-om && make om` after confirming deps are up.

**Airflow DAGs not appearing after OM ingestion**
- Verify the `pipelineServiceClientConfig.apiEndpoint` in `helm/om-values.yaml` matches the Airflow webserver service name.
- Check OM logs for `PipelineServiceClient` errors.

**OpenSearch index errors**
- The security plugin is disabled in `deps-values.yaml` for local use. If you see 401s, confirm `DISABLE_SECURITY_PLUGIN=true` is set.
