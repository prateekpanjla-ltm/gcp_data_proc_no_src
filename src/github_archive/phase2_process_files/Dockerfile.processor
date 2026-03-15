# Dockerfile for GitHub Archive Phase 2 Processor Service
# Multi-stage build for optimized image size

# =============================================================================
# Stage 1: Builder
# =============================================================================
FROM python:3.11-slim AS builder

WORKDIR /build

# Install build dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    gcc \
    g++ \
    && rm -rf /var/lib/apt/lists/*

# Copy requirements
COPY requirements.txt .

# Install Python dependencies to a temporary location
RUN pip install --no-cache-dir --user -r requirements.txt


# =============================================================================
# Stage 2: Runtime
# =============================================================================
FROM python:3.11-slim AS runtime

# Set environment variables
ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1

# Install runtime dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Create non-root user
RUN groupadd -r appuser && useradd -r -g appuser appuser

# Set working directory
WORKDIR /app

# Copy Python packages from builder to /usr/local
# This makes them available to all users including appuser
COPY --from=builder /root/.local /usr/local

# Add site-packages to PYTHONPATH
ENV PYTHONPATH=/usr/local/lib/python3.11/site-packages

# Copy application code
# Build context is phase2_process_files/ directory
COPY . .

# Add PYTHONPATH for relative imports to work
ENV PYTHONPATH=/app:/usr/local/lib/python3.11/site-packages

# Create directories for temp files
RUN mkdir -p /tmp/processing && \
    chown -R appuser:appuser /app /tmp

# Switch to non-root user
USER appuser

# Expose port
EXPOSE 8080

# Health check - longer start period for Flask to initialize
HEALTHCHECK --interval=30s --timeout=10s --start-period=30s --retries=3 \
    CMD python -c "import urllib.request; urllib.request.urlopen('http://localhost:8080/health').read()" || exit 1

# Run the application with production WSGI server
CMD ["gunicorn", "--bind", "0.0.0.0:8080", "--workers", "1", "--threads", "2", "--timeout", "3600", "--access-logfile", "-", "--error-logfile", "-", "main:app"]
