from datetime import date, datetime, time, timedelta, timezone
from typing import Dict, List, Optional, Set, Tuple
import math
import os

from fastapi import APIRouter, Depends, Header, HTTPException, Query
from sqlalchemy.orm import Session

from ..database import get_db
from ..models import Drive, PlaceVisit


router = APIRouter()

# Require API key from environment; fail fast if missing
API_KEY = os.getenv("LIFE247_API_KEY")
if not API_KEY:
    raise RuntimeError("LIFE247_API_KEY must be set")

UTC = timezone.utc
MILES_PER_METER = 0.000621371
MICRO_TRIP_METERS = 0.2 * 1609.344


def verify_api_key(x_api_key: str = Header(...)):
    """Dependency to verify API key"""
    if x_api_key != API_KEY:
        raise HTTPException(status_code=401, detail="Invalid API key")
    return x_api_key


def parse_range(
    start: Optional[str],
    end: Optional[str],
    tz_offset_minutes: int,
) -> Tuple[date, date, datetime, datetime, timezone]:
    """Parse local date range and convert to UTC-naive datetimes for DB filtering."""
    if tz_offset_minutes < -720 or tz_offset_minutes > 840:
        raise HTTPException(status_code=400, detail="tzOffsetMinutes must be between -720 and 840")

    tz = timezone(timedelta(minutes=tz_offset_minutes))
    local_today = datetime.now(UTC).astimezone(tz).date()

    try:
        end_date = date.fromisoformat(end) if end else local_today
        start_date = date.fromisoformat(start) if start else (end_date - timedelta(days=29))
    except ValueError:
        raise HTTPException(status_code=400, detail="start and end must be ISO dates (YYYY-MM-DD)")

    if start_date > end_date:
        raise HTTPException(status_code=400, detail="start must be on or before end")

    local_start = datetime.combine(start_date, time.min, tzinfo=tz)
    local_end_exclusive = datetime.combine(end_date + timedelta(days=1), time.min, tzinfo=tz)

    # SQLite stores datetimes as naive values in this project. Normalize to naive UTC.
    utc_start = local_start.astimezone(UTC).replace(tzinfo=None)
    utc_end_exclusive = local_end_exclusive.astimezone(UTC).replace(tzinfo=None)

    return start_date, end_date, utc_start, utc_end_exclusive, tz


def to_local(dt: Optional[datetime], tz: timezone) -> Optional[datetime]:
    if dt is None:
        return None
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=UTC)
    return dt.astimezone(tz)


def percentile(values: List[float], p: float) -> Optional[float]:
    if not values:
        return None
    sorted_values = sorted(values)
    idx = max(0, math.ceil(len(sorted_values) * p) - 1)
    return sorted_values[idx]


def filtered_drives(
    db: Session,
    utc_start: datetime,
    utc_end_exclusive: datetime,
    device_id: Optional[str],
) -> List[Drive]:
    query = db.query(Drive).filter(
        Drive.startTime.is_not(None),
        Drive.startTime >= utc_start,
        Drive.startTime < utc_end_exclusive,
    )
    if device_id:
        query = query.filter(Drive.deviceId == device_id)
    return query.all()


def compute_drive_day_streaks(active_days: Set[date], end_date: date) -> Tuple[int, int]:
    if not active_days:
        return 0, 0

    ordered_days = sorted(active_days)

    longest = 1
    running = 1
    for i in range(1, len(ordered_days)):
        if ordered_days[i] == ordered_days[i - 1] + timedelta(days=1):
            running += 1
        else:
            running = 1
        longest = max(longest, running)

    current = 0
    cursor = end_date
    while cursor in active_days:
        current += 1
        cursor -= timedelta(days=1)

    return longest, current


