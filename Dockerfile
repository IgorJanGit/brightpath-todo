# Small, non-root image for the Flask app. CI builds it as a check; the EC2 instance builds the same Dockerfile when it deploys.
FROM python:3.12-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1

WORKDIR /app

# Dependencies first so this layer is cached between code changes.
COPY app/requirements.txt .
RUN pip install -r requirements.txt

COPY app/ .

# Never run the app as root inside the container.
RUN useradd --system --uid 10001 --no-create-home appuser
USER appuser

EXPOSE 8000

# Docker marks the container unhealthy if /health fails (e.g. DB unreachable).
# The deploy script waits for "healthy" and rolls back if it never gets there.
HEALTHCHECK --interval=10s --timeout=4s --start-period=15s --retries=3 \
  CMD python -c "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8000/health', timeout=3)" || exit 1

CMD ["gunicorn", "--bind", "0.0.0.0:8000", "--workers", "2", "--timeout", "30", \
     "--access-logfile", "-", "wsgi:app"]
