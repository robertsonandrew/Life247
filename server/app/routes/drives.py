from fastapi import APIRouter, Header, HTTPException, Depends
from pydantic import BaseModel, ConfigDict
from sqlalchemy.orm import Session
from datetime import date, datetime, time, timedelta, timezone
from typing import Optional, List
import os

from ..database import get_db, engine, Base
from ..models import Drive

# Create tables
Base.metadata.create_all(bind=engine)

router = APIRouter()

# Require API key from environment; fail fast if missing
API_KEY = os.getenv("LIFE247_API_KEY")
if not API_KEY:
    raise RuntimeError("LIFE247_API_KEY must be set")


class DriveDTO(BaseModel):
    """Pydantic model for drive upload request"""
    driveId: str
    deviceId: str
    startTime: str
    endTime: str
    durationSeconds: float
    distanceMeters: float
    avgSpeedMPH: float
    maxSpeedMPH: float
    polyline: str
    pointCount: int
    simplifiedPointCount: int
    speeds: Optional[List[float]] = None
    startReason: Optional[str] = None
    endReason: Optional[str] = None
    deviceModel: Optional[str] = None
    iosVersion: Optional[str] = None
    appVersion: Optional[str] = None
    # Quality Metrics
    detectionLatencyMs: Optional[int] = None
    confirmationLatencyMs: Optional[int] = None
    locationSampleCount: Optional[int] = None
    droppedSampleCount: Optional[int] = None
    maxGapBetweenSamplesMs: Optional[int] = None
    locationPauseCount: Optional[int] = None
    bufferedPointCount: Optional[int] = None
    batteryLevelAtStart: Optional[float] = None
    batteryLevelAtEnd: Optional[float] = None
    lowPowerModeAtStart: Optional[bool] = None
    # G-Force Events
    accelerationEvents: Optional[List[dict]] = None
    hardBrakeCount: Optional[int] = None
    hardAccelCount: Optional[int] = None
    hardCornerCount: Optional[int] = None
    maxGForce: Optional[float] = None
    # Timeline Events
    logEntries: Optional[List[dict]] = None


class DriveResponse(BaseModel):
    """Response model for drive operations"""
    driveId: str
    deviceId: str
    startTime: str
    endTime: str
    durationSeconds: float
    distanceMeters: float
    avgSpeedMPH: float
    maxSpeedMPH: float
    polyline: str
    pointCount: int
    simplifiedPointCount: int
    speeds: Optional[List[float]] = None
    startReason: Optional[str] = None
    endReason: Optional[str] = None
    deviceModel: Optional[str] = None
    iosVersion: Optional[str] = None
    appVersion: Optional[str] = None
    # Quality Metrics
    detectionLatencyMs: Optional[int] = None
    confirmationLatencyMs: Optional[int] = None
    locationSampleCount: Optional[int] = None
    droppedSampleCount: Optional[int] = None
    maxGapBetweenSamplesMs: Optional[int] = None
    locationPauseCount: Optional[int] = None
    bufferedPointCount: Optional[int] = None
    batteryLevelAtStart: Optional[float] = None
    batteryLevelAtEnd: Optional[float] = None
    lowPowerModeAtStart: Optional[bool] = None
    # G-Force Events
    accelerationEvents: Optional[List[dict]] = None
    hardBrakeCount: Optional[int] = None
    hardAccelCount: Optional[int] = None
    hardCornerCount: Optional[int] = None
    maxGForce: Optional[float] = None
    # Timeline Events
    logEntries: Optional[List[dict]] = None

    model_config = ConfigDict(from_attributes=True)


class DriveSummaryResponse(BaseModel):
    """Lightweight response model for dashboard lists"""
    driveId: str
    deviceId: str
    startTime: str
    endTime: str
    distanceMeters: float
    durationSeconds: float
    avgSpeedMPH: float
    maxSpeedMPH: float
    eventCount: int
    batteryDrainPercent: Optional[float] = None
    polyline: Optional[str] = None


def verify_api_key(x_api_key: str = Header(...)):
    """Dependency to verify API key"""
    if x_api_key != API_KEY:
        raise HTTPException(status_code=401, detail="Invalid API key")
    return x_api_key


