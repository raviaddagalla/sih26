FROM python:3.11-slim

WORKDIR /app

# Install system dependencies for scientific compute
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    curl \
    && rm -rf /var/lib/apt/lists/*

# Install Python requirements
COPY edge_engine/requirements.txt /app/edge_engine/requirements.txt
RUN pip install --no-cache-dir -r /app/edge_engine/requirements.txt

# Copy source, models, and edge engine
COPY src/ /app/src/
COPY models/ /app/models/
COPY edge_engine/ /app/edge_engine/

ENV PYTHONPATH="/app/src:${PYTHONPATH}"
EXPOSE 8000

CMD ["uvicorn", "edge_engine.main:app", "--host", "0.0.0.0", "--port", "8000"]
