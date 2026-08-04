import asyncio

import httpx
import main
import pytest
import respx
from fastapi.testclient import TestClient

client = TestClient(main.app)


def test_healthz():
    response = client.get("/healthz")
    assert response.status_code == 200
    assert response.json() == {"status": "ok"}


def test_scalar_returns_default_on_empty_result():
    assert main.scalar([]) == "?"


def test_scalar_returns_custom_default_on_empty_result():
    assert main.scalar([], default="n/a") == "n/a"


def test_scalar_extracts_value_from_result():
    result = [{"metric": {}, "value": [1690000000, "3"]}]
    assert main.scalar(result) == "3"


def test_query_prometheus_raises_on_http_error():
    async def run():
        with respx.mock:
            respx.get(f"{main.PROMETHEUS_URL}/api/v1/query").mock(
                return_value=httpx.Response(500)
            )
            async with httpx.AsyncClient() as http_client:
                with pytest.raises(httpx.HTTPStatusError):
                    await main.query_prometheus(http_client, "up")

    asyncio.run(run())


def _scalar_response(value: str) -> dict:
    return {"data": {"result": [{"metric": {}, "value": [1690000000, value]}]}}


def _pods_response() -> dict:
    return {
        "data": {
            "result": [
                {"metric": {"phase": "Running"}, "value": [1690000000, "5"]},
                {"metric": {"phase": "Pending"}, "value": [1690000000, "1"]},
            ]
        }
    }


def test_index_happy_path():
    with respx.mock:
        respx.get(
            f"{main.PROMETHEUS_URL}/api/v1/query",
            params={"query": main.QUERIES["nodes_total"]},
        ).mock(return_value=httpx.Response(200, json=_scalar_response("3")))
        respx.get(
            f"{main.PROMETHEUS_URL}/api/v1/query",
            params={"query": main.QUERIES["nodes_ready"]},
        ).mock(return_value=httpx.Response(200, json=_scalar_response("3")))
        respx.get(
            f"{main.PROMETHEUS_URL}/api/v1/query",
            params={"query": main.QUERIES["pods_by_phase"]},
        ).mock(return_value=httpx.Response(200, json=_pods_response()))
        respx.get(
            f"{main.PROMETHEUS_URL}/api/v1/query",
            params={"query": main.QUERIES["memory_used_pct"]},
        ).mock(return_value=httpx.Response(200, json=_scalar_response("42.5")))

        response = client.get("/")

    assert response.status_code == 200
    assert "3 / 3" in response.text
    assert "42.5%" in response.text
    assert "Running" in response.text
    assert "Pending" in response.text
    assert "Could not reach Prometheus" not in response.text


def test_index_prometheus_unreachable():
    with respx.mock:
        respx.get(f"{main.PROMETHEUS_URL}/api/v1/query").mock(
            side_effect=httpx.ConnectError("connection refused")
        )
        response = client.get("/")

    assert response.status_code == 200
    assert "Could not reach Prometheus" in response.text


def test_index_malformed_response_missing_result_key():
    with respx.mock:
        respx.get(f"{main.PROMETHEUS_URL}/api/v1/query").mock(
            return_value=httpx.Response(200, json={"data": {}})
        )
        response = client.get("/")

    assert response.status_code == 200
    assert "Could not reach Prometheus" in response.text
