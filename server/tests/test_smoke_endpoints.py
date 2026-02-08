def test_smoke_all_primary_endpoints(client, auth_headers):
    health = client.get("/health")
    assert health.status_code == 200
    assert health.json()["status"] == "ok"

    root = client.get("/")
    assert root.status_code == 200

    secure_paths = [
        "/drives",
        "/drives/summary",
        "/stats/overview",
        "/stats/activity",
        "/stats/habits",
        "/stats/places",
        "/visits",
        "/places",
        "/places/stats",
    ]

    for path in secure_paths:
        response = client.get(path, headers=auth_headers)
        assert response.status_code == 200, f"{path} returned {response.status_code}: {response.text}"