@router.get("/stats/overview")
def stats_overview(
    start: Optional[str] = None,
    end: Optional[str] = None,
    deviceId: Optional[str] = None,
    tzOffsetMinutes: int = 0,
    db: Session = Depends(get_db),
    _: str = Depends(verify_api_key),
):
    start_date, end_date, utc_start, utc_end_exclusive, tz = parse_range(start, end, tzOffsetMinutes)
    drives = filtered_drives(db, utc_start, utc_end_exclusive, deviceId)

    drive_count = len(drives)
    total_distance = sum(d.distanceMeters or 0 for d in drives)
    total_duration = sum(d.durationSeconds or 0 for d in drives)
    avg_drive_distance = total_distance / drive_count if drive_count else 0
    avg_drive_duration = total_duration / drive_count if drive_count else 0

    avg_speed_values = [d.avgSpeedMPH for d in drives if d.avgSpeedMPH is not None]
    avg_speed = sum(avg_speed_values) / len(avg_speed_values) if avg_speed_values else 0

    max_speed_values = [d.maxSpeedMPH for d in drives if d.maxSpeedMPH is not None]
    max_speed = max(max_speed_values) if max_speed_values else 0
    max_gforce_values = [d.maxGForce for d in drives if d.maxGForce is not None]
    max_gforce = max(max_gforce_values) if max_gforce_values else 0

    hard_brake = sum(d.hardBrakeCount or 0 for d in drives)
    hard_accel = sum(d.hardAccelCount or 0 for d in drives)
    hard_corner = sum(d.hardCornerCount or 0 for d in drives)
    total_events = hard_brake + hard_accel + hard_corner

    total_miles = total_distance * MILES_PER_METER
    event_rate_per_100_miles = (total_events / (total_miles / 100.0)) if total_miles > 0 else 0

    # Ignore missing battery fields and charging sessions (negative drain)
    battery_rates = []
    for drive in drives:
        if (
            drive.batteryLevelAtStart is None
            or drive.batteryLevelAtEnd is None
            or not drive.durationSeconds
            or drive.durationSeconds <= 0
        ):
            continue
        drain_percent = (drive.batteryLevelAtStart - drive.batteryLevelAtEnd) * 100.0
        if drain_percent < 0:
            continue
        battery_rates.append(drain_percent / (drive.durationSeconds / 3600.0))

    avg_battery_drain_per_hour = (
        sum(battery_rates) / len(battery_rates) if battery_rates else 0
    )

    detection_values = [d.detectionLatencyMs for d in drives if d.detectionLatencyMs is not None]
    confirmation_values = [d.confirmationLatencyMs for d in drives if d.confirmationLatencyMs is not None]
    gap_values = [d.maxGapBetweenSamplesMs for d in drives if d.maxGapBetweenSamplesMs is not None]

    dropped_sample_rates = []
    for drive in drives:
        if drive.locationSampleCount and drive.locationSampleCount > 0 and drive.droppedSampleCount is not None:
            dropped_sample_rates.append(drive.droppedSampleCount / drive.locationSampleCount)

    active_days = {
        to_local(d.startTime, tz).date()
        for d in drives
        if d.startTime is not None and to_local(d.startTime, tz) is not None
    }
    longest_streak, current_streak = compute_drive_day_streaks(active_days, end_date)

    micro_trip_count = sum(
        1
        for d in drives
        if (d.distanceMeters or 0) < MICRO_TRIP_METERS or (d.durationSeconds or 0) < 120
    )

    device_ids = sorted({d.deviceId for d in drives if d.deviceId})

    return {
        "range": {
            "start": start_date.isoformat(),
            "end": end_date.isoformat(),
            "tzOffsetMinutes": tzOffsetMinutes,
        },
        "deviceIds": device_ids,
        "driveCount": drive_count,
        "microTripCount": micro_trip_count,
        "totalDistanceMeters": total_distance,
        "totalDurationSeconds": total_duration,
        "avgDriveDistanceMeters": avg_drive_distance,
        "avgDriveDurationSeconds": avg_drive_duration,
        "avgSpeedMPH": avg_speed,
        "maxSpeedMPH": max_speed,
        "maxGForce": max_gforce,
        "eventCounts": {
            "hardBrake": hard_brake,
            "hardAccel": hard_accel,
            "hardCorner": hard_corner,
            "total": total_events,
        },
        "eventRatePer100Miles": event_rate_per_100_miles,
        "avgBatteryDrainPerHour": avg_battery_drain_per_hour,
        "quality": {
            "avgDetectionLatencyMs": (sum(detection_values) / len(detection_values)) if detection_values else 0,
            "avgConfirmationLatencyMs": (sum(confirmation_values) / len(confirmation_values)) if confirmation_values else 0,
            "avgDroppedSampleRate": (sum(dropped_sample_rates) / len(dropped_sample_rates)) if dropped_sample_rates else 0,
            "p95MaxGapMs": percentile(gap_values, 0.95) or 0,
        },
        "longestDriveDayStreak": longest_streak,
        "currentDriveDayStreak": current_streak,
    }


