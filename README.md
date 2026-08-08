# Sports Store Deployments

Raw Kubernetes manifests for the Sports Store application. Workloads run in the `sports-store` namespace. The gateway is the only NodePort; frontend and backend Services are internal ClusterIP Services.

The complete Diet Mode metrics, alerts, dashboard, Loki/Alloy logging,
credential workflow, resource budget, verification commands, and production
limitations are documented in [monitoring/README.md](monitoring/README.md).

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

## AWS/EKS deployment

The base `values.yaml` is environment-neutral, `values-local.yaml` supplies Minikube-only overrides, and `values-aws.yaml` enables AWS behavior. Before an AWS render or deployment, replace the ECR registry placeholder and every example `<semver>-<7-char-git-hash>` image tag in `values-aws.yaml`; `latest` tags are not allowed.

AWS deployment prerequisites include the Terraform-created EKS cluster, EBS CSI add-on and IRSA role, External Secrets Operator and its IRSA role, the `sports-store/production/app` AWS Secrets Manager container, the `ebs-sc` StorageClass enabled by the AWS values, seven published ECR images, and AWS Load Balancer Controller. Terraform creates only the AWS secret container; Yuval must run the infrastructure repository's `scripts/bootstrap-application-secrets.sh` after the first apply. External Secrets Operator then creates and maintains `app-secrets` in `sports-store`.

Use this setup order:

```text
Terraform apply
-> bootstrap AWS secret values
-> wait for ExternalSecret synchronization
-> verify app-secrets exists
-> verify MongoDB and application workloads
```

Obtain the controller role ARN with:

```sh
terraform -chdir=../sports-store-infrastructure/terraform output -raw aws_load_balancer_controller_iam_role_arn
```

Then run `scripts/install-aws-lbc.sh` with `--cluster-name`, `--region`, and `--iam-role-arn`, or the corresponding documented environment variables. Review the script before running it; this repository does not run it automatically.

Validate both environments without installing a release:

```sh
helm dependency build helm/sports-store
helm lint helm/sports-store -f helm/sports-store/values-local.yaml
helm lint helm/sports-store -f helm/sports-store/values-aws.yaml
helm template sports-store helm/sports-store -f helm/sports-store/values-local.yaml
helm template sports-store helm/sports-store -f helm/sports-store/values-aws.yaml
```

AWS Ingress routes only to the ClusterIP gateway through an internet-facing ALB using IP targets. Verify secret synchronization without printing values:

```sh
kubectl get secretstore,externalsecret -n sports-store
kubectl describe externalsecret app-secrets -n sports-store
kubectl wait --for=condition=Ready externalsecret/app-secrets -n sports-store --timeout=120s
kubectl get secret app-secrets -n sports-store -o go-template='{{range $key, $_ := .data}}{{printf "%s\n" $key}}{{end}}'
kubectl get pods -n sports-store
```

Local development remains independent of AWS: `externalSecrets.enabled` defaults to `false`, and `scripts/create-local-secrets.sh` continues to create the local Secret. No password, JWT secret, credential-bearing URI, AWS access key, or secret JSON belongs in Git, Terraform inputs/state, Helm values, shell history, or logs.

External Secrets refreshes `app-secrets`, but environment variables in running Pods change only after a restart. JWT rotation invalidates tokens once all backends restart with the new signing key. MongoDB root-password rotation is different: the initialized database retains its credential, so rotating the AWS property without changing MongoDB in a coordinated maintenance procedure breaks authentication. Normal deployments must not rotate either property automatically.
