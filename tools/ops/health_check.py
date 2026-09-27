#!/usr/bin/env python3
"""health_check.py — hit every service's /actuator/health and print one table.

Spring Cloud Gateway (api-gateway) does not aggregate downstream health
(B-03: it only proxies the TMF routes), so there is no single URL that
answers "is everything up". This script hits each backend's own actuator
endpoint directly and reports UP/DOWN/TIMEOUT for all of them at once.

Run it from your machine against port-forwarded services:

    kubectl -n bss port-forward svc/customer-service 18081:8080 &
    kubectl -n bss port-forward svc/product-catalog  18082:8080 &
    kubectl -n bss port-forward svc/order-management 18083:8080 &
    kubectl -n bss port-forward svc/billing-service   18084:8080 &
    kubectl -n bss port-forward svc/api-gateway        18080:8080 &
    python tools/ops/health_check.py --mode local

Or run it as a one-off pod *inside* the cluster (no port-forward needed),
where the default `--mode cluster` Kubernetes Service DNS names resolve:

    kubectl -n bss run health-check --rm -it --restart=Never \\
      --image=python:3.12-slim -- sh -c \\
      "pip install requests -q && python -c \\"$(cat tools/ops/health_check.py)\\" --mode cluster"

Exit code is 0 only if every target reports UP.
"""

from __future__ import annotations

import argparse
import sys

import requests

CLUSTER_TARGETS = {
    "api-gateway": "http://api-gateway.bss.svc.cluster.local:8080/actuator/health",
    "customer-service": "http://customer-service.bss.svc.cluster.local:8080/actuator/health",
    "product-catalog": "http://product-catalog.bss.svc.cluster.local:8080/actuator/health",
    "order-management": "http://order-management.bss.svc.cluster.local:8080/actuator/health",
    "billing-service": "http://billing-service.bss.svc.cluster.local:8080/actuator/health",
}

LOCAL_TARGETS = {
    "api-gateway": "http://localhost:18080/actuator/health",
    "customer-service": "http://localhost:18081/actuator/health",
    "product-catalog": "http://localhost:18082/actuator/health",
    "order-management": "http://localhost:18083/actuator/health",
    "billing-service": "http://localhost:18084/actuator/health",
}


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument(
        "--mode",
        choices=["cluster", "local"],
        default="cluster",
        help="which default target map to use (default: cluster, for in-cluster DNS)",
    )
    parser.add_argument(
        "--targets",
        help="override targets as 'name=url,name=url' instead of the built-in map",
    )
    parser.add_argument("--timeout", type=float, default=3.0, help="per-request timeout in seconds")
    return parser.parse_args()


def build_targets(args: argparse.Namespace) -> dict[str, str]:
    if args.targets:
        pairs = [p.split("=", 1) for p in args.targets.split(",")]
        return {name: url for name, url in pairs}
    return CLUSTER_TARGETS if args.mode == "cluster" else LOCAL_TARGETS


def check_one(name: str, url: str, timeout: float) -> tuple[str, str]:
    try:
        resp = requests.get(url, timeout=timeout)
    except requests.exceptions.Timeout:
        return "TIMEOUT", "-"
    except requests.exceptions.RequestException as exc:
        return "DOWN", str(exc)[:60]
    try:
        status = resp.json().get("status", "UNKNOWN")
    except ValueError:
        status = "UNKNOWN"
    return ("UP" if status == "UP" else status), f"HTTP {resp.status_code}"


def main() -> int:
    args = parse_args()
    targets = build_targets(args)

    print(f"{'Service':<20} {'Status':<10} {'Detail'}")
    all_up = True
    for name, url in targets.items():
        status, detail = check_one(name, url, args.timeout)
        if status != "UP":
            all_up = False
        marker = "✅" if status == "UP" else "❌"
        print(f"{name:<20} {status:<10} {detail} {marker}")

    print()
    print("All services UP." if all_up else "One or more services are NOT healthy.")
    return 0 if all_up else 1


if __name__ == "__main__":
    sys.exit(main())