@router.get("/stats/activity")
def stats_activity(
    start: Optional[str] = None,
    end: Optional[str] = None,
    deviceId: Optional[str] = None,
    tzOffsetMinutes: int = 0,
    bucket: str = Query("day", pattern="^(day|week)$"),
    db: Session = Depends(get_db),
    _: str = Depends(verify_api_key),
):
    _, _, utc_start, utc_end_exclusive, tz = parse_range(start, end, tzOffsetMinutes)
    drives = filtered_drives(db, utc_start, utc_end_exclusive, deviceId)

    grouped: Dict[str, Dict[str, float]] = {}

    for drive in drives:
        local_dt = to_local(drive.startTime, tz)
        if not local_dt:
            continue

        if bucket == "week":
            week_start = local_dt.date() - timedelta(days=local_dt.weekday())
            key = week_start.isoformat()
        else:
            key = local_dt.date().isoformat()

        events = (drive.hardBrakeCount or 0) + (drive.hardAccelCount or 0) + (drive.hardCornerCount or 0)

        if key not in grouped:
            grouped[key] = {
                "driveCount": 0,
                "distanceMeters": 0.0,
                "durationSeconds": 0.0,
                "eventCount": 0.0,
            }

        grouped[key]["driveCount"] += 1
        grouped[key]["distanceMeters"] += float(drive.distanceMeters or 0)
        grouped[key]["durationSeconds"] += float(drive.durationSeconds or 0)
        grouped[key]["eventCount"] += float(events)

    rows = []
    for key in sorted(grouped.keys()):
        row = grouped[key]
        rows.append(
            {
                "date": key,
                "driveCount": int(row["driveCount"]),
                "distanceMeters": row["distanceMeters"],
                "durationSeconds": row["durationSeconds"],
                "eventCount": int(row["eventCount"]),
            }
        )

    return rows


