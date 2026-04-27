# syntax=docker/dockerfile:1.4

# ==============================================================================
# STAGE 1: Builder
# ==============================================================================
FROM python:3.14-slim-bookworm AS builder

# Securely pull the uv binary directly from Astral's official image
COPY --from=ghcr.io/astral-sh/uv:0.11.7 /uv /uvx /bin/

# Configure uv behavior
# UV_COMPILE_BYTECODE: Speeds up subsequent executions
# UV_LINK_MODE=copy: Ensures independence of the virtual environment for copying
# UV_PROJECT_ENVIRONMENT: Explicitly define the venv location for predictability
ENV UV_COMPILE_BYTECODE=1 \
    UV_LINK_MODE=copy \
    UV_PROJECT_ENVIRONMENT=/app/.venv

WORKDIR /app

# Copy dependency definition files first to leverage Docker layer caching
COPY pyproject.toml uv.lock ./

# Sync dependencies into the virtual environment (excluding the project code)
# --frozen ensures we strictly respect uv.lock (fails if out of sync)
# --no-dev excludes development dependencies (pytest, black, etc.)
RUN uv sync --frozen --no-install-project --no-dev

# Copy application code
# Ensure your .dockerignore excludes local .venv, .git, and __pycache__
COPY . .

# Final sync to install the project itself into the virtual environment
RUN uv sync --frozen --no-dev

# ==============================================================================
# STAGE 2: Final Production Image
# ==============================================================================
FROM python:3.14-slim-bookworm AS final

# OCI standard labels for governance and traceability
LABEL org.opencontainers.image.title="TUI Application" \
      org.opencontainers.image.description="Python Text User Interface App" \
      org.opencontainers.image.vendor="YourOrg"

# Configure environments for TUI rendering and Python execution
ENV TERM=xterm-256color \
    COLORTERM=truecolor \
    PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PATH="/app/.venv/bin:$PATH"

# Establish a non-root user for security (CIS Docker Benchmark)
# Update system packages to patch base image CVEs
RUN groupadd -r tuigroup && useradd -r -g tuigroup -s /sbin/nologin tuiuser \
    && apt-get update \
    && apt-get upgrade -y \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Copy the pre-built virtual environment and application code from the builder
COPY --from=builder --chown=root:root --chmod=755 /app/.venv /app/.venv
COPY --from=builder --chown=root:root --chmod=755 /app/src /app/src
# NOTE: Adjust /app/src to your actual project structure. Be explicit rather than COPY .

# Enforce least privilege
USER tuiuser

# TUI applications require a pseudo-TTY.
# Execute with: docker run -it <image_name>
ENTRYPOINT ["python", "-m", "src.main"]