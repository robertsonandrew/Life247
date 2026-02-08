from datetime import UTC, datetime, timedelta
from uuid import uuid4

import pytest

from app.models import Drive, PlaceVisit


def add_drive(
    db_session,
    *,
    start_time: datetime,
    duration_seconds: float,
    distance_meters: float,
    device_id: str = "device-1",
    avg_speed_mph: float = 0,
    max_speed_mph: float = 0,
    hard_brake: int = 0,
    hard_accel: int = 0,
    hard_corner: int = 0,
    max_gforce: float | None = None,
    detection_ms: int | None = None,
    confirmation_ms: int | None = None,
    sample_count: int | None = None,
    dropped_count: int | None = None,
    max_gap_ms: int | None = None,
    battery_start: float | None = None,
    battery_end: float | None = None,
):
    drive = Drive(
        driveId=str(uuid4()),
        deviceId=device_id,
        startTime=start_time,
        endTime=start_time + timedelta(seconds=duration_seconds),
        durationSeconds=duration_seconds,
        distanceMeters=distance_meters,
        avgSpeedMPH=avg_speed_mph,
        maxSpeedMPH=max_speed_mph,
        polyline="",
        pointCount=0,
        simplifiedPointCount=0,
        speeds=[],
        hardBrakeCount=hard_brake,
        hardAccelCount=hard_accel,
        hardCornerCount=hard_corner,
        maxGForce=max_gforce,
        detectionLatencyMs=detection_ms,
        confirmationLatencyMs=confirmation_ms,
        locationSampleCount=sample_count,
        droppedSampleCount=dropped_count,
        maxGapBetweenSamplesMs=max_gap_ms,
        batteryLevelAtStart=battery_start,
        batteryLevelAtEnd=battery_end,
        uploadedAt=datetime.now(UTC).replace(tzinfo=None),
    )
    db_session.add(drive)
    db_session.commit()
    return drive


def add_visit(
    db_session,
    *,
    place_name: str,
    arrival: datetime,
    duration_seconds: float,
    device_id: str = "device-1",
    place_icon: str = "house.fill",
):
    visit = PlaceVisit(
        visitId=str(uuid4()),
        deviceId=device_id,
        arrivalTime=arrival,
        departureTime=arrival + timedelta(seconds=duration_seconds),
        durationSeconds=duration_seconds,
        placeName=place_name,
        placeIcon=place_icon,
        placeRadiusMeters=100,
        placeLatitude=35.0,
        placeLongitude=-95.0,
        latitude=35.0,
        longitude=-95.0,
        source="clvisit",
        uploadedAt=datetime.now(UTC).replace(tzinfo=None),
    )
    db_session.add(visit)
    db_session.commit()
    return visit


def test_stats_overview_empty_returns_zeroes(client, auth_headers):
    response = client.get(
        "/stats/overview",
        params={"start": "2026-01-01", "end": "2026-01-31", "tzOffsetMinutes": 0},
        headers=auth_headers,
    )

    assert response.status_code == 200
    payload = response.json()

    assert payload["driveCount"] == 0
    assert payload["totalDistanceMeters"] == 0
    assert payload["totalDurationSeconds"] == 0
    assert payload["eventCounts"]["total"] == 0
    assert payload["quality"]["avgDroppedSampleRate"] == 0


