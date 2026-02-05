from sqlalchemy import Column, String, Float, Integer, DateTime, JSON, Boolean
from .database import Base


class Drive(Base):
    """SQLAlchemy model for stored drives"""
    __tablename__ = "drives"
    
    driveId = Column(String, primary_key=True, index=True)
    deviceId = Column(String, index=True)
    startTime = Column(DateTime)
    endTime = Column(DateTime)
    durationSeconds = Column(Float)
    distanceMeters = Column(Float)
    avgSpeedMPH = Column(Float)
    maxSpeedMPH = Column(Float)
    polyline = Column(String)
    pointCount = Column(Integer)
    simplifiedPointCount = Column(Integer)
    speeds = Column(JSON, nullable=True)
    startReason = Column(String, nullable=True)
    endReason = Column(String, nullable=True)
    
    # System context
    deviceModel = Column(String, nullable=True)
    iosVersion = Column(String, nullable=True)
    appVersion = Column(String, nullable=True)
    
    # Quality Metrics
    detectionLatencyMs = Column(Integer, nullable=True)       # Time to first GPS fix
    confirmationLatencyMs = Column(Integer, nullable=True)    # Time to confirmed speed
    locationSampleCount = Column(Integer, nullable=True)      # Total samples recorded
    droppedSampleCount = Column(Integer, nullable=True)       # Samples rejected
    maxGapBetweenSamplesMs = Column(Integer, nullable=True)   # Longest GPS gap
    locationPauseCount = Column(Integer, nullable=True)       # iOS location pauses
    bufferedPointCount = Column(Integer, nullable=True)       # Points from maybeDriving buffer
    batteryLevelAtStart = Column(Float, nullable=True)        # 0.0 - 1.0
    batteryLevelAtEnd = Column(Float, nullable=True)          # 0.0 - 1.0
    lowPowerModeAtStart = Column(Boolean, nullable=True)      # Was LPM enabled?
    
    # G-Force Events
    accelerationEvents = Column(JSON, nullable=True)          # Array of event objects
    hardBrakeCount = Column(Integer, nullable=True)
    hardAccelCount = Column(Integer, nullable=True)
    hardCornerCount = Column(Integer, nullable=True)
    maxGForce = Column(Float, nullable=True)
    
    # Timeline Events (Drive Inspector log entries)
    logEntries = Column(JSON, nullable=True)                  # Array of log entry objects
    
    # Server metadata
    uploadedAt = Column(DateTime)


class PlaceVisit(Base):
    """SQLAlchemy model for stored place visits (dwell sessions)."""
    __tablename__ = "place_visits"

    visitId = Column(String, primary_key=True, index=True)
    deviceId = Column(String, index=True)

    # Timing
    arrivalTime = Column(DateTime)
    departureTime = Column(DateTime)
    durationSeconds = Column(Float)

    # Place snapshot
    placeName = Column(String)
    placeIcon = Column(String)
    placeRadiusMeters = Column(Float)
    placeLatitude = Column(Float)
    placeLongitude = Column(Float)

    # Observed coordinate (visit coordinate)
    latitude = Column(Float)
    longitude = Column(Float)

    # Source
    source = Column(String, nullable=True)

    # System context
    deviceModel = Column(String, nullable=True)
    iosVersion = Column(String, nullable=True)
    appVersion = Column(String, nullable=True)

    # Server metadata
    uploadedAt = Column(DateTime)


class Place(Base):
    """SQLAlchemy model for user-defined saved places (geofences)."""
    __tablename__ = "places"

    placeId = Column(String, primary_key=True, index=True)  # UUID from iOS
    deviceId = Column(String, index=True)

    # Place info
    name = Column(String)
    latitude = Column(Float)
    longitude = Column(Float)
    radiusMeters = Column(Float)
    icon = Column(String)

    # Server metadata
    createdAt = Column(DateTime)
    updatedAt = Column(DateTime)
    isDeleted = Column(Boolean, default=False)  # Soft delete for sync
