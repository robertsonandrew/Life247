# Life247 Drive Sync Server

Self-hosted FastAPI backend for syncing Life247 drive data.

## Quick Start

### Local Development
```bash
cd server
pip install -r requirements.txt
uvicorn app.main:app --reload
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
| GET | `/drives/{id}` | Get single drive |
| DELETE | `/drives/{id}` | Delete drive |

## Authentication

All `/drives` endpoints require `X-API-Key` header.

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
