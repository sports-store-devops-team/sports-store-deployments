# Raw Minikube Manifests

These legacy local manifests use namespace `sports-store`, directly route the same public paths through the Minikube NGINX Ingress, and do not deploy the Gateway. Application images use `imagePullPolicy: Never` for locally loaded images.

Use the Helm chart for normal local and AWS deployments. The raw manifests remain a local teaching reference; secrets must be created outside Git. Backend service-to-service URLs continue to use Kubernetes Service DNS, and MongoDB initialization remains in `mongodb/init-configmap.yaml`.
