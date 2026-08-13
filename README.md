# Sports Store Deployments

GitOps deployment configuration for namespace `sports-store`.

## Production AWS flow

`User -> CloudFront -> private S3 (frontend)`

`User -> CloudFront /api/* -> ALB -> Kubernetes Ingress -> FastAPI Service -> Pod`

S3 is the production frontend source origin, with direct public access blocked. Only Vite content-hashed `/assets/*` receive long-lived caching. Extensionless SPA routes are rewritten to `index.html`; API responses remain uncached and preserve query strings, cookies, authorization, CORS headers, and required methods. The ALB remains directly reachable only for API troubleshooting. The AWS frontend Pod, Service, metrics sidecar, ServiceMonitor, and root Ingress route are intentionally disabled.

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

The six rows above are the complete AWS ALB route set. Local and Minikube values still add `/ -> frontend:80`; the frontend remains containerized for local development and CI validation.

No route rewrites the URI. Enable the Minikube Ingress addon before using `values-local.yaml`:

```bash
minikube addons enable ingress
```

The chart preserves MongoDB initialization, persistent storage, AWS External Secrets, and the `sports-store` namespace. CI lints and renders both environments and validates standard schemas plus the project CRDs.
