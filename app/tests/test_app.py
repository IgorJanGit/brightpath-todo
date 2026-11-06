"""Integration tests against a real PostgreSQL (CI runs one as a service).

Set TEST_DATABASE_URL, e.g. postgresql://todo:todo@localhost:5432/todo
"""

import os
import sys

import pytest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from app import create_app  # noqa: E402

DB_URL = os.environ.get("TEST_DATABASE_URL")
pytestmark = pytest.mark.skipif(not DB_URL, reason="TEST_DATABASE_URL not set")


@pytest.fixture
def client():
    app = create_app(DB_URL)
    app.config["TESTING"] = True
    pool = app.extensions["db_pool"]
    pool.wait(timeout=10)
    with app.test_client() as c:
        c.get("/")  # creates the table
        with pool.connection() as conn:
            conn.execute("TRUNCATE todos RESTART IDENTITY")
        yield c
    pool.close()


def test_health_ok(client):
    r = client.get("/health")
    assert r.status_code == 200
    body = r.get_json()
    assert body["status"] == "ok"
    assert body["database"]["ok"] is True
    assert body["database"]["todo_count"] == 0


def test_add_and_read_back(client):
    r = client.post("/todos", data={"title": "Deploy to EC2"})
    assert r.status_code == 302
    page = client.get("/").get_data(as_text=True)
    assert "Deploy to EC2" in page
    assert client.get("/health").get_json()["database"]["todo_count"] == 1


def test_html_is_escaped(client):
    client.post("/todos", data={"title": "<script>alert(1)</script>"})
    page = client.get("/").get_data(as_text=True)
    assert "<script>alert(1)</script>" not in page
    assert "&lt;script&gt;" in page


def test_rejects_empty_and_too_long(client):
    client.post("/todos", data={"title": "   "})
    client.post("/todos", data={"title": "x" * 201})
    assert client.get("/health").get_json()["database"]["todo_count"] == 0


def test_toggle_and_delete(client):
    client.post("/todos", data={"title": "Write README"})
    assert client.post("/todos/1/toggle").status_code == 302
    assert 'class="done"' in client.get("/").get_data(as_text=True)
    assert client.post("/todos/999/toggle").status_code == 404
    client.post("/todos/1/delete")
    assert client.get("/health").get_json()["database"]["todo_count"] == 0


def test_health_reports_database_down():
    # Nothing listens on port 1, so the DB is "down" but the app must stay up.
    app = create_app("postgresql://nobody:nothing@127.0.0.1:1/none?connect_timeout=1")
    with app.test_client() as c:
        r = c.get("/health")
        assert r.status_code == 503
        body = r.get_json()
        assert body["app"] == "ok"
        assert body["status"] == "degraded"
        assert body["database"]["ok"] is False
        assert c.get("/").status_code == 503
    app.extensions["db_pool"].close()
