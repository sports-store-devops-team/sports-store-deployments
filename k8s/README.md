# Raw Kubernetes manifests

These resources use the `sports-store` namespace. Application Deployments use pinned image tags with `imagePullPolicy: Never` for images loaded into local Minikube: the standalone gateway uses `sports-store/gateway:0.2.0`, while the frontend remains `sports-store/frontend:0.1.0` and the backends remain at `0.1.0`.

## Layout

- `namespace.yaml`: application namespace
- `mongodb/`: Bitnami MongoDB values and seed ConfigMap
- `configmaps/`: non-secret backend configuration
- `auth-service/`, `catalog-service/`, `cart-service/`, `order-service/`, and `payment-service/`: internal backend workloads
- `frontend/`: internal frontend Deployment and ClusterIP Service
- `gateway/`: gateway Deployment and the only NodePort Service
- `secrets/app-secrets.yaml`: non-applicable guidance; create the real Secret outside Git

The gateway resolves `frontend`, `auth-service`, `catalog-service`, `cart-service`, `order-service`, and `payment-service` through Kubernetes Service DNS. Backend MongoDB URIs created outside Git must use `sports-store-mongodb:27017`.

## Apply order

Create the namespace and out-of-Git Secret first, then initialize MongoDB. Apply ConfigMaps, backends, frontend, and gateway in that order. See the repository root README for the complete sequence and Minikube access command.