@router.get("/stats/habits")
def stats_habits(
    start: Optional[str] = None,
    end: Optional[str] = None,
    deviceId: Optional[str] = None,
    tzOffsetMinutes: int = 0,
    db: Session = Depends(get_db),
    _: str = Depends(verify_api_key),
):
    _, end_date, utc_start, utc_end_exclusive, tz = parse_range(start, end, tzOffsetMinutes)
    drives = filtered_drives(db, utc_start, utc_end_exclusive, deviceId)

    by_weekday: Dict[int, Dict[str, float]] = {i: {"driveCount": 0, "distanceMeters": 0.0} for i in range(7)}
    by_hour: Dict[int, Dict[str, float]] = {i: {"driveCount": 0, "distanceMeters": 0.0} for i in range(24)}
    heatmap: Dict[Tuple[int, int], int] = {(weekday, hour): 0 for hour in range(24) for weekday in range(7)}

    active_days: Set[date] = set()
    micro_trip_count = 0

    for drive in drives:
        local_dt = to_local(drive.startTime, tz)
        if not local_dt:
            continue

        weekday_js = (local_dt.weekday() + 1) % 7  # Sunday=0
        hour = local_dt.hour

        by_weekday[weekday_js]["driveCount"] += 1
        by_weekday[weekday_js]["distanceMeters"] += float(drive.distanceMeters or 0)

        by_hour[hour]["driveCount"] += 1
        by_hour[hour]["distanceMeters"] += float(drive.distanceMeters or 0)
        heatmap[(weekday_js, hour)] += 1

        active_days.add(local_dt.date())

        if (drive.distanceMeters or 0) < MICRO_TRIP_METERS or (drive.durationSeconds or 0) < 120:
            micro_trip_count += 1

    longest_streak, current_streak = compute_drive_day_streaks(active_days, end_date)

    return {
        "byWeekday": [
            {
                "weekday": i,
                "driveCount": int(by_weekday[i]["driveCount"]),
                "distanceMeters": by_weekday[i]["distanceMeters"],
            }
            for i in range(7)
        ],
        "byHour": [
            {
                "hour": i,
                "driveCount": int(by_hour[i]["driveCount"]),
                "distanceMeters": by_hour[i]["distanceMeters"],
            }
            for i in range(24)
        ],
        "heatmap": [
            {
                "weekday": weekday,
                "hour": hour,
                "driveCount": heatmap[(weekday, hour)],
            }
            for hour in range(24)
            for weekday in range(7)
        ],
        "microTripCount": micro_trip_count,
        "totalActiveDays": len(active_days),
        "longestDriveDayStreak": longest_streak,
        "currentDriveDayStreak": current_streak,
    }


@router.get("/stats/places")
def stats_places(
    start: Optional[str] = None,
    end: Optional[str] = None,
    deviceId: Optional[str] = None,
    limit: int = Query(10, ge=1, le=100),
    tzOffsetMinutes: int = 0,
    db: Session = Depends(get_db),
    _: str = Depends(verify_api_key),
):
    _, _, utc_start, utc_end_exclusive, _ = parse_range(start, end, tzOffsetMinutes)

    query = db.query(PlaceVisit).filter(
        PlaceVisit.arrivalTime.is_not(None),
        PlaceVisit.arrivalTime >= utc_start,
        PlaceVisit.arrivalTime < utc_end_exclusive,
    )
    if deviceId:
        query = query.filter(PlaceVisit.deviceId == deviceId)

    visits = query.all()

    grouped: Dict[str, Dict[str, object]] = {}

    for visit in visits:
        place_name = visit.placeName or "Unknown"
        if place_name not in grouped:
            grouped[place_name] = {
                "placeName": place_name,
                "placeIcon": visit.placeIcon or "mappin.circle.fill",
                "visitCount": 0,
                "totalDwellSeconds": 0.0,
                "lastVisited": None,
            }

        duration_seconds = float(visit.durationSeconds or 0)
        if duration_seconds <= 0 and visit.arrivalTime and visit.departureTime:
            duration_seconds = max(0.0, (visit.departureTime - visit.arrivalTime).total_seconds())

        grouped[place_name]["visitCount"] = int(grouped[place_name]["visitCount"]) + 1
        grouped[place_name]["totalDwellSeconds"] = float(grouped[place_name]["totalDwellSeconds"]) + duration_seconds

        latest = visit.departureTime or visit.arrivalTime
        current_latest = grouped[place_name]["lastVisited"]
        if latest and (current_latest is None or latest > current_latest):
            grouped[place_name]["lastVisited"] = latest

    rows = []
    for row in grouped.values():
        visit_count = int(row["visitCount"])
        total_dwell = float(row["totalDwellSeconds"])
        last_visited = row["lastVisited"]
        rows.append(
            {
                "placeName": row["placeName"],
                "placeIcon": row["placeIcon"],
                "visitCount": visit_count,
                "totalDwellSeconds": total_dwell,
                "avgDwellSeconds": (total_dwell / visit_count) if visit_count else 0,
                "lastVisited": (
                    last_visited.replace(tzinfo=UTC).isoformat() if isinstance(last_visited, datetime) else None
                ),
            }
        )

    rows.sort(key=lambda x: (x["totalDwellSeconds"], x["visitCount"]), reverse=True)
    return rows[:limit]
