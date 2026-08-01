# Sports Store Deployments

Raw Kubernetes manifests for the Sports Store application. Workloads run in the `sports-store` namespace. The gateway is the only NodePort; frontend and backend Services are internal ClusterIP Services.

## Local Minikube images

Build or load the pinned application images into Minikube before creating workloads: `sports-store/frontend:0.1.0`, `sports-store/gateway:0.2.0`, and each backend image at `0.1.0`. These local manifests use `imagePullPolicy: Never`, which is appropriate for locally loaded Minikube images and is not an EKS deployment strategy.

## Safe application order

1. Apply `k8s/namespace.yaml`.
2. Create `app-secrets` outside Git in the `sports-store` namespace.
3. Install MongoDB using `k8s/mongodb/values.yaml` and apply its init ConfigMap.
4. Apply the ConfigMaps.
5. Apply backend Deployments and Services.
6. Apply the frontend Deployment and Service.
7. Apply the gateway Deployment and Service last.

Do not store secret values or credential-bearing MongoDB URIs in this repository. The file under `k8s/secrets/` is guidance only and is intentionally not a usable Secret.

Access the site with:

```sh
minikube service gateway -n sports-store
```

The `k8s/` tree retains the raw resource-per-component layout. No application Helm chart is included.