def test_stats_overview_computes_expected_metrics(client, db_session, auth_headers):
    add_drive(
        db_session,
        start_time=datetime(2026, 1, 1, 8, 0, 0),
        duration_seconds=3600,
        distance_meters=1609.344,
        avg_speed_mph=1,
        max_speed_mph=10,
        hard_brake=1,
        hard_corner=1,
        max_gforce=0.6,
        detection_ms=1000,
        confirmation_ms=2000,
        sample_count=100,
        dropped_count=10,
        max_gap_ms=1000,
        battery_start=0.80,
        battery_end=0.75,
    )
    add_drive(
        db_session,
        start_time=datetime(2026, 1, 2, 8, 0, 0),
        duration_seconds=1800,
        distance_meters=3218.688,
        avg_speed_mph=4,
        max_speed_mph=20,
        hard_accel=1,
        max_gforce=0.9,
        detection_ms=3000,
        confirmation_ms=4000,
        sample_count=50,
        dropped_count=5,
        max_gap_ms=5000,
        battery_start=0.50,
        battery_end=0.49,
    )

    response = client.get(
        "/stats/overview",
        params={"start": "2026-01-01", "end": "2026-01-02", "tzOffsetMinutes": 0},
        headers=auth_headers,
    )

    assert response.status_code == 200
    payload = response.json()

    assert payload["driveCount"] == 2
    assert payload["totalDistanceMeters"] == pytest.approx(4828.032)
    assert payload["avgDriveDurationSeconds"] == pytest.approx(2700)
    assert payload["avgSpeedMPH"] == pytest.approx(2.5)
    assert payload["maxSpeedMPH"] == pytest.approx(20)
    assert payload["maxGForce"] == pytest.approx(0.9)
    assert payload["eventCounts"]["total"] == 3
    assert payload["eventRatePer100Miles"] == pytest.approx(100)
    assert payload["avgBatteryDrainPerHour"] == pytest.approx(3.5)
    assert payload["quality"]["avgDetectionLatencyMs"] == pytest.approx(2000)
    assert payload["quality"]["avgConfirmationLatencyMs"] == pytest.approx(3000)
    assert payload["quality"]["avgDroppedSampleRate"] == pytest.approx(0.1)
    assert payload["quality"]["p95MaxGapMs"] == pytest.approx(5000)
    assert payload["microTripCount"] == 0
    assert payload["longestDriveDayStreak"] == 2
    assert payload["currentDriveDayStreak"] == 2


def test_stats_activity_respects_date_range_and_tz_offset(client, db_session, auth_headers):
    # UTC 04:30 becomes previous local day at -300 offset.
    add_drive(
        db_session,
        start_time=datetime(2026, 2, 1, 4, 30, 0),
        duration_seconds=600,
        distance_meters=2000,
        avg_speed_mph=20,
        max_speed_mph=35,
    )
    # UTC 06:00 stays on local 2026-02-01 at -300 offset.
    add_drive(
        db_session,
        start_time=datetime(2026, 2, 1, 6, 0, 0),
        duration_seconds=600,
        distance_meters=3000,
        avg_speed_mph=22,
        max_speed_mph=40,
    )

    response = client.get(
        "/stats/activity",
        params={
            "start": "2026-02-01",
            "end": "2026-02-01",
            "tzOffsetMinutes": -300,
            "bucket": "day",
        },
        headers=auth_headers,
    )

    assert response.status_code == 200
    payload = response.json()
    assert len(payload) == 1
    assert payload[0]["date"] == "2026-02-01"
    assert payload[0]["driveCount"] == 1
    assert payload[0]["distanceMeters"] == pytest.approx(3000)


def test_stats_habits_returns_heatmap_and_streaks(client, db_session, auth_headers):
    add_drive(
        db_session,
        start_time=datetime(2026, 1, 4, 8, 0, 0),
        duration_seconds=600,
        distance_meters=1000,
    )
    add_drive(
        db_session,
        start_time=datetime(2026, 1, 5, 8, 0, 0),
        duration_seconds=600,
        distance_meters=1000,
    )
    add_drive(
        db_session,
        start_time=datetime(2026, 1, 5, 9, 0, 0),
        duration_seconds=60,
        distance_meters=100,
    )

    response = client.get(
        "/stats/habits",
        params={"start": "2026-01-04", "end": "2026-01-05", "tzOffsetMinutes": 0},
        headers=auth_headers,
    )

    assert response.status_code == 200
    payload = response.json()

    assert len(payload["byWeekday"]) == 7
    assert len(payload["byHour"]) == 24
    assert len(payload["heatmap"]) == 168
    assert payload["microTripCount"] == 1
    assert payload["longestDriveDayStreak"] == 2
    assert payload["currentDriveDayStreak"] == 2


