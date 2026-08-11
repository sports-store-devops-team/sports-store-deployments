# Sports Store Helm Chart

This chart deploys the five FastAPI services, frontend, MongoDB, monitoring integration, and optional External Secrets resources. It does not deploy the local-only NGINX Gateway.

## Request routing

Both environment overlays preserve the public `/api/...` paths and route directly to Kubernetes Services. `values-local.yaml` enables the Minikube NGINX Ingress; `values-aws.yaml` enables the internet-facing AWS ALB Ingress with IP targets. API paths precede the frontend `/` catch-all and no rewrite annotation is used.

| Path | Service | Port |
| --- | --- | --- |
| `/api/auth` | `auth-service` | 8001 |
| `/api/products` | `catalog-service` | 8002 |
| `/api/internal` | `catalog-service` | 8002 |
| `/api/cart` | `cart-service` | 8003 |
| `/api/orders` | `order-service` | 8004 |
| `/api/payments` | `payment-service` | 8005 |
| `/` | `frontend` | 80 |

All targets answer `/health`; the frontend NGINX supplies that endpoint without affecting SPA fallback behavior.

## Validation

```bash
helm dependency build
helm lint . -f values-local.yaml
helm lint . -f values-aws.yaml
helm template sports-store . --namespace sports-store -f values-local.yaml
helm template sports-store . --namespace sports-store -f values-aws.yaml
```

CI performs those commands, structured route and secret assertions, explicit CRD checks, and strict Kubeconform validation of standard Kubernetes resources.

## Environment behavior

Local images use `Never` pull policy and Minikube requires the Ingress addon. AWS uses immutable ECR tags in `<semver>-<7-char-git-hash>` format, External Secrets, and the retained `ebs-sc` MongoDB storage class. The `mongo-init` ConfigMap remains mounted for initialization of an empty persistent database.

Never put credentials in values or rendered manifests. AWS Secrets Manager owns the production secret value; Terraform creates only its metadata container, and External Secrets creates the Kubernetes Secret at runtime.
