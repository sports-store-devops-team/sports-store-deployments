# Sports Store observability

The observability stack is intentionally small enough for the course EKS
cluster while still covering application metrics, Kubernetes state, node
health, alerts, dashboards, and workload logs.

## Architecture and responsibilities

- The five FastAPI services expose internal Prometheus metrics and write safe,
  one-line JSON events to stdout. Route labels use FastAPI route templates,
  never requested URLs or resource identifiers.
- Frontend NGINX writes minimal JSON access events. A pinned NGINX
  Prometheus Exporter sidecar scrapes a loopback-only `stub_status` listener.
- ServiceMonitors select five internal HTTP Services and two dedicated
  ClusterIP exporter Services at a 60-second interval.
- kube-prometheus-stack 88.1.5 provides Prometheus, Alertmanager, Grafana, the
  Prometheus Operator, kube-state-metrics, and node-exporter.
- The official Grafana Community Loki chart 18.5.0 (Loki 3.7.3) stores logs
  in one monolithic replica. The official Grafana Alloy chart 1.11.0 (Alloy
  1.18.0) uses one Deployment and the Kubernetes logs API to collect only
  `sports-store` Pod logs and events. It cannot read Kubernetes Secrets under
  its scoped RBAC.
- EKS `api`, `audit`, and `authenticator` logs go to CloudWatch for seven days.
  These control-plane records complement Loki workload logs; they do not
  duplicate or replace them.

## Diet Mode resource budget

Requests are the scheduling budget; limits are safety ceilings. Config
reloaders and the Grafana dashboard sidecar are included below. Alloy's
config-reloader is disabled: Helm puts a config checksum on the Pod template,
so GitOps changes still trigger a rollout without a permanent sidecar.

| Component | Replicas | CPU request / limit | Memory request / limit |
|---|---:|---:|---:|
| Prometheus plus config reloader | 1 | 110m / 350m | 288Mi / 576Mi |
| Grafana plus dashboard sidecar | 1 | 60m / 250m | 160Mi / 320Mi |
| Prometheus Operator | 1 | 25m / 100m | 64Mi / 128Mi |
| Alertmanager plus config reloader | 1 | 35m / 150m | 96Mi / 192Mi |
| kube-state-metrics | 1 | 25m / 100m | 64Mi / 128Mi |
| Loki monolithic | 1 | 100m / 300m | 256Mi / 512Mi |
| Alloy | 1 | 30m / 125m | 80Mi / 160Mi |
| NGINX exporters | 2 | 20m / 100m | 48Mi / 96Mi |
| node-exporter | per node | 15m / 100m | 32Mi / 64Mi |

The fixed request is approximately 405m CPU and 1,056Mi memory, plus 15m CPU
and 32Mi memory per Linux node. At the Terraform configuration's six-node
desired capacity, that is approximately 495m CPU and 1,248Mi (1.22Gi) memory.
The corresponding limits are about 2,075m CPU and 2,496Mi (2.44Gi) memory.

The rendered logging inventory used for later node sizing is:

| Component | Workload kind | Replicas | Containers per Pod | CPU request / limit | Memory request / limit | Storage |
|---|---|---:|---:|---:|---:|---|
| Loki monolithic | StatefulSet | 1 | 1 | 100m / 300m | 256Mi / 512Mi | 2Gi bounded `emptyDir` at `/var/loki` |
| Alloy | Deployment | 1 | 1 | 30m / 125m | 80Mi / 160Mi | 128Mi bounded `emptyDir` at `/tmp/alloy` |

Loki also renders the stable `loki` ClusterIP query/write Service and two
headless chart-internal Services, `loki-headless` for the StatefulSet and
`loki-memberlist` for Loki's internal ring. They expose nothing outside the
cluster and create no additional Pods. Alloy renders no Service.

Diet Mode disables built-in dashboards and rules, control-plane scrapes that
are unavailable on EKS, Loki caches/gateway/canary, distributed Loki
components, and all persistence for the observability stack. Prometheus keeps
24 hours up to 900MB in a 1Gi `emptyDir`; Loki keeps 24 hours in a 2Gi
`emptyDir`; Alertmanager also uses ephemeral storage. **Pod recreation can
lose metrics, logs, silences, and notification state; cluster destruction
loses all of them.** This intentional cost tradeoff is not highly available or
production-durable. MongoDB persistence is unrelated and remains controlled by
the application chart.

## GitOps applications and order

All Applications use the existing `default` AppProject because no scoped
Sports Store AppProject exists in this repository. The intended order is:

1. Create `monitoring-grafana-admin` outside Git in `monitoring`.
2. Reconcile `sports-store-monitoring` at sync wave `0` so the namespace,
   Grafana, and Prometheus Operator CRDs exist.
3. Reconcile `sports-store-loki` at wave `1`.
4. Reconcile `sports-store-alloy` at wave `2`; delivery retries are safe while
   Loki finishes readiness.
5. Reconcile `sports-store` at wave `3`.

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
`job="sports-store/pods"`. Useful focused queries are:

```logql
{job="sports-store/pods"}
{job="sports-store/events"}
{job="sports-store/pods", app_kubernetes_io_component="order-service"} | json
```

Pod streams carry only the low-cardinality labels `namespace`, `pod`,
`container`, `app_kubernetes_io_name`, `app_kubernetes_io_component`, and
`job`. Event streams carry Alloy's documented `namespace`, `job`, and
`instance` labels. Kubernetes labels containing dots and slashes are converted
to valid Loki label names with underscores. JSON log lines remain unchanged as
content and can be parsed at query time with `| json`; no request IDs, user
IDs, URLs, order IDs, timestamps, or message content become labels.

The Alloy ServiceAccount is in `monitoring`. Its only binding is a Role in
`sports-store`: `pods` and `events` allow `get`, `list`, and `watch`, while
`pods/log` allows only `get`. It has no ClusterRole, mutation verb, or
permission for Secrets, ConfigMaps, Namespaces, Nodes, or other namespaces.
Alloy collects container stdout/stderr and event records through the Kubernetes
API; it has no host mount, privileged mode, host network/PID, application file
access, or data store access.

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

Validate the extracted Alloy configuration with the chart's exact app image:

```bash
docker run --rm -v "$PWD:/work:ro" \
  docker.io/grafana/alloy@sha256:491b0578c04983fd54fe99b587b6fab4404dc46d0dc16677bd6b00cc1140b308 \
  validate /work/rendered-alloy-config.alloy
```

Loki's chart-selected 3.7.3 image is likewise pinned to manifest-list digest
`sha256:70b9f699fc9bb868b62f1cfd4f787dfa50242f1fd92e6089787d5d7daea75fe8`;
CI runs its `-verify-config=true` check against the rendered config.

If Loki is not ready, inspect only status and recent logs, then verify the 2Gi
`emptyDir` has not filled. If Alloy reports delivery failures, verify
`loki.monitoring.svc.cluster.local`, the Loki `/ready` endpoint, Alloy's scoped
Role, and that `sports-store` Pods exist. Alloy retries temporary connection
failures; do not broaden RBAC or add host mounts to troubleshoot.

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
