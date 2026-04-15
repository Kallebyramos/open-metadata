# OpenMetadata on Kubernetes — Study Guide

## Table of Contents

1. [What is OpenMetadata?](#1-what-is-openmetadata)
2. [Architecture Overview](#2-architecture-overview)
3. [Kubernetes Concepts Used in This Project](#3-kubernetes-concepts-used-in-this-project)
   - [Namespace](#namespace)
   - [Pod](#pod)
   - [Deployment & ReplicaSet](#deployment--replicaset)
   - [StatefulSet](#statefulset)
   - [Service](#service)
   - [PersistentVolume (PV) & PersistentVolumeClaim (PVC)](#persistentvolume-pv--persistentvolumeclaim-pvc)
   - [Secrets](#secrets)
   - [Init Containers](#init-containers)
   - [Liveness & Readiness Probes](#liveness--readiness-probes)
   - [Jobs](#jobs)
4. [Helm Charts](#4-helm-charts)
5. [Airflow on Kubernetes](#5-airflow-on-kubernetes)
6. [OpenMetadata + Airflow Integration](#6-openmetadata--airflow-integration)
7. [Data Quality Workflow](#7-data-quality-workflow)
8. [Common kubectl Commands](#8-common-kubectl-commands)

---

## 1. What is OpenMetadata?

OpenMetadata is an open-source **metadata management platform**. It centralizes metadata from across your data ecosystem so that data teams can:

- **Discover** data assets (tables, dashboards, pipelines, ML models)
- **Understand** data through descriptions, tags, and ownership
- **Trust** data via lineage graphs and data quality scores
- **Govern** data with access policies and classifications

### Core concepts

| Concept | Description |
|---------|-------------|
| **Service** | A connection to a data source (e.g. MySQL, Snowflake, dbt) |
| **Entity** | Any tracked asset: table, column, dashboard, pipeline, etc. |
| **Ingestion pipeline** | A job that crawls a service and populates OM with metadata |
| **Lineage** | A graph showing how data flows from source to destination |
| **Data Quality test** | A rule applied to a table/column (e.g. "no nulls in `id`") |
| **Glossary** | Business vocabulary linked to technical assets |

---

## 2. Architecture Overview

```
┌──────────────────────────────────────────────────────────┐
│  Namespace: openmetadata                                   │
│                                                            │
│  ┌──────────────────┐  REST API  ┌─────────────────────┐  │
│  │  OpenMetadata    │◄──────────►│  Apache Airflow 3   │  │
│  │  Server 1.12.5   │            │  (api-server)        │  │
│  │  :8585           │            │  :8080               │  │
│  └────────┬─────────┘            └──────────┬──────────┘  │
│           │                                 │             │
│           ▼                                 ▼             │
│  ┌────────────────┐             ┌──────────────────────┐  │
│  │  MySQL 8       │             │  MySQL 8             │  │
│  │  openmetadata  │             │  airflow_db          │  │
│  │  _db           │             │                      │  │
│  └────────────────┘             └──────────────────────┘  │
│                                                            │
│  ┌────────────────────────────────────────────────────┐   │
│  │  OpenSearch 2  (search index + lineage graph)      │   │
│  └────────────────────────────────────────────────────┘   │
└──────────────────────────────────────────────────────────┘
```

### Component responsibilities

| Component | Role |
|-----------|------|
| **openmetadata server** | REST API + UI. Stores all metadata in MySQL, indexes into OpenSearch |
| **MySQL** | Relational store for OM entities and Airflow task metadata |
| **OpenSearch** | Full-text search index and lineage graph storage |
| **Airflow api-server** | Receives DAG trigger requests from OM, executes ingestion pipelines |
| **Airflow scheduler** | Polls for DAGs to run, dispatches tasks to the executor |
| **Airflow dag-processor** | Parses DAG files from the PVC |
| **Airflow triggerer** | Handles deferrable operators (async tasks) |

---

## 3. Kubernetes Concepts Used in This Project

### Namespace

A **namespace** is a logical partition inside a Kubernetes cluster. All resources in this project live in the `openmetadata` namespace.

```bash
kubectl get pods -n openmetadata        # list pods in this namespace
kubectl get all -n openmetadata         # list everything
```

Why namespaces matter: they isolate resources, allow per-namespace RBAC, and prevent name collisions with other applications on the same cluster.

---

### Pod

A **pod** is the smallest deployable unit in Kubernetes — it wraps one or more containers that share network and storage.

```bash
kubectl describe pod <name> -n openmetadata   # full pod details
kubectl logs <name> -n openmetadata           # stdout/stderr
kubectl exec -it <name> -n openmetadata -- bash  # shell into a container
```

**Pod phases:**

| Phase | Meaning |
|-------|---------|
| `Pending` | Scheduled but not yet running (waiting for image pull or PVC) |
| `Init:0/1` | Init containers are running/waiting |
| `Running` | At least one container is running |
| `CrashLoopBackOff` | Container keeps crashing; Kubernetes backs off retries |
| `Completed` | All containers exited with code 0 (typical for Jobs) |

---

### Deployment & ReplicaSet

A **Deployment** declares the desired state for a stateless application: which image to run, how many replicas, resource limits, etc.

Kubernetes creates a **ReplicaSet** (the actual set of pods) to fulfil the Deployment's spec. When you update a Deployment (e.g. new image tag), it creates a new ReplicaSet and performs a rolling update — replacing pods one by one.

In this project:
- `openmetadata` (OM server) is a Deployment with `replicaCount: 1`
- `openmetadata-dependencies-api-server` (Airflow api-server) is a Deployment

```bash
kubectl get deployments -n openmetadata
kubectl rollout status deployment/openmetadata -n openmetadata
```

---

### StatefulSet

A **StatefulSet** is like a Deployment but for stateful applications. The key differences:

| Feature | Deployment | StatefulSet |
|---------|-----------|-------------|
| Pod names | Random suffix (`abc-xyz`) | Stable ordinal (`mysql-0`, `mysql-1`) |
| Storage | Shared or ephemeral | Each pod gets its own PVC |
| Startup order | Parallel | Sequential (0 before 1) |
| DNS | Not stable | Stable (`mysql-0.mysql-headless`) |

In this project: `mysql`, `opensearch`, `openmetadata-dependencies-scheduler`, and `openmetadata-dependencies-triggerer` are all StatefulSets — they need stable identity and dedicated storage.

---

### Service

A **Service** gives a stable DNS name and virtual IP to a set of pods, so other pods can reach them without knowing individual pod IPs (which change on restart).

Types used here:

| Type | Behaviour |
|------|-----------|
| `ClusterIP` | Only reachable inside the cluster. Default for all services here. |
| `NodePort` | Exposes a port on every node (used for `kubectl port-forward` targets) |

Service DNS format inside the cluster:
```
<service-name>.<namespace>.svc.cluster.local
# short form within same namespace:
<service-name>
```

That is why `host: mysql` works in our config — the `mysql` service resolves inside the `openmetadata` namespace.

```bash
kubectl get svc -n openmetadata
```

---

### PersistentVolume (PV) & PersistentVolumeClaim (PVC)

Containers are ephemeral — when a pod restarts, its filesystem is wiped. **PersistentVolumes** solve this by providing durable storage that outlives pods.

**PV (PersistentVolume):** A piece of storage provisioned in the cluster (e.g. a directory on the node, an NFS share, a cloud disk). It exists independently of any pod.

**PVC (PersistentVolumeClaim):** A request for storage by a workload. A PVC says "I need 5Gi with ReadWriteOnce access." Kubernetes binds it to a matching PV.

```
Pod → PVC → PV → actual storage (disk/NFS/cloud)
```

**Access modes:**

| Mode | Abbreviation | Meaning |
|------|-------------|---------|
| `ReadWriteOnce` | RWO | One node can read+write at a time |
| `ReadWriteMany` | RWX | Multiple nodes can read+write simultaneously |
| `ReadOnlyMany` | ROX | Multiple nodes can read simultaneously |

In this project, kind uses the **local-path provisioner** which only supports `ReadWriteOnce`. This is why we disabled logs persistence (Airflow defaults to `ReadWriteMany` for logs, expecting multiple workers on different nodes).

**PVCs in this project:**

| PVC | Used by | Size |
|-----|---------|------|
| `data-mysql-0` | MySQL data directory | 5Gi |
| `opensearch-opensearch-0` | OpenSearch index data | 5Gi |
| `openmetadata-dependencies-dags` | Airflow DAG files (shared between scheduler & dag-processor) | 2Gi |

```bash
kubectl get pvc -n openmetadata
kubectl describe pvc <name> -n openmetadata
```

---

### Secrets

A **Secret** stores sensitive data (passwords, tokens, keys) as base64-encoded values. Pods consume them as environment variables or mounted files.

In this project, `k8s/secrets.yaml` defines three secrets:

| Secret | Keys | Used by |
|--------|------|---------|
| `mysql-secrets` | `openmetadata-mysql-password` | OM server → MySQL auth |
| `airflow-secrets` | `openmetadata-airflow-password` | OM server → Airflow auth |
| `airflow-mysql-secrets` | `connection` | Airflow → MySQL connection string |

```bash
kubectl get secrets -n openmetadata
kubectl get secret mysql-secrets -n openmetadata -o jsonpath='{.data}' | base64 -d
```

> Secrets are only base64-encoded, not encrypted, by default. For production use Vault, Sealed Secrets, or External Secrets Operator.

---

### Init Containers

**Init containers** run to completion before the main containers start. They are used to:
- Wait for a dependency to be ready
- Run database migrations
- Pre-populate a volume

In this project, every Airflow pod has a `wait-for-airflow-migrations` init container that runs:
```bash
airflow db check-migrations --migration-wait-timeout=60
```

It polls the database until Airflow's schema is fully migrated, then exits — allowing the main container to start. This is why all Airflow pods stay in `Init:0/1` until you run `make migrate-airflow`.

```bash
# Check init container logs
kubectl logs <pod> -c wait-for-airflow-migrations -n openmetadata

# Exec into a running init container
kubectl exec <pod> -c wait-for-airflow-migrations -n openmetadata -- airflow db migrate
```

---

### Liveness & Readiness Probes

Probes are health checks that Kubernetes runs against containers automatically.

**Readiness probe** — "Is this container ready to receive traffic?"
- Failing: Kubernetes removes the pod from Service endpoints (traffic stops going to it)
- Passing: Pod is added back to rotation

**Liveness probe** — "Is this container still alive?"
- Failing: Kubernetes kills and restarts the container

In `om-values.yaml`:
```yaml
readinessProbe:
  initialDelaySeconds: 60   # wait 60s before first check (OM takes time to boot)
  periodSeconds: 15          # check every 15s
  failureThreshold: 10       # restart after 10 consecutive failures

livenessProbe:
  initialDelaySeconds: 80   # longer delay — liveness fires after readiness
  periodSeconds: 30
  failureThreshold: 5
```

`initialDelaySeconds` matters a lot here — OpenMetadata takes ~60-90 seconds to boot. Setting it too low causes `CrashLoopBackOff` even when the app is healthy.

```bash
# See probe results in pod events
kubectl describe pod <openmetadata-pod> -n openmetadata | grep -A5 "Liveness\|Readiness"
```

---

### Jobs

A **Job** runs a pod to completion (exit code 0) and then stops. Unlike Deployments, Jobs are not restarted after success.

Common uses:
- Database migrations (`airflow db migrate`)
- One-time data seeding
- Batch processing

In this project, the Airflow Helm chart is supposed to create a migration Job automatically, but due to chart version behaviour it doesn't — so `make migrate-airflow` substitutes for it by exec'ing into the init container directly.

```bash
kubectl get jobs -n openmetadata
kubectl logs job/<name> -n openmetadata
```

---

## 4. Helm Charts

**Helm** is the package manager for Kubernetes. A **chart** is a collection of YAML templates + a `values.yaml` with defaults.

### Charts used

| Chart | What it deploys |
|-------|----------------|
| `open-metadata/openmetadata-dependencies` | MySQL + OpenSearch + Airflow (all bundled) |
| `open-metadata/openmetadata` | The OM server |

### Values files

You override chart defaults in a `values.yaml` file passed with `--values`:

```bash
helm install <release> <chart> --values helm/deps-values.yaml
helm upgrade <release> <chart> --values helm/deps-values.yaml
```

### Useful Helm commands

```bash
helm list -n openmetadata                          # installed releases
helm get values openmetadata-dependencies -n openmetadata  # effective values
helm get manifest openmetadata -n openmetadata     # rendered K8s manifests
helm history openmetadata -n openmetadata          # revision history
helm rollback openmetadata 1 -n openmetadata       # roll back to revision 1
```

---

## 5. Airflow on Kubernetes

### Airflow 3 architecture

Airflow 3 split the old monolithic **webserver** into two components:

| Component | Role |
|-----------|------|
| **api-server** | REST API + new React UI. Replaces the old Flask webserver. |
| **dag-processor** | Parses and validates DAG files. Runs independently. |
| **scheduler** | Decides when tasks should run, submits them to the executor. |
| **triggerer** | Manages deferrable operators (async waiting). |

### Executors

An **executor** controls how tasks are run:

| Executor | Where tasks run | When to use |
|----------|----------------|-------------|
| `LocalExecutor` | Subprocess of the scheduler | Local dev, single-node |
| `CeleryExecutor` | Distributed Celery workers | Production, multi-node |
| `KubernetesExecutor` | Individual K8s pods per task | Cloud-native production |

We use `LocalExecutor` — it requires no extra infrastructure (no Redis, no worker nodes) and is perfect for a local kind cluster.

### DAG persistence

Airflow reads DAG files from a directory. The `openmetadata-dependencies-dags` PVC is mounted at `/opt/airflow/dags` in both the dag-processor and scheduler. When OM creates an ingestion pipeline, it writes a DAG file to this PVC, and Airflow picks it up automatically.

---

## 6. OpenMetadata + Airflow Integration

When you create an ingestion pipeline in the OM UI:

1. OM generates a Python DAG file and writes it to the shared DAGs PVC
2. OM calls the Airflow REST API (`POST /api/v2/dags/{dag_id}/dagRuns`) to trigger a run
3. Airflow executes the DAG, which uses the `openmetadata-managed-apis` plugin (pre-installed in the `openmetadata/ingestion` image)
4. The plugin calls back to OM's REST API with results (metadata, lineage, quality test results)

The OM ingestion image (`openmetadata/ingestion:1.12.5`) is used as the Airflow image — it ships Python, the Airflow binaries, and all OM connector libraries in one image.

### Key configuration in om-values.yaml

```yaml
pipelineServiceClientConfig:
  apiEndpoint: "http://openmetadata-dependencies-api-server:8080"  # Airflow REST API
  metadataApiEndpoint: "http://openmetadata:8585/api"              # OM API (Airflow calls back here)
```

Both endpoints must be reachable from inside the cluster. This is why we use Kubernetes service names, not `localhost`.

---

## 7. Data Quality Workflow

1. **Add a service** — Settings → Services → Add Service (e.g. MySQL, PostgreSQL)
2. **Run metadata ingestion** — OM creates a DAG in Airflow, executes it, and populates tables/columns/schemas
3. **Add data quality tests** — Navigate to a table → Quality → Add Test
   - Examples: `columnValuesToBeNotNull`, `tableRowCountToBeBetween`, `columnValuesToMatchRegex`
4. **Schedule tests** — OM triggers Airflow DAG runs on your chosen schedule
5. **View results** — Results appear in the OM UI under the table's Quality tab with pass/fail history
6. **Set up alerts** — Configure webhooks or email notifications on test failures

### Test types

| Category | Example tests |
|----------|---------------|
| **Table** | `tableRowCountToBeBetween`, `tableColumnCountToEqual` |
| **Column** | `columnValuesToBeNotNull`, `columnValuesToBeBetween`, `columnValuesToBeUnique` |
| **Custom SQL** | Write any SQL expression that returns a boolean |

---

## 8. Common kubectl Commands

```bash
# Pods
kubectl get pods -n openmetadata -o wide
kubectl describe pod <name> -n openmetadata
kubectl logs <name> -n openmetadata -f --tail=100
kubectl logs <name> -c <container> -n openmetadata   # specific container
kubectl exec -it <name> -n openmetadata -- bash

# Services & networking
kubectl get svc -n openmetadata
kubectl port-forward svc/openmetadata 8585:8585 -n openmetadata

# Storage
kubectl get pvc -n openmetadata
kubectl describe pvc <name> -n openmetadata

# Events (great for debugging pending pods)
kubectl get events -n openmetadata --sort-by='.lastTimestamp'

# Resources
kubectl top pods -n openmetadata    # requires metrics-server
kubectl describe node               # node capacity and allocations

# Helm
helm list -n openmetadata
helm get values <release> -n openmetadata
helm upgrade <release> <chart> --values <file> -n openmetadata
```
