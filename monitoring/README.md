# Sports Store observability

The observability stack is intentionally small enough for the course EKS
cluster while still covering application metrics, Kubernetes state, node
health, alerts, dashboards, and workload logs.

## Architecture and responsibilities

- The five FastAPI services expose internal Prometheus metrics and write safe,
  one-line JSON events to stdout. Route labels use FastAPI route templates,
  never requested URLs or resource identifiers.
- Frontend and gateway NGINX write minimal JSON access events. A pinned NGINX
  Prometheus Exporter sidecar scrapes a loopback-only `stub_status` listener.
- ServiceMonitors select five internal HTTP Services and two dedicated
  ClusterIP exporter Services at a 60-second interval.
- kube-prometheus-stack 88.1.5 provides Prometheus, Alertmanager, Grafana, the
  Prometheus Operator, kube-state-metrics, and node-exporter.
- Loki 18.5.0 stores logs in one monolithic replica. Alloy 1.11.0 uses one
  Deployment and the Kubernetes logs API to collect only `sports-store` Pod
  logs and events. It cannot read Kubernetes Secrets under its scoped RBAC.
- EKS `api`, `audit`, and `authenticator` logs go to CloudWatch for seven days.
  These control-plane records complement Loki workload logs; they do not
  duplicate or replace them.

## Diet Mode resource budget

Requests are the scheduling budget; limits are safety ceilings. Config
reloaders and the Grafana dashboard sidecar are included below.

| Component | Replicas | CPU request / limit | Memory request / limit |
|---|---:|---:|---:|
| Prometheus plus config reloader | 1 | 110m / 350m | 288Mi / 576Mi |
| Grafana plus dashboard sidecar | 1 | 60m / 250m | 160Mi / 320Mi |
| Prometheus Operator | 1 | 25m / 100m | 64Mi / 128Mi |
| Alertmanager plus config reloader | 1 | 35m / 150m | 96Mi / 192Mi |
| kube-state-metrics | 1 | 25m / 100m | 64Mi / 128Mi |
| Loki monolithic | 1 | 100m / 300m | 256Mi / 512Mi |
| Alloy plus config reloader | 1 | 30m / 125m | 80Mi / 160Mi |
| NGINX exporters | 2 | 20m / 100m | 48Mi / 96Mi |
| node-exporter | per node | 15m / 100m | 32Mi / 64Mi |

The fixed request is approximately 405m CPU and 1,056Mi memory, plus 15m CPU
and 32Mi memory per Linux node. At the Terraform configuration's six-node
desired capacity, that is approximately 495m CPU and 1,248Mi (1.22Gi) memory.
The corresponding limits are about 2,075m CPU and 2,496Mi (2.44Gi) memory.

Diet Mode disables built-in dashboards and rules, control-plane scrapes that
are unavailable on EKS, Loki caches/gateway/canary, distributed Loki
components, and all persistence for the observability stack. Prometheus keeps
24 hours up to 900MB in a 1Gi `emptyDir`; Loki keeps 24 hours in a 2Gi
`emptyDir`; Alertmanager also uses ephemeral storage. **Pod recreation loses
metrics, logs, silences, and notification state.** MongoDB persistence is
unrelated and remains controlled by the application chart.

## GitOps applications and order

All Applications use the existing `default` AppProject because no scoped
Sports Store AppProject exists in this repository. The intended order is:

1. Create `monitoring-grafana-admin` outside Git in `monitoring`.
2. Reconcile `sports-store-monitoring` so Prometheus Operator CRDs exist.
3. Reconcile `sports-store-loki`.
4. Reconcile `sports-store-alloy` after Loki is ready.
5. Reconcile `sports-store`; its ServiceMonitors carry sync wave `1` and the
   Application carries wave `2` for an app-of-apps bootstrap.

The monitoring Application renders the official chart, reads
`monitoring/values.yaml`, and applies `monitoring/resources`. Loki and Alloy
are separate pinned multi-source Applications. Automated prune and self-heal
match the existing GitOps policy.

Inspect GitOps state without syncing anything:

```bash
kubectl get applications -n argocd \
  sports-store-monitoring sports-store-loki sports-store-alloy sports-store
kubectl get applications -n argocd -o custom-columns='NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status'
```

## Grafana credentials and private access

The chart expects Secret `monitoring-grafana-admin` with keys `admin-user` and
`admin-password`. `grafana-admin-secret.example.yaml` documents names only.
Create or rotate it from a deliberately selected context; the helper never
prints the password and never writes Secret YAML to disk:

