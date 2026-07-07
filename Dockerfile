FROM python:3.11-slim

WORKDIR /app

# 시스템 의존성, curl, 그리고 GCS MCP 도구(npx) 구동을 위한 Node.js & npm 설치
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    gnupg \
    && curl -fsSL https://deb.nodesource.com/setup_18.x | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && rm -rf /var/lib/apt/lists/*

# 파이썬 의존성 파일 복사 및 설치
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# 에이전트 소스 및 스킬 데이터 복사
# (수동 GCS I/O가 제거되었으므로 tools.py는 더 이상 복사하지 않습니다)
COPY agent.py callbacks.py ./
COPY skill/ ./skill/

# Cloud Run의 기본 포트 8080 오픈
EXPOSE 8080

# ADK 내장 Ambient API Server 실행
CMD ["adk", "api_server", "--trigger_sources", "eventarc", "--host", "0.0.0.0", "--port", "8080", "."]


