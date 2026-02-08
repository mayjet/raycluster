# Stage 0: builder - build wheels (uses Python 3.11)
FROM python:3.11-slim AS builder
WORKDIR /tmp

# Install system deps for building wheels
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential git curl ca-certificates python3-dev gcc wget \
 && rm -rf /var/lib/apt/lists/*

# Install uv in builder for faster ops and wheel building
RUN curl -LsSf https://astral.sh/uv/install.sh | sh \
 && ln -s /root/.local/bin/uv /usr/local/bin/uv

# Copy your requirements (uploaded file path)
# In CI/registry builds, prefer copying from build context instead.
COPY /mnt/data/requirements.txt /tmp/requirements.txt

# Build wheels into /wheels for reproducible fast installs
RUN uv pip wheel --wheel-dir=/wheels -r /tmp/requirements.txt

# Stage 1: runtime image (Python 3.11 slim)
FROM python:3.11-slim
WORKDIR /workspace

# runtime OS deps
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl git rsync ca-certificates ffmpeg openssh-client iproute2 jq \
 && rm -rf /var/lib/apt/lists/*

# Install uv in runtime (for fast install, mirrors builder behaviour)
RUN curl -LsSf https://astral.sh/uv/install.sh | sh \
 && ln -s /root/.local/bin/uv /usr/local/bin/uv

# Copy prebuilt wheels from builder and install them using uv (fast + reproducible)
COPY --from=builder /wheels /wheels
RUN uv pip install --system /wheels/* || true

# Fallback: copy requirements and ensure leftover requirements are installed
COPY /mnt/data/requirements.txt /workspace/requirements.txt
RUN uv pip install --system -r /workspace/requirements.txt || true

# Ensure ray is present (install via uv if not installed by requirements)
RUN python - <<'PY'
import importlib, sys, subprocess
try:
    importlib.import_module('ray')
except Exception:
    subprocess.check_call([sys.executable, '-m', 'pip', 'install', 'ray[default]==2.11.0'])
PY

# Copy start scripts (consul leader script, wait-for-nvidia, ensure_model_cached, etc.)
# Ensure your repository has a `start/` directory with these scripts.
COPY start /usr/local/bin/start-scripts
RUN chmod -R +x /usr/local/bin/start-scripts

# Create runtime dirs (cache, logs)
RUN mkdir -p /var/local/cache/project/models /workspace/code /workspace/models /workspace/logs

ENV PYTHONUNBUFFERED=1

# Expose typical ports (Ray dashboard, Jupyter, Ray services)
EXPOSE 8000 8265 6379 8888 22

# Entrypoint runs the consul-based leader-election + ray start/join script added earlier
ENTRYPOINT ["/usr/local/bin/start-scripts/consul_leader_elect_and_run.sh"]