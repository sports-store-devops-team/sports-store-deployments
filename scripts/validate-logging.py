import argparse
from pathlib import Path

import yaml


LOKI_URL = "http://loki.monitoring.svc.cluster.local:3100"
ALLOY_PUSH_URL = f"{LOKI_URL}/loki/api/v1/push"
PUBLIC_SERVICE_TYPES = {"LoadBalancer", "NodePort", "ExternalName"}


def documents(path):
    return [doc for doc in yaml.safe_load_all(path.read_text(encoding="utf-8")) if doc]


def metadata_name(document):
    return document.get("metadata", {}).get("name", "")


def workloads(items):
    return [doc for doc in items if doc.get("kind") in {"Deployment", "StatefulSet", "DaemonSet"}]


def config_value(items, key):
    values = [
        doc["data"][key]
        for doc in items
        if doc.get("kind") == "ConfigMap" and key in doc.get("data", {})
    ]
    assert len(values) == 1, f"expected one ConfigMap key named {key}"
    return values[0]


def assert_no_public_or_secret_resources(items):
    assert not any(doc.get("kind") in {"Ingress", "Secret"} for doc in items)
    for service in (doc for doc in items if doc.get("kind") == "Service"):
        assert service.get("spec", {}).get("type", "ClusterIP") not in PUBLIC_SERVICE_TYPES


def assert_restricted_container(container):
    context = container.get("securityContext", {})
    assert context.get("runAsNonRoot") is True
    assert context.get("allowPrivilegeEscalation") is False
    assert context.get("readOnlyRootFilesystem") is True
    assert context.get("capabilities", {}).get("drop") == ["ALL"]
    assert context.get("seccompProfile", {}).get("type") == "RuntimeDefault"


def validate_loki(items, extracted_config):
    assert_no_public_or_secret_resources(items)
    rendered_workloads = workloads(items)
    assert len(rendered_workloads) == 1, [metadata_name(doc) for doc in rendered_workloads]
    workload = rendered_workloads[0]
    assert workload["kind"] == "StatefulSet"
    assert metadata_name(workload) == "loki"
    assert workload["spec"]["replicas"] == 1

    pod_spec = workload["spec"]["template"]["spec"]
    assert pod_spec.get("automountServiceAccountToken") is False
    assert len(pod_spec["containers"]) == 1
    container = pod_spec["containers"][0]
    assert container["name"] == "loki"
    assert container["resources"] == {
        "limits": {"cpu": "300m", "memory": "512Mi"},
        "requests": {"cpu": "100m", "memory": "256Mi"},
    }
    assert_restricted_container(container)

    storage = next(volume for volume in pod_spec["volumes"] if volume["name"] == "storage")
    assert storage["emptyDir"]["sizeLimit"] == "2Gi"
    assert not any(doc.get("kind") == "PersistentVolumeClaim" for doc in items)

    services = [doc for doc in items if doc.get("kind") == "Service"]
    query_services = [doc for doc in services if metadata_name(doc) == "loki"]
    assert len(query_services) == 1
    assert query_services[0]["spec"].get("type", "ClusterIP") == "ClusterIP"
    assert any(port.get("port") == 3100 for port in query_services[0]["spec"]["ports"])
    assert {metadata_name(service) for service in services} == {
        "loki", "loki-headless", "loki-memberlist"
    }
    assert all(service["spec"].get("type", "ClusterIP") == "ClusterIP" for service in services)
    assert not any(doc.get("kind") in {"ClusterRole", "ClusterRoleBinding", "Role", "RoleBinding"} for doc in items)

    config = config_value(items, "config.yaml")
    for expected in (
        "auth_enabled: false",
        "retention_period: 24h",
        "retention_enabled: true",
        "delete_request_store: filesystem",
        "object_store: filesystem",
        "store: tsdb",
        "period: 24h",
    ):
        assert expected in config, expected
    extracted_config.write_text(config.rstrip() + "\n", encoding="utf-8")

    forbidden_names = (
        "gateway", "canary", "chunks-cache", "results-cache", "backend", "read", "write",
        "ingester", "querier", "query-frontend", "query-scheduler", "distributor",
        "compactor", "index-gateway", "bloom-planner", "bloom-builder", "bloom-gateway",
        "minio",
    )
    assert not any(any(name in metadata_name(doc) for name in forbidden_names) for doc in rendered_workloads)


