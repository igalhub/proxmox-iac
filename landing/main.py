import os

import httpx
from fastapi import FastAPI
from fastapi.responses import HTMLResponse
from fastapi.templating import Jinja2Templates
from starlette.requests import Request

PROMETHEUS_URL = os.environ.get(
    "PROMETHEUS_URL", "http://prometheus-server.monitoring.svc.cluster.local"
)
REFRESH_SECONDS = int(os.environ.get("REFRESH_SECONDS", "10"))

QUERIES = {
    "nodes_total": "count(kube_node_info)",
    "nodes_ready": 'sum(kube_node_status_condition{condition="Ready",status="true"})',
    "pods_by_phase": "sum by (phase) (kube_pod_status_phase)",
    "memory_used_pct": (
        "100 * (sum(node_memory_MemTotal_bytes) - sum(node_memory_MemAvailable_bytes))"
        " / sum(node_memory_MemTotal_bytes)"
    ),
}

app = FastAPI()
templates = Jinja2Templates(directory="templates")


async def query_prometheus(client: httpx.AsyncClient, promql: str) -> list[dict]:
    response = await client.get(
        f"{PROMETHEUS_URL}/api/v1/query", params={"query": promql}
    )
    response.raise_for_status()
    return response.json()["data"]["result"]


def scalar(result: list[dict], default: str = "?") -> str:
    if not result:
        return default
    return result[0]["value"][1]


@app.get("/", response_class=HTMLResponse)
async def index(request: Request):
    error = None
    nodes_total = nodes_ready = memory_used_pct = "?"
    pods_by_phase: dict[str, str] = {}

    try:
        async with httpx.AsyncClient(timeout=5.0) as client:
            nodes_total_result, nodes_ready_result, pods_result, memory_result = [
                await query_prometheus(client, QUERIES[key])
                for key in (
                    "nodes_total",
                    "nodes_ready",
                    "pods_by_phase",
                    "memory_used_pct",
                )
            ]
        nodes_total = scalar(nodes_total_result)
        nodes_ready = scalar(nodes_ready_result)
        memory_used_pct = scalar(memory_result)
        pods_by_phase = {
            item["metric"].get("phase", "unknown"): item["value"][1]
            for item in pods_result
        }
    except (httpx.HTTPError, KeyError, IndexError) as exc:
        error = f"Could not reach Prometheus: {exc}"

    return templates.TemplateResponse(
        request,
        "index.html",
        {
            "error": error,
            "nodes_total": nodes_total,
            "nodes_ready": nodes_ready,
            "memory_used_pct": memory_used_pct,
            "pods_by_phase": pods_by_phase,
            "refresh_seconds": REFRESH_SECONDS,
        },
    )


@app.get("/healthz")
async def healthz():
    return {"status": "ok"}
