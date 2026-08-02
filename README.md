# Sports Store Deployments

Raw Kubernetes manifests for the Sports Store application. Workloads run in the `sports-store` namespace. The gateway is the only NodePort; frontend and backend Services are internal ClusterIP Services.

## Local Minikube setup

The helper scripts resolve every sibling repository relative to their own location, so they can be run from any working directory. Start Minikube, then run:

```sh
bash scripts/create-local-secrets.sh sports-store
```

On first use, the helper generates a protected, Git-ignored `scripts/local-secrets.env`; later runs reuse it without replacing its values. Keep `MONGO_ROOT_USERNAME=root` so it matches the Helm chart. If `app-secrets` already exists, the helper refuses to rotate its MongoDB password because changing the Secret alone does not update an initialized MongoDB PVC.

Build and load all seven pinned application images:

```sh
bash scripts/build-load-minikube-images.sh
```

The image script builds from the sibling application repositories and loads the exact chart tags into Minikube. The local Helm values use `imagePullPolicy: Never`, which is appropriate for those locally loaded images and is not an EKS deployment strategy.

Validate and install the chart from its directory:

```sh
cd helm/sports-store
helm dependency build
helm lint . -f values-local.yaml
helm upgrade --install sports-store . \
  --namespace sports-store \
  -f values-local.yaml
```

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

The `k8s/` tree retains the verified raw resource-per-component layout. The application Helm chart is under `helm/sports-store/`.
