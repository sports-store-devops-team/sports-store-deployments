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

## AWS/EKS deployment

The base `values.yaml` is environment-neutral, `values-local.yaml` supplies Minikube-only overrides, and `values-aws.yaml` enables AWS behavior. Before an AWS render or deployment, replace the ECR registry placeholder and every example `<semver>-<7-char-git-hash>` image tag in `values-aws.yaml`; `latest` tags are not allowed.

AWS deployment prerequisites include the Terraform-created EKS cluster, EBS CSI add-on and IRSA role, the `ebs-sc` StorageClass enabled by the AWS values, seven published ECR images, an out-of-Git `app-secrets` Secret, and AWS Load Balancer Controller. Obtain the controller role ARN with:

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

AWS Ingress routes only to the ClusterIP gateway through an internet-facing ALB using IP targets. Secrets remain outside Git and must never be placed in Helm values files.
