# Life247 Drive Sync Server

Self-hosted FastAPI backend for syncing Life247 drive data.

## Quick Start

### Local Development
```bash
cd server
pip install -r requirements.txt
uvicorn app.main:app --reload
```

### Test Setup
```bash
cd server
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements-dev.txt
pytest
```

### Docker
```bash
cd server
cp .env.example .env   # then set a real LIFE247_API_KEY
docker compose up -d
```

The API will be available at `http://localhost:8247`

## Configuration

Set your API key via environment variable:
```bash
export LIFE247_API_KEY="your-secret-key"
```

Or in `server/.env` file:
```
LIFE247_API_KEY=your-secret-key
```

## API Endpoints

| Method | Endpoint | Description |
|--------|----------|-------------|
| GET | `/health` | Health check |
| POST | `/drives` | Upload a drive |
| GET | `/drives` | List drives (paginated) |
| GET | `/drives/summary` | List lightweight drive summaries (paginated) |
| GET | `/drives/{id}` | Get single drive |
| DELETE | `/drives/{id}` | Delete drive |
| POST | `/visits` | Upload a place visit |
| GET | `/visits` | List place visits (paginated) |
| DELETE | `/visits/{id}` | Delete a place visit |
| POST | `/places/sync` | Upsert a place |
| GET | `/places` | List places |
| DELETE | `/places/{id}` | Soft-delete place |
| GET | `/stats/overview` | KPI summary for selected range |
| GET | `/stats/activity` | Daily/weekly activity buckets |
| GET | `/stats/habits` | Weekday/hour habits and streaks |
| GET | `/stats/places` | Place dwell analytics |

## Authentication

All data endpoints require `X-API-Key` header.

## iOS App Configuration

1. Go to Settings > Cloud Sync
2. Enable sync
3. Enter server URL: `http://your-server:8247`
4. Enter API key

## Data Storage

SQLite database stored at `./data/drives.db`

Backup your data:
```bash
cp data/drives.db data/drives.db.backup
```
