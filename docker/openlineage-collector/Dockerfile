# Stdlib-only collector -- no pip install, no dependency drift, deterministic
# for a live demo.
FROM python:3.12-slim

COPY server.py /app/server.py
WORKDIR /app

ENV PORT=5000
EXPOSE 5000

CMD ["python3", "/app/server.py"]
