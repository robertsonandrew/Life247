from fastapi import APIRouter, Header, HTTPException, Depends
from pydantic import BaseModel
from sqlalchemy.orm import Session
from datetime import datetime, timezone
from typing import Optional, List
import os

from ..database import get_db, engine, Base
from ..models import Place

# Create tables
Base.metadata.create_all(bind=engine)

router = APIRouter()

# Require API key from environment; fail fast if missing
API_KEY = os.getenv("LIFE247_API_KEY")
if not API_KEY:
    raise RuntimeError("LIFE247_API_KEY must be set")


class PlaceDTO(BaseModel):
    """Pydantic model for place sync request"""
    placeId: str
    deviceId: str
    name: str
    latitude: float
    longitude: float
    radiusMeters: float
    icon: str


class PlaceResponse(BaseModel):
    """Response model for place operations"""
    placeId: str
    deviceId: str
    name: str
    latitude: float
    longitude: float
    radiusMeters: float
    icon: str
    createdAt: str
    updatedAt: str
    isDeleted: bool


def verify_api_key(x_api_key: str = Header(...)):
    """Verify API key from header"""
    if x_api_key != API_KEY:
        raise HTTPException(status_code=401, detail="Invalid API key")
    return x_api_key


@router.post("/places/sync", response_model=PlaceResponse)
def sync_place(
    place: PlaceDTO,
    db: Session = Depends(get_db),
    api_key: str = Depends(verify_api_key)
):
    """
    Sync (upsert) a place from iOS.
    Creates new place or updates existing one.
    """
    now = datetime.now(timezone.utc)
    
    # Check if place exists
    existing = db.query(Place).filter(Place.placeId == place.placeId).first()
    
    if existing:
        # Update existing place
        existing.name = place.name
        existing.latitude = place.latitude
        existing.longitude = place.longitude
        existing.radiusMeters = place.radiusMeters
        existing.icon = place.icon
        existing.updatedAt = now
        existing.isDeleted = False  # Restore if was deleted
        db.commit()
        db.refresh(existing)
        
        return PlaceResponse(
            placeId=existing.placeId,
            deviceId=existing.deviceId,
            name=existing.name,
            latitude=existing.latitude,
            longitude=existing.longitude,
            radiusMeters=existing.radiusMeters,
            icon=existing.icon,
            createdAt=existing.createdAt.isoformat() if existing.createdAt else now.isoformat(),
            updatedAt=existing.updatedAt.isoformat(),
            isDeleted=existing.isDeleted
        )
    else:
        # Create new place
        db_place = Place(
            placeId=place.placeId,
            deviceId=place.deviceId,
            name=place.name,
            latitude=place.latitude,
            longitude=place.longitude,
            radiusMeters=place.radiusMeters,
            icon=place.icon,
            createdAt=now,
            updatedAt=now,
            isDeleted=False
        )
        db.add(db_place)
        db.commit()
        db.refresh(db_place)
        
        return PlaceResponse(
            placeId=db_place.placeId,
            deviceId=db_place.deviceId,
            name=db_place.name,
            latitude=db_place.latitude,
            longitude=db_place.longitude,
            radiusMeters=db_place.radiusMeters,
            icon=db_place.icon,
            createdAt=db_place.createdAt.isoformat(),
            updatedAt=db_place.updatedAt.isoformat(),
            isDeleted=db_place.isDeleted
        )


@router.get("/places", response_model=List[PlaceResponse])
def get_places(
    device_id: Optional[str] = None,
    include_deleted: bool = False,
    db: Session = Depends(get_db),
    api_key: str = Depends(verify_api_key)
):
    """
    Get all places, optionally filtered by device.
    """
    query = db.query(Place)
    
    if device_id:
        query = query.filter(Place.deviceId == device_id)
    
    if not include_deleted:
        query = query.filter(Place.isDeleted == False)
    
    places = query.order_by(Place.name).all()
    
    return [
        PlaceResponse(
            placeId=p.placeId,
            deviceId=p.deviceId,
            name=p.name,
            latitude=p.latitude,
            longitude=p.longitude,
            radiusMeters=p.radiusMeters,
            icon=p.icon,
            createdAt=p.createdAt.isoformat() if p.createdAt else "",
            updatedAt=p.updatedAt.isoformat() if p.updatedAt else "",
            isDeleted=p.isDeleted or False
        )
        for p in places
    ]


@router.delete("/places/{place_id}")
def delete_place(
    place_id: str,
    db: Session = Depends(get_db),
    api_key: str = Depends(verify_api_key)
):
    """
    Soft-delete a place by ID.
    """
    place = db.query(Place).filter(Place.placeId == place_id).first()
    
    if not place:
        raise HTTPException(status_code=404, detail="Place not found")
    
    place.isDeleted = True
    place.updatedAt = datetime.now(timezone.utc)
    db.commit()
    
    return {"status": "deleted", "placeId": place_id}


@router.get("/places/stats")
def get_places_stats(
    db: Session = Depends(get_db),
    api_key: str = Depends(verify_api_key)
):
    """
    Get statistics about saved places.
    """
    total = db.query(Place).filter(Place.isDeleted == False).count()
    deleted = db.query(Place).filter(Place.isDeleted == True).count()
    
    # Get unique devices
    devices = db.query(Place.deviceId).distinct().count()
    
    return {
        "totalPlaces": total,
        "deletedPlaces": deleted,
        "uniqueDevices": devices
    }
