#!/bin/bash
set -e

echo "[$(date +'%H:%M:%S')] Initializing local build environment..."

# 1. Create the virtual environment
echo "[$(date +'%H:%M:%S')] Creating Python virtual environment..."
python3 -m venv venv

# 2. Activate it
echo "[$(date +'%H:%M:%S')] Activating virtual environment..."
source venv/bin/activate

# 3. Upgrade pip to avoid legacy installation issues
echo "[$(date +'%H:%M:%S')] Upgrading pip..."
pip install --upgrade pip

# 4. Install the required testing, application, and LLM provider libraries
echo "[$(date +'%H:%M:%S')] Installing Python dependencies..."
pip install \
  certifi==2026.2.25 \
  fastapi==0.135.1 \
  uvicorn==0.42.0 \
  pydantic==2.12.5 \
  pytest==8.3.4 \
  httpx==0.28.1 \
  requests==2.32.5 \
  mcp==1.26.0 \
  pytest-asyncio==1.3.0 \
  mcp-watchdog==0.1.9
echo "[$(date +'%H:%M:%S')] Build environment initialized successfully!"
echo "[$(date +'%H:%M:%S')] Note: Run 'source venv/bin/activate' in your terminal before running ./test.sh"