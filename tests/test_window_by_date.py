"""按日期重跑（--date）：窗口必须严格等于本地时区那一整天，且报告日期与所选日期一致。

这里的要害是 report_day(rc) 用 `rc.end - 1 秒` 推日期（见 bureau/pipeline/score.py），
所以 end 必须是「次日 00:00」而不是「当天 23:59:59」，否则报告会落到第二天。
"""

from __future__ import annotations

from datetime import date, datetime, timedelta
from zoneinfo import ZoneInfo

import pytest

from bureau.pipeline.window import compute_window, day_window

TZ = "Asia/Shanghai"


@pytest.mark.parametrize("day", ["2026-11-17", "2026-11-18", "2026-11-19", "2026-01-01", "2026-12-31"])
def test_day_window_covers_exactly_one_local_day(day: str):
    d = date.fromisoformat(day)
    start, end = day_window(d, TZ)
    assert start == datetime(d.year, d.month, d.day, 0, 0, 0, tzinfo=ZoneInfo(TZ))
    assert end - start == timedelta(days=1)
    assert end == start + timedelta(days=1)


@pytest.mark.parametrize("day", ["2026-11-17", "2026-11-18", "2026-11-19"])
def test_report_day_matches_requested_day(day: str):
    """报告日期（end-1s 所在日期）必须等于所选日期，否则报告会跑到第二天。"""
    d = date.fromisoformat(day)
    _start, end = day_window(d, TZ)
    report_day = (end - timedelta(seconds=1)).astimezone(ZoneInfo(TZ)).strftime("%Y-%m-%d")
    assert report_day == day


def test_day_window_accepts_tzinfo_too():
    tz = ZoneInfo(TZ)
    start, end = day_window(date(2026, 11, 17), tz)
    assert start.tzinfo is not None and end - start == timedelta(days=1)
    assert start.isoformat() == "2026-11-17T00:00:00+08:00"


def test_explicit_window_wins_over_since_last(app):
    """给了显式窗口就完全跳过 since_last / max_lookback 的推断。"""
    start, end = day_window(date(2026, 11, 17), TZ)
    got_start, got_end = compute_window(app, demo=False, window_start=start, window_end=end)
    assert (got_start, got_end) == (start, end)


def test_explicit_window_rejects_empty_and_inverted(app):
    start, end = day_window(date(2026, 11, 17), TZ)
    with pytest.raises(ValueError):
        compute_window(app, demo=False, window_start=start, window_end=start)
    with pytest.raises(ValueError):
        compute_window(app, demo=False, window_start=end, window_end=start)


def test_without_explicit_window_behaves_as_before(app):
    """没给窗口时走原有逻辑：窗口终点取「现在」，且不因为新参数而报错。"""
    got_start, got_end = compute_window(app, demo=False, window_hours=24)
    assert got_end - got_start == timedelta(hours=24)
    assert got_start < got_end
