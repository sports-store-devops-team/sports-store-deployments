# Sports Store Helm Chart

This Helm chart deploys the Sports Store microservices application to Kubernetes. It provides environment-neutral defaults and a local Minikube override while leaving room for a future AWS/EKS configuration.

## Components

The chart deploys:

- Five FastAPI backend services: authentication, catalog, cart, order, and payment
- The frontend web application
- The gateway, which is the external entry point to the application
- MongoDB as the pinned Bitnami chart dependency
- Application ConfigMaps for non-secret backend configuration
- A MongoDB initialization ConfigMap containing the seed script
- A shared ServiceAccount for application workloads
- An optional Ingress that routes traffic only to the gateway

Each component can be enabled or disabled through its values. Ingress is disabled by default.

## Prerequisites

- A Kubernetes cluster, such as Minikube for local development
- `kubectl` configured for the intended cluster
- Helm 3
- The required application container images:
  - `sports-store/auth-service:0.1.0`
  - `sports-store/catalog-service:0.1.0`
  - `sports-store/cart-service:0.1.0`
  - `sports-store/order-service:0.1.0`
  - `sports-store/payment-service:0.1.0`
  - `sports-store/frontend:0.1.0`
  - `sports-store/gateway:0.2.0`
- An existing Kubernetes Secret named `app-secrets`, unless `existingSecret` and the MongoDB dependency configuration are changed together

The existing Secret must provide the keys expected by the application services and MongoDB dependency. Create and manage it outside Git. Never place passwords, JWT values, MongoDB connection strings, or other secret data in any values file.

## Values files

### `values.yaml`

`values.yaml` contains the environment-neutral chart defaults. Application images default to `IfNotPresent`, frontend and gateway Services default to `ClusterIP`, Ingress is disabled, and MongoDB runs as a standalone instance with persistent storage.

### `values-local.yaml`

`values-local.yaml` contains Minikube-specific overrides. It changes the backend, frontend, and gateway image pull policy to `Never` because the application images are loaded directly into Minikube rather than pulled from a registry. It also exposes the gateway through a `NodePort` Service. Ingress remains disabled locally.

### `values-aws.yaml`

`values-aws.yaml` contains AWS/EKS overrides. It enables an ALB Ingress, keeps the gateway as `ClusterIP`, enables the `ebs-sc` StorageClass, selects `IfNotPresent`, and supplies ECR registry and immutable tag placeholders. Replace the registry placeholder and all example tags with published values following `<semver>-<7-char-git-hash>` before deployment. Never use `latest`.

Values files are layered from left to right, so an environment file overrides matching settings from `values.yaml`.

## Dependencies

MongoDB is declared in `Chart.yaml` as Bitnami MongoDB chart version `19.1.22`. Dependency versions and integrity are pinned through `Chart.lock`. Restore the packaged dependency from the lock file with:

```bash
cd sports-store-deployments/helm/sports-store
helm dependency build
```

Do not use `helm dependency update` unless intentionally changing the locked dependency version.

## Validate the chart

Run these commands from `sports-store-deployments/helm/sports-store`.

Lint with the local overrides:

```bash
helm lint . -f values-local.yaml
```

Render the manifests without contacting or changing the cluster:

```bash
helm template sports-store . \
  --namespace sports-store-helm-test \
  -f values-local.yaml \
  > /tmp/sports-store-rendered.yaml
```

Ask `kubectl` to validate the rendered resources locally without applying them:

```bash
kubectl apply --dry-run=client \
  -f /tmp/sports-store-rendered.yaml
```

## Local Minikube installation

Build the application images and load the required tags into Minikube before installing the chart. For example:

```bash
minikube image load sports-store/auth-service:0.1.0
minikube image load sports-store/catalog-service:0.1.0
minikube image load sports-store/cart-service:0.1.0
minikube image load sports-store/order-service:0.1.0
minikube image load sports-store/payment-service:0.1.0
minikube image load sports-store/frontend:0.1.0
minikube image load sports-store/gateway:0.2.0
```

Create `app-secrets` in the target namespace through an approved secret-management workflow, then install:

```bash
helm dependency build

helm install sports-store . \
  --namespace sports-store \
  --create-namespace \
  -f values-local.yaml
```

Open the local gateway with:

```bash
minikube service gateway --namespace sports-store
```

## Release operations

Upgrade an existing local release:

```bash
helm upgrade sports-store . \
  --namespace sports-store \
  -f values-local.yaml
```

Review release history and roll back to a known revision:

```bash
helm history sports-store --namespace sports-store
helm rollback sports-store REVISION --namespace sports-store
```

Uninstall the release:

```bash
helm uninstall sports-store --namespace sports-store
```

## MongoDB persistence

MongoDB uses a persistent volume claim with a default requested size of `1Gi`. Its persistence resource policy is `keep`, so the chart is configured to retain persistent data independently of normal workload replacement.

Upgrades and rollbacks must reuse the existing PVC; do not delete or replace it as part of routine release operations. Before changing storage configuration or performing destructive maintenance, verify the PVC, PersistentVolume reclaim policy, and backups. Retaining a PVC is not a substitute for backups.

The `mongo-init` ConfigMap supplies the initialization script used when MongoDB initializes an empty data directory. It does not reseed an already-populated persistent volume during every upgrade.

## Ingress

Ingress is disabled in the default and local configurations. The AWS values enable an internet-facing ALB with IP targets. In every environment, Ingress routes configured hosts and paths only to the gateway Service; frontend and backend Services are not exposed directly.

## AWS prerequisites and validation

Provision EKS and its managed EBS CSI add-on first. The AWS values create the cluster-scoped `ebs-sc` StorageClass using `ebs.csi.aws.com`, `gp3`, `WaitForFirstConsumer`, volume expansion, and a `Retain` reclaim policy. MongoDB requests that same StorageClass.

Install AWS Load Balancer Controller only after Terraform has created its scoped IAM role. Obtain the role ARN with `terraform output -raw aws_load_balancer_controller_iam_role_arn`, then pass it to `scripts/install-aws-lbc.sh`. The script installs the pinned controller chart into `kube-system` and annotates its Helm-created ServiceAccount.

Validate AWS rendering without installing it:

```bash
helm lint . -f values-aws.yaml
helm template sports-store . \
  --namespace sports-store \
  -f values-aws.yaml \
  > /tmp/sports-store-aws.yaml
kubectl apply --dry-run=client -f /tmp/sports-store-aws.yaml
```

## Secret handling

The chart references an existing Secret; it does not create application credentials. Secret manifests, command-line secret values, exported Secret contents, and decrypted credentials must never be committed to this repository or stored in `values.yaml`, `values-local.yaml`, or future environment values files.
