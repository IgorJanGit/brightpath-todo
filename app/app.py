"""BrightPath To-Do: a deliberately small Flask + PostgreSQL app.

The app is intentionally simple; the interesting part of this repo is how it
is deployed (see README.md). Configuration comes only from environment
variables, so no secret ever lives in the code or the image.
"""

import logging
import os
import threading
import time

import psycopg
from flask import Flask, abort, jsonify, redirect, render_template, request, url_for
from psycopg_pool import ConnectionPool, PoolTimeout
from werkzeug.exceptions import HTTPException

MAX_TITLE_LENGTH = 200

SCHEMA_SQL = """
CREATE TABLE IF NOT EXISTS todos (
    id          SERIAL PRIMARY KEY,
    title       VARCHAR(200) NOT NULL,
    done        BOOLEAN      NOT NULL DEFAULT FALSE,
    created_at  TIMESTAMPTZ  NOT NULL DEFAULT now()
);
"""

log = logging.getLogger("todo")


def conninfo_from_env() -> str:
    """Build a libpq connection string from env vars.

    DATABASE_URL wins if set (handy locally and in CI). On AWS the deploy
    script writes DB_HOST/DB_USER/... from SSM Parameter Store instead.
    sslmode defaults to "require" because RDS for PostgreSQL 15+ enforces
    TLS (rds.force_ssl=1).
    """
    if os.environ.get("DATABASE_URL"):
        return os.environ["DATABASE_URL"]
    return psycopg.conninfo.make_conninfo(
        host=os.environ.get("DB_HOST", "localhost"),
        port=os.environ.get("DB_PORT", "5432"),
        dbname=os.environ.get("DB_NAME", "todo"),
        user=os.environ.get("DB_USER", "todo"),
        password=os.environ.get("DB_PASSWORD", ""),
        sslmode=os.environ.get("DB_SSLMODE", "require"),
        connect_timeout=5,
    )


def create_app(conninfo: str | None = None) -> Flask:
    app = Flask(__name__)
    app.config["VERSION"] = os.environ.get("APP_VERSION", "dev")[:7]
    app.config["INSTANCE_ID"] = os.environ.get("INSTANCE_ID", "local")

    # open=False + open(wait=False): the web server starts even if the
    # database is unreachable, so /health can *report* the problem instead
    # of the process crash-looping.
    pool = ConnectionPool(
        conninfo or conninfo_from_env(),
        min_size=1,
        max_size=5,
        open=False,
        check=ConnectionPool.check_connection,
        name="todo-pool",
    )
    pool.open(wait=False)
    app.extensions["db_pool"] = pool

    schema_ready = threading.Event()
    schema_lock = threading.Lock()

    def ensure_schema() -> None:
        """Create the table once per process (idempotent)."""
        if schema_ready.is_set():
            return
        with schema_lock:
            if schema_ready.is_set():
                return
            with pool.connection(timeout=5) as conn:
                conn.execute(SCHEMA_SQL)
            schema_ready.set()

    def db():
        ensure_schema()
        return pool.connection(timeout=5)

    @app.get("/")
    def index():
        with db() as conn:
            todos = conn.execute(
                "SELECT id, title, done, created_at FROM todos "
                "ORDER BY done, created_at DESC, id DESC"
            ).fetchall()
        remaining = sum(1 for t in todos if not t[2])
        error = request.args.get("error")
        return render_template(
            "index.html",
            todos=todos,
            remaining=remaining,
            error=error,
            version=app.config["VERSION"],
            instance=app.config["INSTANCE_ID"],
        )

    @app.post("/todos")
    def add_todo():
        title = (request.form.get("title") or "").strip()
        if not title:
            return redirect(url_for("index", error="Please type something first."))
        if len(title) > MAX_TITLE_LENGTH:
            return redirect(url_for("index", error=f"Keep it under {MAX_TITLE_LENGTH} characters."))
        with db() as conn:
            # Parameterised query: user input never becomes SQL.
            conn.execute("INSERT INTO todos (title) VALUES (%s)", (title,))
        return redirect(url_for("index"))

    @app.post("/todos/<int:todo_id>/toggle")
    def toggle_todo(todo_id: int):
        with db() as conn:
            cur = conn.execute("UPDATE todos SET done = NOT done WHERE id = %s", (todo_id,))
            if cur.rowcount == 0:
                abort(404)
        return redirect(url_for("index"))

    @app.post("/todos/<int:todo_id>/delete")
    def delete_todo(todo_id: int):
        with db() as conn:
            conn.execute("DELETE FROM todos WHERE id = %s", (todo_id,))
        return redirect(url_for("index"))

    @app.get("/health")
    def health():
        """Liveness + readiness in one: is the app up, and can it reach the DB?

        Returns 200 when everything works and 503 when the database is
        unreachable, so load balancers, Docker and uptime checks can act on
        the status code alone.
        """
        started = time.perf_counter()
        database = {"ok": False}
        try:
            with pool.connection(timeout=3) as conn:
                conn.execute("SELECT 1").fetchone()
                count = None
                if schema_ready.is_set():
                    count = conn.execute("SELECT count(*) FROM todos").fetchone()[0]
            database = {
                "ok": True,
                "latency_ms": round((time.perf_counter() - started) * 1000, 1),
            }
            if count is not None:
                database["todo_count"] = count
        except Exception as exc:  # report, don't crash
            log.warning("health check: database unavailable: %r", exc)
            # Only the exception *type* is exposed, never connection details.
            database = {"ok": False, "error": type(exc).__name__}

        body = {
            "status": "ok" if database["ok"] else "degraded",
            "app": "ok",
            "database": database,
            "version": app.config["VERSION"],
            "instance": app.config["INSTANCE_ID"],
        }
        return jsonify(body), (200 if database["ok"] else 503)

    @app.errorhandler(Exception)
    def handle_error(exc):
        if isinstance(exc, HTTPException):
            return exc  # 404 etc. keep their normal responses
        if isinstance(exc, (PoolTimeout, psycopg.Error)):
            # Database unreachable or erroring: show a friendly page, log details.
            log.error("database error on %s: %r", request.path, exc)
            return render_template("error.html"), 503
        log.exception("unhandled error on %s", request.path)
        return render_template("error.html"), 500

    return app