def test_stats_places_aggregates_by_place_name(client, db_session, auth_headers):
    add_visit(
        db_session,
        place_name="Home",
        arrival=datetime(2026, 1, 10, 12, 0, 0),
        duration_seconds=3600,
    )
    add_visit(
        db_session,
        place_name="Home",
        arrival=datetime(2026, 1, 11, 12, 0, 0),
        duration_seconds=1800,
    )
    add_visit(
        db_session,
        place_name="Work",
        arrival=datetime(2026, 1, 11, 9, 0, 0),
        duration_seconds=1200,
        place_icon="building.2.fill",
    )

    response = client.get(
        "/stats/places",
        params={"start": "2026-01-01", "end": "2026-01-31", "limit": 10},
        headers=auth_headers,
    )

    assert response.status_code == 200
    payload = response.json()

    assert len(payload) == 2
    assert payload[0]["placeName"] == "Home"
    assert payload[0]["visitCount"] == 2
    assert payload[0]["totalDwellSeconds"] == pytest.approx(5400)
    assert payload[0]["avgDwellSeconds"] == pytest.approx(2700)


def test_drives_summary_paginates_and_returns_expected_fields(client, db_session, auth_headers):
    add_drive(
        db_session,
        start_time=datetime(2026, 1, 1, 8, 0, 0),
        duration_seconds=600,
        distance_meters=1000,
        battery_start=0.8,
        battery_end=0.79,
    )
    add_drive(
        db_session,
        start_time=datetime(2026, 1, 2, 8, 0, 0),
        duration_seconds=600,
        distance_meters=2000,
    )
    add_drive(
        db_session,
        start_time=datetime(2026, 1, 3, 8, 0, 0),
        duration_seconds=600,
        distance_meters=3000,
    )

    first = client.get(
        "/drives/summary",
        params={"start": "2026-01-01", "end": "2026-01-31", "limit": 2, "offset": 0},
        headers=auth_headers,
    )
    second = client.get(
        "/drives/summary",
        params={"start": "2026-01-01", "end": "2026-01-31", "limit": 2, "offset": 2},
        headers=auth_headers,
    )

    assert first.status_code == 200
    assert second.status_code == 200

    first_payload = first.json()
    second_payload = second.json()

    assert len(first_payload) == 2
    assert len(second_payload) == 1

    expected_keys = {
        "driveId",
        "deviceId",
        "startTime",
        "endTime",
        "distanceMeters",
        "durationSeconds",
        "avgSpeedMPH",
        "maxSpeedMPH",
        "eventCount",
        "batteryDrainPercent",
    }
    assert expected_keys.issubset(first_payload[0].keys())


def test_drive_detail_includes_speeds_array(client, db_session, auth_headers):
    drive = Drive(
        driveId=str(uuid4()),
        deviceId="device-1",
        startTime=datetime(2026, 1, 7, 8, 0, 0),
        endTime=datetime(2026, 1, 7, 8, 10, 0),
        durationSeconds=600,
        distanceMeters=2500,
        avgSpeedMPH=25,
        maxSpeedMPH=40,
        polyline="",
        pointCount=10,
        simplifiedPointCount=4,
        speeds=[22.5, 26.0, 24.3, 31.2],
        uploadedAt=datetime.now(UTC).replace(tzinfo=None),
    )
    db_session.add(drive)
    db_session.commit()

    response = client.get(f"/drives/{drive.driveId}", headers=auth_headers)
    assert response.status_code == 200
    payload = response.json()
    assert payload["speeds"] == [22.5, 26.0, 24.3, 31.2]