@router.post("/drives", response_model=dict)
def upload_drive(
    drive: DriveDTO, 
    db: Session = Depends(get_db),
    _: str = Depends(verify_api_key)
):
    """Upload a new drive"""
    # Check for duplicate
    existing = db.query(Drive).filter(Drive.driveId == drive.driveId).first()
    if existing:
        return {"status": "exists", "driveId": drive.driveId}
    
    # Parse timestamps
    try:
        start_time = datetime.fromisoformat(drive.startTime.replace("Z", "+00:00"))
        end_time = datetime.fromisoformat(drive.endTime.replace("Z", "+00:00"))
    except ValueError as e:
        raise HTTPException(status_code=400, detail=f"Invalid timestamp format: {e}")
    
    # Create drive entry
    drive_entry = Drive(
        driveId=drive.driveId,
        deviceId=drive.deviceId,
        startTime=start_time,
        endTime=end_time,
        durationSeconds=drive.durationSeconds,
        distanceMeters=drive.distanceMeters,
        avgSpeedMPH=drive.avgSpeedMPH,
        maxSpeedMPH=drive.maxSpeedMPH,
        polyline=drive.polyline,
        pointCount=drive.pointCount,
        simplifiedPointCount=drive.simplifiedPointCount,
        speeds=drive.speeds,
        startReason=drive.startReason,
        endReason=drive.endReason,
        deviceModel=drive.deviceModel,
        iosVersion=drive.iosVersion,
        appVersion=drive.appVersion,
        # Quality Metrics
        detectionLatencyMs=drive.detectionLatencyMs,
        confirmationLatencyMs=drive.confirmationLatencyMs,
        locationSampleCount=drive.locationSampleCount,
        droppedSampleCount=drive.droppedSampleCount,
        maxGapBetweenSamplesMs=drive.maxGapBetweenSamplesMs,
        locationPauseCount=drive.locationPauseCount,
        batteryLevelAtStart=drive.batteryLevelAtStart,
        batteryLevelAtEnd=drive.batteryLevelAtEnd,
        lowPowerModeAtStart=drive.lowPowerModeAtStart,
        # G-Force Events
        accelerationEvents=drive.accelerationEvents,
        hardBrakeCount=drive.hardBrakeCount,
        hardAccelCount=drive.hardAccelCount,
        hardCornerCount=drive.hardCornerCount,
        maxGForce=drive.maxGForce,
        # Timeline Events
        logEntries=drive.logEntries,
        uploadedAt=datetime.utcnow()
    )
    
    db.add(drive_entry)
    db.commit()
    
    return {"status": "success", "driveId": drive.driveId}


@router.get("/drives", response_model=List[DriveResponse])
def list_drives(
    limit: int = 50,
    offset: int = 0,
    db: Session = Depends(get_db),
    _: str = Depends(verify_api_key)
):
    """List all drives (paginated)"""
    drives = db.query(Drive).order_by(Drive.startTime.desc()).offset(offset).limit(limit).all()
    
    return [
        DriveResponse(
            driveId=d.driveId,
            deviceId=d.deviceId,
            startTime=d.startTime.replace(tzinfo=timezone.utc).isoformat() if d.startTime else "",
            endTime=d.endTime.replace(tzinfo=timezone.utc).isoformat() if d.endTime else "",
            durationSeconds=d.durationSeconds,
            distanceMeters=d.distanceMeters,
            avgSpeedMPH=d.avgSpeedMPH,
            maxSpeedMPH=d.maxSpeedMPH,
            polyline=d.polyline,
            pointCount=d.pointCount,
            simplifiedPointCount=d.simplifiedPointCount,
            speeds=d.speeds,
            startReason=d.startReason,
            endReason=d.endReason,
            deviceModel=d.deviceModel,
            iosVersion=d.iosVersion,
            appVersion=d.appVersion,
            detectionLatencyMs=d.detectionLatencyMs,
            confirmationLatencyMs=d.confirmationLatencyMs,
            locationSampleCount=d.locationSampleCount,
            droppedSampleCount=d.droppedSampleCount,
            maxGapBetweenSamplesMs=d.maxGapBetweenSamplesMs,
            locationPauseCount=d.locationPauseCount,
            batteryLevelAtStart=d.batteryLevelAtStart,
            batteryLevelAtEnd=d.batteryLevelAtEnd,
            lowPowerModeAtStart=d.lowPowerModeAtStart,
            accelerationEvents=d.accelerationEvents,
            hardBrakeCount=d.hardBrakeCount,
            hardAccelCount=d.hardAccelCount,
            hardCornerCount=d.hardCornerCount,
            maxGForce=d.maxGForce,
            logEntries=d.logEntries
        )
        for d in drives
    ]


