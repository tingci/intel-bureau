"""运行窗口：since_last 取上次成功运行的 until（最多回溯 72 小时），首跑取 24 小时；fixed_hours 固定小时数；
按日期（date）取本地时区里那一整天 [00:00, 次日 00:00)。"""

from __future__ import annotations

from datetime import date as _date
from datetime import datetime, time, timedelta
from typing import Any

from bureau.core.timeutil import parse_iso, to_tz


def day_window(day: _date, tz: Any) -> tuple[datetime, datetime]:
    """本地时区里 day 这一整天：[当天 00:00, 次日 00:00)。

    tz 可以是 IANA 时区名（如 "Asia/Shanghai"）或 tzinfo 对象。
    end 取次日 00:00（而不是当天 23:59:59），这样 report_day(rc) 里 end-1 秒正好落在 day，
    报告目录和标题的日期都与所选日期一致。
    """
    start = datetime.combine(day, time.min)
    start = to_tz(start, tz) if isinstance(tz, str) else start.replace(tzinfo=tz)
    return start, start + timedelta(days=1)


def compute_window(app: Any, *, demo: bool, window_mode: str = "since_last", window_hours: int | None = None,
                   schedule_id: str | None = None, now: datetime | None = None,
                   window_start: datetime | None = None,
                   window_end: datetime | None = None) -> tuple[datetime, datetime]:
    # 显式窗口优先：按日期重跑历史时用，完全跳过 since_last / max_lookback 的推断。
    if window_start is not None and window_end is not None:
        if window_end <= window_start:
            raise ValueError("window_end 必须晚于 window_start")
        return window_start, window_end
    if demo:
        anchor = app.demo_anchor()
        end = anchor or (now or app.now()).replace(minute=0, second=0, microsecond=0)
        return end - timedelta(hours=int(window_hours or 24)), end
    end = (now or app.now()).replace(second=0, microsecond=0)
    max_back = int(app.config.get("sources.collect.max_lookback_hours", 72) or 72)
    # 定时任务按 window_mode；临时运行指定了 window_hours 就按固定小时数
    fixed = bool(window_hours) and (window_mode == "fixed_hours" or schedule_id is None)
    if fixed:
        hours = min(int(window_hours or 24), 24 * 31)
        return end - timedelta(hours=hours), end
    last = parse_iso(app.store.last_success_window_end(schedule_id=schedule_id), app.tz)
    if last is None and schedule_id is not None:
        last = parse_iso(app.store.last_success_window_end(), app.tz)
    if last is None:
        start = end - timedelta(hours=int(app.config.get("sources.collect.first_run_hours", 24) or 24))
    else:
        start = max(last, end - timedelta(hours=max_back))
    if end - start < timedelta(hours=1):          # 两次运行挨得太近时至少看 1 小时
        start = end - timedelta(hours=1)
    return start, end
