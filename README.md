# Sports Store Deployments

GitOps deployment configuration for namespace `sports-store`.

## Production AWS flow

`User -> CloudFront -> ALB -> Kubernetes Ingress -> frontend or FastAPI Service -> Pod`

CloudFront keeps the ALB origin, HTTPS viewer redirect, HTTP origin protocol, disabled caching, all viewer query strings/cookies/authorization/CORS headers, and all application methods. The ALB remains directly reachable. The local-only Gateway is absent from Helm, AWS image values, monitoring targets, and the production request path.

## Local flows

Minikube uses the NGINX Ingress addon with the same direct path-to-Service mapping as AWS. Docker Compose, maintained in `sports-store-local`, retains `sports-store-gateway` only as a local same-origin adapter on `localhost:8080`.

## Public routes

| Path | Backend |
| --- | --- |
| `/api/auth` | `auth-service:8001` |
| `/api/products` | `catalog-service:8002` |
| `/api/internal` | `catalog-service:8002` |
| `/api/cart` | `cart-service:8003` |
| `/api/orders` | `order-service:8004` |
| `/api/payments` | `payment-service:8005` |
| `/` | `frontend:80` |

No route rewrites the URI. Enable the Minikube Ingress addon before using `values-local.yaml`:

```bash
minikube addons enable ingress
```

The chart preserves MongoDB initialization, persistent storage, AWS External Secrets, and the `sports-store` namespace. CI lints and renders both environments and validates standard schemas plus the project CRDs.
