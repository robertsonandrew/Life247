from fastapi import APIRouter, Header, HTTPException, Depends
from pydantic import BaseModel, ConfigDict
from sqlalchemy.orm import Session
from datetime import datetime, timezone
from typing import Optional, List
import os

from ..database import get_db
from ..models import PlaceVisit

router = APIRouter()

# Require API key from environment; fail fast if missing
API_KEY = os.getenv("LIFE247_API_KEY")
if not API_KEY:
    raise RuntimeError("LIFE247_API_KEY must be set")


class PlaceVisitDTO(BaseModel):
    """Pydantic model for place visit upload request"""

    visitId: str
    deviceId: str

    arrivalTime: str
    departureTime: str
    durationSeconds: float

    placeName: str
    placeIcon: str
    placeRadiusMeters: float
    placeLatitude: float
    placeLongitude: float

    latitude: float
    longitude: float

    source: str

    deviceModel: Optional[str] = None
    iosVersion: Optional[str] = None
    appVersion: Optional[str] = None


class PlaceVisitResponse(BaseModel):
    visitId: str
    deviceId: str

    arrivalTime: str
    departureTime: str
    durationSeconds: float

    placeName: str
    placeIcon: str
    placeRadiusMeters: float
    placeLatitude: float
    placeLongitude: float

    latitude: float
    longitude: float

    source: Optional[str] = None

    deviceModel: Optional[str] = None
    iosVersion: Optional[str] = None
    appVersion: Optional[str] = None

    model_config = ConfigDict(from_attributes=True)


def verify_api_key(x_api_key: str = Header(...)):
    """Dependency to verify API key"""
    if x_api_key != API_KEY:
        raise HTTPException(status_code=401, detail="Invalid API key")
    return x_api_key


@router.post("/visits", response_model=dict)
def upload_visit(
    visit: PlaceVisitDTO,
    db: Session = Depends(get_db),
    _: str = Depends(verify_api_key),
):
    """Upload a new place visit (dwell session)"""

    existing = db.query(PlaceVisit).filter(PlaceVisit.visitId == visit.visitId).first()
    if existing:
        return {"status": "exists", "visitId": visit.visitId}

    try:
        arrival_time = datetime.fromisoformat(visit.arrivalTime.replace("Z", "+00:00"))
        departure_time = datetime.fromisoformat(visit.departureTime.replace("Z", "+00:00"))
    except ValueError as e:
        raise HTTPException(status_code=400, detail=f"Invalid timestamp format: {e}")

    entry = PlaceVisit(
        visitId=visit.visitId,
        deviceId=visit.deviceId,
        arrivalTime=arrival_time,
        departureTime=departure_time,
        durationSeconds=visit.durationSeconds,
        placeName=visit.placeName,
        placeIcon=visit.placeIcon,
        placeRadiusMeters=visit.placeRadiusMeters,
        placeLatitude=visit.placeLatitude,
        placeLongitude=visit.placeLongitude,
        latitude=visit.latitude,
        longitude=visit.longitude,
        source=visit.source,
        deviceModel=visit.deviceModel,
        iosVersion=visit.iosVersion,
        appVersion=visit.appVersion,
        uploadedAt=datetime.utcnow(),
    )

    db.add(entry)
    db.commit()

    return {"status": "success", "visitId": visit.visitId}


@router.get("/visits", response_model=List[PlaceVisitResponse])
def list_visits(
    limit: int = 200,
    offset: int = 0,
    db: Session = Depends(get_db),
    _: str = Depends(verify_api_key),
):
    """List all visits (paginated)"""

    visits = (
        db.query(PlaceVisit)
        .order_by(PlaceVisit.arrivalTime.desc())
        .offset(offset)
        .limit(limit)
        .all()
    )

    return [
        PlaceVisitResponse(
            visitId=v.visitId,
            deviceId=v.deviceId,
            arrivalTime=v.arrivalTime.replace(tzinfo=timezone.utc).isoformat() if v.arrivalTime else "",
            departureTime=v.departureTime.replace(tzinfo=timezone.utc).isoformat() if v.departureTime else "",
            durationSeconds=v.durationSeconds,
            placeName=v.placeName,
            placeIcon=v.placeIcon,
            placeRadiusMeters=v.placeRadiusMeters,
            placeLatitude=v.placeLatitude,
            placeLongitude=v.placeLongitude,
            latitude=v.latitude,
            longitude=v.longitude,
            source=v.source,
            deviceModel=v.deviceModel,
            iosVersion=v.iosVersion,
            appVersion=v.appVersion,
        )
        for v in visits
    ]


@router.delete("/visits/{visit_id}")
def delete_visit(
    visit_id: str,
    db: Session = Depends(get_db),
    _: str = Depends(verify_api_key),
):
    """Delete a visit"""

    visit = db.query(PlaceVisit).filter(PlaceVisit.visitId == visit_id).first()
    if not visit:
        raise HTTPException(status_code=404, detail="Visit not found")

    db.delete(visit)
    db.commit()

    return {"status": "deleted", "visitId": visit_id}