def validate_alloy(items, extracted_config, grafana_values, dashboard):
    assert_no_public_or_secret_resources(items)
    rendered_workloads = workloads(items)
    assert len(rendered_workloads) == 1
    deployment = rendered_workloads[0]
    assert deployment["kind"] == "Deployment"
    assert metadata_name(deployment) == "alloy"
    assert deployment["spec"]["replicas"] == 1

    pod_spec = deployment["spec"]["template"]["spec"]
    assert pod_spec.get("hostNetwork") is not True
    assert pod_spec.get("hostPID") is not True
    assert len(pod_spec["containers"]) == 1
    assert not any("hostPath" in volume for volume in pod_spec.get("volumes", []))
    container = pod_spec["containers"][0]
    assert container["name"] == "alloy"
    assert container["resources"] == {
        "limits": {"cpu": "125m", "memory": "160Mi"},
        "requests": {"cpu": "30m", "memory": "80Mi"},
    }
    assert_restricted_container(container)

    roles = [doc for doc in items if doc.get("kind") == "Role"]
    assert len(roles) == 1
    assert roles[0]["metadata"]["namespace"] == "sports-store"
    assert roles[0]["rules"] == [
        {
            "apiGroups": [""],
            "resources": ["pods"],
            "verbs": ["get", "list", "watch"],
        },
        {
            "apiGroups": [""],
            "resources": ["pods/log"],
            "verbs": ["get"],
        },
        {
            "apiGroups": [""],
            "resources": ["events"],
            "verbs": ["get", "list", "watch"],
        },
    ]
    assert not any(doc.get("kind") in {"ClusterRole", "ClusterRoleBinding"} for doc in items)
    assert "secrets" not in yaml.safe_dump(roles).lower()

    bindings = [doc for doc in items if doc.get("kind") == "RoleBinding"]
    assert len(bindings) == 1
    assert bindings[0]["metadata"]["namespace"] == "sports-store"
    assert bindings[0]["subjects"] == [{
        "kind": "ServiceAccount",
        "name": "alloy",
        "namespace": "monitoring",
    }]

    config = config_value(items, "config.alloy")
    for expected in (
        'names = ["sports-store"]',
        'namespaces = ["sports-store"]',
        'replacement  = "sports-store/pods"',
        'job_name   = "sports-store/events"',
        'target_label  = "namespace"',
        'target_label  = "pod"',
        'target_label  = "container"',
        'target_label  = "app_kubernetes_io_name"',
        'target_label  = "app_kubernetes_io_component"',
        ALLOY_PUSH_URL,
    ):
        assert expected in config, expected
    for forbidden in ('monitoring"]', 'argocd"]', 'kube-system"]'):
        assert forbidden not in config
    extracted_config.write_text(config.rstrip() + "\n", encoding="utf-8")

    monitoring = yaml.safe_load(grafana_values.read_text(encoding="utf-8"))
    datasources = monitoring["grafana"]["datasources"]["datasources.yaml"]["datasources"]
    prometheus = next(source for source in datasources if source["uid"] == "prometheus")
    loki = next(source for source in datasources if source["uid"] == "loki")
    assert prometheus["isDefault"] is True
    assert loki == {
        "name": "Loki",
        "uid": "loki",
        "type": "loki",
        "access": "proxy",
        "url": LOKI_URL,
        "isDefault": False,
        "editable": False,
    }
    dashboard_text = dashboard.read_text(encoding="utf-8")
    assert '{job=\\"sports-store/pods\\"}' in dashboard_text


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("component", choices=["loki", "alloy"])
    parser.add_argument("manifest", type=Path)
    parser.add_argument("--loki-config", type=Path)
    parser.add_argument("--alloy-config", type=Path)
    parser.add_argument("--grafana-values", type=Path)
    parser.add_argument("--dashboard", type=Path)
    args = parser.parse_args()
    items = documents(args.manifest)
    if args.component == "loki":
        assert args.loki_config is not None
        validate_loki(items, args.loki_config)
    else:
        assert args.alloy_config is not None
        assert args.grafana_values is not None
        assert args.dashboard is not None
        validate_alloy(
            items,
            args.alloy_config,
            args.grafana_values,
            args.dashboard,
        )
    print(f"{args.component} rendering validated ({len(items)} resources).")


if __name__ == "__main__":
    main()
