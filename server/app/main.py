from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from fastapi.staticfiles import StaticFiles
from fastapi.responses import FileResponse
from pathlib import Path
from .routes import drives, visits, places

app = FastAPI(
    title="Life247 Drive Sync API",
    description="Self-hosted API for syncing Life247 drive data",
    version="1.0.0"
)

# CORS middleware (adjust origins for production)
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

# Include routes
app.include_router(drives.router, tags=["drives"])
app.include_router(visits.router, tags=["visits"])
app.include_router(places.router, tags=["places"])

# Static files directory
static_dir = Path(__file__).parent / "static"


@app.get("/health")
def health_check():
    """Health check endpoint"""
    return {"status": "ok", "service": "life247-sync"}


@app.get("/")
def root():
    """Serve the dashboard"""
    return FileResponse(static_dir / "index.html")


@app.get("/docs-api")
def api_docs_redirect():
    """Redirect to API docs"""
    return {"message": "Visit /docs for API documentation"}