@router.get("/drives/summary", response_model=List[DriveSummaryResponse])
def list_drive_summaries(
    start: Optional[str] = None,
    end: Optional[str] = None,
    deviceId: Optional[str] = None,
    limit: int = 50,
    offset: int = 0,
    db: Session = Depends(get_db),
    _: str = Depends(verify_api_key),
):
    """List lightweight drive summaries for dashboard cards."""
    query = db.query(Drive).filter(Drive.startTime.is_not(None))

    try:
        if start:
            start_date = date.fromisoformat(start)
            start_dt = datetime.combine(start_date, time.min)
            query = query.filter(Drive.startTime >= start_dt)
        if end:
            end_date = date.fromisoformat(end)
            end_exclusive = datetime.combine(end_date + timedelta(days=1), time.min)
            query = query.filter(Drive.startTime < end_exclusive)
    except ValueError:
        raise HTTPException(status_code=400, detail="start and end must be ISO dates (YYYY-MM-DD)")

    if deviceId:
        query = query.filter(Drive.deviceId == deviceId)

    drives = query.order_by(Drive.startTime.desc()).offset(offset).limit(limit).all()

    return [
        DriveSummaryResponse(
            driveId=d.driveId,
            deviceId=d.deviceId,
            startTime=d.startTime.replace(tzinfo=timezone.utc).isoformat() if d.startTime else "",
            endTime=d.endTime.replace(tzinfo=timezone.utc).isoformat() if d.endTime else "",
            distanceMeters=d.distanceMeters,
            durationSeconds=d.durationSeconds,
            avgSpeedMPH=d.avgSpeedMPH,
            maxSpeedMPH=d.maxSpeedMPH,
            eventCount=(d.hardBrakeCount or 0) + (d.hardAccelCount or 0) + (d.hardCornerCount or 0),
            batteryDrainPercent=(
                round((d.batteryLevelAtStart - d.batteryLevelAtEnd) * 100.0, 2)
                if d.batteryLevelAtStart is not None and d.batteryLevelAtEnd is not None
                else None
            ),
            polyline=d.polyline,
        )
        for d in drives
    ]


@router.get("/drives/{drive_id}")
def get_drive(
    drive_id: str,
    db: Session = Depends(get_db),
    _: str = Depends(verify_api_key)
):
    """Get a single drive with full polyline"""
    drive = db.query(Drive).filter(Drive.driveId == drive_id).first()
    if not drive:
        raise HTTPException(status_code=404, detail="Drive not found")
    
    return {
        "driveId": drive.driveId,
        "deviceId": drive.deviceId,
        "startTime": drive.startTime.replace(tzinfo=timezone.utc).isoformat() if drive.startTime else None,
        "endTime": drive.endTime.replace(tzinfo=timezone.utc).isoformat() if drive.endTime else None,
        "durationSeconds": drive.durationSeconds,
        "distanceMeters": drive.distanceMeters,
        "avgSpeedMPH": drive.avgSpeedMPH,
        "maxSpeedMPH": drive.maxSpeedMPH,
        "polyline": drive.polyline,
        "speeds": drive.speeds,
        "pointCount": drive.pointCount,
        "simplifiedPointCount": drive.simplifiedPointCount,
        "startReason": drive.startReason,
        "endReason": drive.endReason,
        "deviceModel": drive.deviceModel,
        "iosVersion": drive.iosVersion,
        "appVersion": drive.appVersion,
        "detectionLatencyMs": drive.detectionLatencyMs,
        "confirmationLatencyMs": drive.confirmationLatencyMs,
        "locationSampleCount": drive.locationSampleCount,
        "droppedSampleCount": drive.droppedSampleCount,
        "maxGapBetweenSamplesMs": drive.maxGapBetweenSamplesMs,
        "locationPauseCount": drive.locationPauseCount,
        "batteryLevelAtStart": drive.batteryLevelAtStart,
        "batteryLevelAtEnd": drive.batteryLevelAtEnd,
        "lowPowerModeAtStart": drive.lowPowerModeAtStart,
        "accelerationEvents": drive.accelerationEvents,
        "hardBrakeCount": drive.hardBrakeCount,
        "hardAccelCount": drive.hardAccelCount,
        "hardCornerCount": drive.hardCornerCount,
        "maxGForce": drive.maxGForce,
        "logEntries": drive.logEntries,
        "uploadedAt": drive.uploadedAt.replace(tzinfo=timezone.utc).isoformat() if drive.uploadedAt else None
    }


@router.delete("/drives/{drive_id}")
def delete_drive(
    drive_id: str,
    db: Session = Depends(get_db),
    _: str = Depends(verify_api_key)
):
    """Delete a drive"""
    drive = db.query(Drive).filter(Drive.driveId == drive_id).first()
    if not drive:
        raise HTTPException(status_code=404, detail="Drive not found")
    
    db.delete(drive)
    db.commit()
    
    return {"status": "deleted", "driveId": drive_id}
