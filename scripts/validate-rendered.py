import argparse
from pathlib import Path

import yaml


API_ROUTES = [
    ("/api/auth", "auth-service", 8001),
    ("/api/products", "catalog-service", 8002),
    ("/api/internal", "catalog-service", 8002),
    ("/api/cart", "cart-service", 8003),
    ("/api/orders", "order-service", 8004),
    ("/api/payments", "payment-service", 8005),
]
LOCAL_ROUTES = [*API_ROUTES, ("/", "frontend", 80)]
CUSTOM_KINDS = {"SecretStore", "ExternalSecret", "ServiceMonitor"}


def load_documents(path):
    return [doc for doc in yaml.safe_load_all(path.read_text(encoding="utf-8")) if doc]


def route_tuple(path):
    backend = path["backend"]["service"]
    return path["path"], backend["name"], backend["port"]["number"]


def validate(environment, documents, expected_registry):
    ingresses = [doc for doc in documents if doc.get("kind") == "Ingress"]
    assert len(ingresses) == 1, "exactly one application Ingress must render"
    ingress = ingresses[0]
    paths = ingress["spec"]["rules"][0]["http"]["paths"]
    expected_routes = API_ROUTES if environment == "aws" else LOCAL_ROUTES
    assert [route_tuple(path) for path in paths] == expected_routes
    assert all(path["pathType"] == "Prefix" for path in paths)
    if environment == "aws":
        assert all(path["path"] != "/" for path in paths)
    else:
        assert paths[-1]["path"] == "/", "local frontend catch-all must remain last"

    annotations = ingress.get("metadata", {}).get("annotations", {})
    annotation_text = yaml.safe_dump(annotations).lower()
    assert "rewrite" not in annotation_text
    assert "remove" not in annotation_text
    assert "method" not in annotation_text

    workload_kinds = {"Deployment", "Service", "StatefulSet", "ServiceMonitor"}
    workloads = [doc for doc in documents if doc.get("kind") in workload_kinds]
    assert not any(doc.get("metadata", {}).get("name") == "gateway" for doc in workloads)
    assert all(route[1] != "gateway" for route in expected_routes)

    namespaced = [
        doc.get("metadata", {}).get("namespace")
        for doc in documents
        if doc.get("metadata", {}).get("namespace") is not None
    ]
    assert all(namespace == "sports-store" for namespace in namespaced)

    kinds = {doc.get("kind") for doc in documents}
    assert "ConfigMap" in kinds
    rendered_text = yaml.safe_dump_all(documents)
    assert "mongo-init" in rendered_text
    assert "init-mongo.js" in rendered_text
    assert "http://catalog-service:8002" in rendered_text
    assert "http://cart-service:8003" in rendered_text
    assert "http://payment-service:8005" in rendered_text
    assert "kind: Secret\n" not in rendered_text, "plaintext Secret rendered"

    application_images = [
        container["image"]
        for document in documents
        if document.get("kind") == "Deployment"
        for container in document["spec"]["template"]["spec"]["containers"]
        if container["name"] in {
            "auth-service",
            "catalog-service",
            "cart-service",
            "order-service",
            "payment-service",
            "frontend",
        }
    ]
    assert len(application_images) == (5 if environment == "aws" else 6)

    external_kinds = {"SecretStore", "ExternalSecret"}
    if environment == "aws":
        assert expected_registry, "AWS rendering requires an expected registry"
        assert all(
            image.startswith(f"{expected_registry}/") for image in application_images
        )
        assert ingress["spec"]["ingressClassName"] == "alb"
        assert annotations["alb.ingress.kubernetes.io/scheme"] == "internet-facing"
        assert annotations["alb.ingress.kubernetes.io/target-type"] == "ip"
        assert annotations["alb.ingress.kubernetes.io/healthcheck-path"] == "/health"
        assert external_kinds.issubset(kinds)
        frontend_resources = [
            doc
            for doc in documents
            if doc.get("metadata", {}).get("name") == "frontend"
            and doc.get("kind") in {"Deployment", "Service", "ServiceMonitor"}
        ]
        assert not frontend_resources, "AWS must not render frontend workloads"
    else:
        assert expected_registry is None
        assert all(".dkr.ecr." not in image for image in application_images)
        assert ingress["spec"]["ingressClassName"] == "nginx"
        assert external_kinds.isdisjoint(kinds)
        local_frontend_kinds = {
            doc["kind"]
            for doc in documents
            if doc.get("metadata", {}).get("name") == "frontend"
        }
        assert {"Deployment", "Service", "ServiceMonitor"}.issubset(
            local_frontend_kinds
        ), "local rendering must retain the complete frontend workload"
        frontend_deployment = next(
            doc
            for doc in documents
            if doc.get("kind") == "Deployment"
            and doc.get("metadata", {}).get("name") == "frontend"
        )
        frontend_containers = frontend_deployment["spec"]["template"]["spec"][
            "containers"
        ]
        assert {container["name"] for container in frontend_containers} == {
            "frontend",
            "nginx-exporter",
        }

    for document in documents:
        if document.get("kind") in CUSTOM_KINDS:
            assert document.get("apiVersion") and document.get("spec")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("environment", choices=["local", "aws"])
    parser.add_argument("manifest", type=Path)
    parser.add_argument("standard_output", type=Path)
    parser.add_argument("--expected-registry")
    args = parser.parse_args()

    documents = load_documents(args.manifest)
    validate(args.environment, documents, args.expected_registry)
    standard = [doc for doc in documents if doc.get("kind") not in CUSTOM_KINDS]
    args.standard_output.write_text(
        yaml.safe_dump_all(standard, sort_keys=False), encoding="utf-8"
    )
    print(f"{args.environment} rendering validated ({len(documents)} resources).")


if __name__ == "__main__":
    main()
