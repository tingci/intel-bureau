"""手动出报（按日期/区间）接口：校验、区间展开、默认不投递。

这里不启动真实流水线（会很慢且要联网），只验证接口把日期展开成"每天一份"的任务清单，
以及各种非法输入给出可读的 400。真正跑一次由人工在界面上验证。
"""

from __future__ import annotations

from datetime import date, timedelta

import pytest
from fastapi.testclient import TestClient

from bureau.api import create_app

BASE = "http://127.0.0.1:8765"


@pytest.fixture
def client(app):
    with TestClient(create_app(app, background=False), base_url=BASE) as c:
        c.token = c.get("/api/session").json()["token"]
        c.headers.update({"X-Bureau-Token": c.token})
        yield c


def _today(app) -> date:
    return app.now().date()


def test_single_day_expands_to_one(client, app):
    d = _today(app) - timedelta(days=3)
    r = client.post("/api/runs/manual", json={"date": d.isoformat(), "platforms": ["wechat"], "dry_run": True})
    assert r.status_code == 202, r.text
    body = r.json()
    assert body["total"] == 1 and body["dates"] == [d.isoformat()]
    assert body["dry_run"] is True


def test_range_expands_to_each_day(client, app):
    end = _today(app) - timedelta(days=1)
    start = end - timedelta(days=2)                       # 3 天：start, +1, +2
    r = client.post("/api/runs/manual",
                    json={"date_from": start.isoformat(), "date_to": end.isoformat(),
                          "platforms": ["wechat"], "dry_run": True})
    assert r.status_code == 202, r.text
    body = r.json()
    assert body["total"] == 3
    assert body["dates"] == [(start + timedelta(days=i)).isoformat() for i in range(3)]


def test_dry_run_defaults_to_true_when_omitted(client, app):
    """补历史默认只预览、不往通道推 —— 省略 dry_run 时必须按 True 处理。"""
    d = _today(app) - timedelta(days=2)
    r = client.post("/api/runs/manual", json={"date": d.isoformat(), "platforms": ["wechat"]})
    assert r.status_code == 202, r.text
    assert r.json()["dry_run"] is True


def test_future_date_rejected(client, app):
    d = _today(app) + timedelta(days=1)
    r = client.post("/api/runs/manual", json={"date": d.isoformat(), "platforms": ["wechat"]})
    assert r.status_code == 400
    assert r.json()["error"]["code"] == "invalid_date"


def test_inverted_range_rejected(client, app):
    end = _today(app) - timedelta(days=1)
    start = end + timedelta(days=2)
    r = client.post("/api/runs/manual",
                    json={"date_from": start.isoformat(), "date_to": end.isoformat(), "platforms": ["wechat"]})
    assert r.status_code == 400
    assert r.json()["error"]["code"] == "invalid_date"


def test_bad_date_format_rejected(client):
    r = client.post("/api/runs/manual", json={"date": "2026/11/17", "platforms": ["wechat"]})
    assert r.status_code == 400
    assert r.json()["error"]["code"] == "invalid_date"


def test_missing_dates_rejected(client):
    r = client.post("/api/runs/manual", json={"platforms": ["wechat"]})
    assert r.status_code == 400
    assert r.json()["error"]["code"] == "invalid_date"


def test_date_and_range_mutually_exclusive(client, app):
    d = _today(app) - timedelta(days=1)
    r = client.post("/api/runs/manual",
                    json={"date": d.isoformat(), "date_from": d.isoformat(), "date_to": d.isoformat(),
                          "platforms": ["wechat"]})
    assert r.status_code == 400
    assert r.json()["error"]["code"] == "invalid_date"


def test_too_many_days_rejected(client, app):
    end = _today(app) - timedelta(days=1)
    start = end - timedelta(days=40)                      # 41 天，超过 31 上限
    r = client.post("/api/runs/manual",
                    json={"date_from": start.isoformat(), "date_to": end.isoformat(), "platforms": ["wechat"]})
    assert r.status_code == 400
    assert r.json()["error"]["code"] == "too_many_days"


def test_unknown_platform_rejected(client, app):
    d = _today(app) - timedelta(days=1)
    r = client.post("/api/runs/manual", json={"date": d.isoformat(), "platforms": ["telegram"]})
    assert r.status_code == 400
    assert r.json()["error"]["code"] == "invalid_platform"
