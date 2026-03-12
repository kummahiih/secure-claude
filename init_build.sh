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
    pytest \
    httpx \
    fastapi \
    uvicorn \
    requests \
    pydantic \
    langchain \
    langchain-openai \
    langchain-anthropic \
    langchain-google-genai \
    langchain-community

echo "[$(date +'%H:%M:%S')] Build environment initialized successfully!"
echo "[$(date +'%H:%M:%S')] Note: Run 'source venv/bin/activate' in your terminal before running ./test.sh"