# =============================================================================
# OpenMetadata + Airflow — local Kubernetes (kind / minikube / Docker Desktop)
#
# Versions:
#   OpenMetadata  : 1.12.5
#   Apache Airflow: 3.1.7  (pinned by OM ingestion for 1.12.x)
# =============================================================================

NAMESPACE        := openmetadata
DEPS_RELEASE     := openmetadata-dependencies
OM_RELEASE       := openmetadata
HELM_REPO        := open-metadata
HELM_REPO_URL    := https://helm.open-metadata.org/

# Port-forward targets
OM_LOCAL_PORT    := 8585
AIRFLOW_LOCAL_PORT := 8080

.PHONY: help cluster setup repo namespace secrets deps om migrate-airflow \
        port-forward-om port-forward-airflow \
        status logs-om logs-airflow \
        upgrade-deps upgrade-om \
        clean-deps clean-om clean delete-cluster

# -----------------------------------------------------------------------------
# help
# -----------------------------------------------------------------------------
help:
	@echo ""
	@echo "  OpenMetadata + Airflow — local K8s"
	@echo ""
	@echo "  Targets:"
	@echo "    make cluster         Create the kind cluster (run once before everything else)"
	@echo "    make setup           Full install (repo + ns + secrets + deps + om)"
	@echo "    make repo            Add the open-metadata Helm repo"
	@echo "    make namespace       Create the '$(NAMESPACE)' namespace"
	@echo "    make secrets         Create K8s secrets from k8s/secrets.yaml"
	@echo "    make deps            Install openmetadata-dependencies chart"
	@echo "    make om              Install openmetadata chart"
	@echo ""
	@echo "    make migrate-airflow Run Airflow DB migrations (run once after make deps)"
	@echo ""
	@echo "    make port-forward-om      Expose OM UI at http://localhost:$(OM_LOCAL_PORT)"
	@echo "    make port-forward-airflow Expose Airflow UI at http://localhost:$(AIRFLOW_LOCAL_PORT)"
	@echo ""
	@echo "    make status          Show pod status in namespace"
	@echo "    make logs-om         Stream OM server logs"
	@echo "    make logs-airflow    Stream Airflow webserver logs"
	@echo ""
	@echo "    make upgrade-deps    Helm upgrade for dependencies"
	@echo "    make upgrade-om      Helm upgrade for openmetadata"
	@echo ""
	@echo "    make clean-om        Uninstall openmetadata release"
	@echo "    make clean-deps      Uninstall openmetadata-dependencies release"
	@echo "    make clean           Uninstall both releases (keeps namespace)"
	@echo "    make delete-cluster  Destroy the kind cluster entirely"
	@echo ""

# -----------------------------------------------------------------------------
# kind cluster (run once)
# -----------------------------------------------------------------------------
cluster:
	kind create cluster --config k8s/kind-cluster.yaml
	kubectl cluster-info --context kind-openmetadata

delete-cluster:
	kind delete cluster --name openmetadata

# -----------------------------------------------------------------------------
# Full setup in one shot
# -----------------------------------------------------------------------------
setup: repo namespace secrets deps
	@echo ""
	@echo ">> Dependencies are deploying. Wait for all pods to be Ready before"
	@echo "   running 'make om'. Check with: make status"
	@echo ""

# -----------------------------------------------------------------------------
# Helm repo
# -----------------------------------------------------------------------------
repo:
	helm repo add $(HELM_REPO) $(HELM_REPO_URL)
	helm repo update

# -----------------------------------------------------------------------------
# Namespace
# -----------------------------------------------------------------------------
namespace:
	kubectl apply -f k8s/namespace.yaml

# -----------------------------------------------------------------------------
# Secrets
# NOTE: k8s/secrets.yaml contains example passwords. Edit them before running,
# or replace this target with your own secret management approach (Vault, ESO…)
# -----------------------------------------------------------------------------
secrets:
	kubectl apply -f k8s/secrets.yaml -n $(NAMESPACE)

# -----------------------------------------------------------------------------
# Dependencies (MySQL + OpenSearch + Airflow)
# -----------------------------------------------------------------------------
deps:
	helm install $(DEPS_RELEASE) $(HELM_REPO)/openmetadata-dependencies \
		--namespace $(NAMESPACE) \
		--values helm/deps-values.yaml \
		--timeout 10m \
		--wait

upgrade-deps:
	helm upgrade $(DEPS_RELEASE) $(HELM_REPO)/openmetadata-dependencies \
		--namespace $(NAMESPACE) \
		--values helm/deps-values.yaml \
		--timeout 10m \
		--wait

# -----------------------------------------------------------------------------
# OpenMetadata server
# Run only after 'make status' shows all dependency pods are Running/Ready.
# -----------------------------------------------------------------------------
om:
	helm install $(OM_RELEASE) $(HELM_REPO)/openmetadata \
		--namespace $(NAMESPACE) \
		--values helm/om-values.yaml \
		--timeout 10m \
		--wait

upgrade-om:
	helm upgrade $(OM_RELEASE) $(HELM_REPO)/openmetadata \
		--namespace $(NAMESPACE) \
		--values helm/om-values.yaml \
		--timeout 10m \
		--wait

# -----------------------------------------------------------------------------
# Airflow DB migration
# Run once after 'make deps' — pods will be stuck in Init until this completes.
# -----------------------------------------------------------------------------
migrate-airflow:
	@echo ">> Waiting for scheduler init container to be ready..."
	@until kubectl exec -n $(NAMESPACE) openmetadata-dependencies-scheduler-0 \
		-c wait-for-airflow-migrations -- echo "ready" 2>/dev/null; do \
		echo "   still waiting..."; sleep 5; \
	done
	@echo ">> Running Airflow DB migrations..."
	kubectl exec -n $(NAMESPACE) openmetadata-dependencies-scheduler-0 \
		-c wait-for-airflow-migrations -- airflow db migrate
	@echo ">> Migrations complete. Pods should become Ready shortly."

# -----------------------------------------------------------------------------
# Observability
# -----------------------------------------------------------------------------
status:
	kubectl get pods -n $(NAMESPACE) -o wide

logs-om:
	kubectl logs -n $(NAMESPACE) -l app.kubernetes.io/name=openmetadata -f --tail=100

logs-airflow:
	kubectl logs -n $(NAMESPACE) -l component=webserver -f --tail=100

# -----------------------------------------------------------------------------
# Port-forwarding
# Run each in a separate terminal.
# -----------------------------------------------------------------------------
port-forward-om:
	@echo ">> OpenMetadata UI → http://localhost:$(OM_LOCAL_PORT)"
	@echo "   Default credentials: admin / admin"
	kubectl port-forward svc/$(OM_RELEASE) $(OM_LOCAL_PORT):8585 -n $(NAMESPACE) --address 127.0.0.1

port-forward-airflow:
	@echo ">> Airflow UI → http://localhost:$(AIRFLOW_LOCAL_PORT)"
	@echo "   Default credentials: admin / admin"
	kubectl port-forward svc/$(DEPS_RELEASE)-api-server $(AIRFLOW_LOCAL_PORT):8080 -n $(NAMESPACE) --address 127.0.0.1

# -----------------------------------------------------------------------------
# Cleanup
# -----------------------------------------------------------------------------
clean-om:
	helm uninstall $(OM_RELEASE) --namespace $(NAMESPACE)

clean-deps:
	helm uninstall $(DEPS_RELEASE) --namespace $(NAMESPACE)

clean: clean-om clean-deps