```bash
EXPECTED_KUBE_CONTEXT=my-eks-context \
  bash scripts/create-grafana-admin-secret.sh monitoring
```

The helper is intentionally not run by GitOps. Retrieve credentials only in a
private terminal and avoid shell history or screenshots:

```bash
kubectl get secret monitoring-grafana-admin -n monitoring \
  -o jsonpath='{.data.admin-user}' | base64 --decode; echo
kubectl get secret monitoring-grafana-admin -n monitoring \
  -o jsonpath='{.data.admin-password}' | base64 --decode; echo
```

Grafana has no Ingress or public Service. Use a temporary local tunnel:

```bash
kubectl port-forward -n monitoring svc/monitoring-grafana 3000:80
```

Open `http://127.0.0.1:3000` and stop the command when finished.

## Metrics and alert diagnostics

Prometheus and Alertmanager are ClusterIP-only. Inspect them with temporary
local tunnels:

```bash
kubectl port-forward -n monitoring svc/monitoring-kube-prometheus-prometheus 9090:9090
kubectl port-forward -n monitoring svc/monitoring-kube-prometheus-alertmanager 9093:9093
```

Useful read-only checks:

```bash
kubectl get servicemonitors -A -l observability.sports-store/enabled=true
kubectl get prometheusrules -n monitoring -l observability.sports-store/enabled=true
kubectl get pods -n monitoring
curl -fsS http://127.0.0.1:9090/api/v1/targets | jq '.data.activeTargets[] | {job: .labels.job, health: .health, error: .lastError}'
```

The single `Sports Store Overview` dashboard shows node CPU/memory, Pod phases
and restarts, desired/available Deployment replicas, request rate for all seven
application workloads, FastAPI 5xx rate and p95 latency, and recent Loki logs.
Built-in dashboard provisioning is disabled.

Alertmanager's only receiver is local `null`, so the Prometheus-to-Alertmanager
pipeline can be verified without committing notification credentials. Slack,
email, PagerDuty, or webhook routing remains a manual production integration
through an approved external Secret/configuration workflow.

## Loki and Alloy verification

The rendered monolithic Loki Service is
`loki.monitoring.svc.cluster.local:3100`. Both Alloy and Grafana use that exact
DNS name. Nothing exposes Loki or Alloy through Ingress, NodePort, LoadBalancer,
or ALB.

```bash
kubectl get deployment,statefulset,service -n monitoring \
  -l 'app.kubernetes.io/instance in (loki,alloy)'
kubectl logs -n monitoring deployment/alloy -c alloy --tail=100
kubectl port-forward -n monitoring svc/loki 3100:3100
curl -fsS http://127.0.0.1:3100/ready
```

In Grafana, select **Explore**, choose the `Loki` datasource, and query:

```logql
{namespace="sports-store"}
```

Events use `job="sports-store/events"`; container logs use
`job="sports-store/pods"`. Alloy collects stdout only and does not read Secret
objects, request bodies, or application data stores.

## Local validation

These commands render only; they do not install or contact a cluster:

```bash
helm lint helm/sports-store -f helm/sports-store/values-local.yaml
helm lint helm/sports-store -f helm/sports-store/values-aws.yaml
helm template sports-store helm/sports-store -n sports-store -f helm/sports-store/values-local.yaml
helm template sports-store helm/sports-store -n sports-store -f helm/sports-store/values-aws.yaml
helm template monitoring prometheus-community/kube-prometheus-stack --version 88.1.5 -n monitoring -f monitoring/values.yaml
helm template loki oci://ghcr.io/grafana-community/helm-charts/loki --version 18.5.0 -n monitoring -f logging/loki-values.yaml
helm template alloy grafana/alloy --version 1.11.0 -n monitoring -f logging/alloy-values.yaml
```

## Production limitations

- Prometheus, Alertmanager, Loki, and Grafana are single-replica and ephemeral.
- There is no object storage, durable volume, backup, restore test, or HA.
- Alert notifications intentionally go nowhere until an external receiver is
  configured outside Git.
- Grafana authentication is local admin only; SSO and fine-grained RBAC are
  not configured.
- Traffic between in-cluster observability components is HTTP without mTLS or
  NetworkPolicy enforcement.
- Alloy API log tailing is efficient for this small cluster but increases
  kubelet/API traffic compared with a host-file DaemonSet at larger scale.
- NGINX OSS `stub_status` provides request/connection totals, not per-status or
  latency histograms; 5xx and latency metrics therefore cover FastAPI services.
- Retention, scaling, cardinality, and resource budgets need load testing
  before production use.
