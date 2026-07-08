#!/usr/bin/env bash
# ==============================================================================
# Cloud SQL for MySQL 8.4 Upgrade Checker Agent - Simplified Deployer
# ==============================================================================
# 이 스크립트는 .env의 내용을 바탕으로 빌드, 배포, 트리거 연동을 군더더기 없이 기계적으로 수행합니다.
# # ==============================================================================
#  0. 환경 변수 감지, 로드 및 엄격 밸리데이션 검사
# ==============================================================================

# 에러 발생 시 즉각 스크립트 중단, 미선언 변수 에러 처리, 파이프라인 에러 전파 활성화 (Fail Fast)
set -euo pipefail

# 스크립트가 위치한 물리적 디렉토리 경로를 강제 앵커링하여 상위 폴더 등 임의 위치 호출 시 상대 경로 붕괴 현상을 원천 방지
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

ENV_FILE=".env"
if [ ! -f "$ENV_FILE" ]; then
  echo "❌ 에러: .env 파일이 존재하지 않습니다. 먼저 .env 파일을 준비해 주세요."
  exit 1
fi

echo "ℹ️  $ENV_FILE 파일로부터 설정을 로드합니다..."
export $(grep -v '^#' "$ENV_FILE" | xargs)

# [필수 변수 유무 검증] 단 하나의 필수 값이라도 정의되어 있지 않으면 대안 없이 즉각 중단
REQUIRED_VARS=(
  "GOOGLE_CLOUD_PROJECT"
  "GOOGLE_CLOUD_LOCATION"
  "STAGING_BUCKET_URI"
  "SERVICE_ACCOUNT"
  "GCP_RESOURCES_LOCATION"
  "GCS_MCP_SERVER"
)

for var in "${REQUIRED_VARS[@]}"; do
  if [ -z "${!var:-}" ]; then
    echo "❌ 에러: .env 파일에 필수 설정 변수인 '$var'가 정의되어 있지 않습니다. 배포를 중단합니다."
    exit 1
  fi
done

# ==============================================================================
#  1. 배포 구성 변수 모음 (설정값 일원화 관리)
# ==============================================================================
# Cloud Run 서비스 식별 이름 정보
SERVICE_NAME="cloudsql-upgrade-checker"
FRONTEND_SERVICE_NAME="cloudsql-upgrade-checker-frontend"

# 업그레이드 체커 트리거 및 GCS 구성 정보
TRIGGER_PREFIX="check-results"
TRIGGER_BUCKET=$(echo "$STAGING_BUCKET_URI" | sed 's|^gs://||')

# 서비스 계정(SA) 정보 자동 가공 및 구조화
PROJECT_ID="$GOOGLE_CLOUD_PROJECT"
if [[ "$SERVICE_ACCOUNT" == *@* ]]; then
  SA_EMAIL="$SERVICE_ACCOUNT"
  SA_NAME=$(echo "$SA_EMAIL" | cut -d'@' -f1)
else
  SA_NAME="$SERVICE_ACCOUNT"
  SA_EMAIL="${SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"
fi

# 서비스 계정에 부여할 최소 권한(IAM Role) 모음
REQUIRED_SA_ROLES=(
  "roles/aiplatform.user"
  "roles/storage.objectUser"
  "roles/eventarc.eventReceiver"
  "roles/run.invoker"
  "roles/agentregistry.viewer"
  "roles/mcp.toolUser"
)

# ==============================================================================
#  2. 전용 서비스 계정(SA) 리소스 확인, 생성 및 권한 연동
# ==============================================================================
echo "----------------------------------------------------------------------"
echo "🔑 [전용 SA 구성] 서비스 계정 상태 확인 및 생성 중... ($SA_EMAIL)"
echo "----------------------------------------------------------------------"
if ! gcloud iam service-accounts describe "$SA_EMAIL" --project="$PROJECT_ID" >/dev/null 2>&1; then
  echo "🆕 서비스 계정이 존재하지 않아 새로 생성합니다: $SA_NAME"
  gcloud iam service-accounts create "$SA_NAME" \
    --display-name="MySQL 8.4 Upgrade Checker Service Account" \
    --project="$PROJECT_ID"
fi

echo "🔒 서비스 계정에 필요한 최소 IAM 역할을 부여합니다..."
for role in "${REQUIRED_SA_ROLES[@]}"; do
  gcloud projects add-iam-policy-binding "$PROJECT_ID" \
    --member="serviceAccount:$SA_EMAIL" \
    --role="$role" >/dev/null 2>&1 || true
done

# 현재 로그인된 사용자 계정에게 Service Account User 권한 부여 (actAs 권한 해결에 필수)
CURRENT_USER=$(gcloud config get-value account 2>/dev/null || echo "")
if [ -n "$CURRENT_USER" ]; then
  echo "🔒 현재 배포 사용자($CURRENT_USER)에게 서비스 계정 사용(actAs) 권한을 부여합니다..."
  gcloud iam service-accounts add-iam-policy-binding "$SA_EMAIL" \
    --member="user:$CURRENT_USER" \
    --role="roles/iam.serviceAccountUser" \
    --project="$PROJECT_ID" >/dev/null 2>&1 || true
fi

# Eventarc 서비스 에이전트에게 Service Account User 권한 부여 (Eventarc가 해당 서비스 계정을 actAs할 수 있도록 처리)
PROJECT_NUMBER=$(gcloud projects describe "$PROJECT_ID" --format="value(projectNumber)" 2>/dev/null || echo "")
if [ -n "$PROJECT_NUMBER" ]; then
  EVENTARC_SERVICE_ACCOUNT="service-${PROJECT_NUMBER}@gcp-sa-eventarc.iam.gserviceaccount.com"
  echo "🔒 Eventarc 서비스 에이전트($EVENTARC_SERVICE_ACCOUNT)에게 서비스 계정 사용(actAs) 권한을 부여합니다..."
  gcloud iam service-accounts add-iam-policy-binding "$SA_EMAIL" \
    --member="serviceAccount:$EVENTARC_SERVICE_ACCOUNT" \
    --role="roles/iam.serviceAccountUser" \
    --project="$PROJECT_ID" >/dev/null 2>&1 || true
fi

echo "======================================================================"
echo "🚀 배포 구성을 시작합니다 (.env 입력 정보)"
echo "======================================================================"
echo "📍 GCP 프로젝트 ID: $GOOGLE_CLOUD_PROJECT"
echo "📍 배포 대상 리전: $GCP_RESOURCES_LOCATION"
echo "📍 ADK Agent on Cloud Run: $SERVICE_NAME"
echo "📍 Frontend on Cloud Run: $FRONTEND_SERVICE_NAME"
echo "📍 이벤트 감지 GCS 버킷: $TRIGGER_BUCKET"
echo "📍 사용 서비스 계정: $SERVICE_ACCOUNT"
echo "======================================================================"

# 2. 소스 기반 배포를 사용하여 Cloud Run에 직접 빌드 및 배포
echo "🚀 1단계: 현재 소스 디렉토리(.)로부터 Cloud Run 서비스를 직접 빌드 및 배포합니다..."
gcloud run deploy "$SERVICE_NAME" \
  --source . \
  --region "$GCP_RESOURCES_LOCATION" \
  --project "$GOOGLE_CLOUD_PROJECT" \
  --allow-unauthenticated \
  --set-env-vars="TRIGGER_BUCKET=$TRIGGER_BUCKET,TRIGGER_PREFIX=$TRIGGER_PREFIX,GOOGLE_GENAI_USE_VERTEXAI=True,GOOGLE_CLOUD_PROJECT=$GOOGLE_CLOUD_PROJECT,GOOGLE_CLOUD_LOCATION=$GOOGLE_CLOUD_LOCATION,GCS_MCP_SERVER=$GCS_MCP_SERVER" \
  --service-account="$SA_EMAIL"

# 배포된 Cloud Run URL 획득
RUN_URL=$(gcloud run services describe "$SERVICE_NAME" --region "$GCP_RESOURCES_LOCATION" --project "$GOOGLE_CLOUD_PROJECT" --format 'value(status.url)')
echo "✅ Cloud Run 배포 완료! 서비스 URL: $RUN_URL"

# 4. GCS 서비스 에이전트에 Pub/Sub 게시자 권한 부여 (Eventarc 정상 연동을 위해 무조건 실행)
echo "🔑 3단계: GCS 서비스 에이전트 권한 연동을 구성합니다..."
STORAGE_SERVICE_ACCOUNT=$(gcloud storage service-agent --project="$GOOGLE_CLOUD_PROJECT" 2>/dev/null | tr -d '[:space:]' || echo "")
if [ -n "$STORAGE_SERVICE_ACCOUNT" ]; then
  gcloud projects add-iam-policy-binding "$GOOGLE_CLOUD_PROJECT" \
    --member="serviceAccount:$STORAGE_SERVICE_ACCOUNT" \
    --role="roles/pubsub.publisher" >/dev/null 2>&1 || true
fi

# 5. Eventarc 트리거 설정 (GCS 버킷 위치와 일치하도록 트리거 위치를 자동 조율)
TRIGGER_NAME="${SERVICE_NAME}-gcs-trigger"
echo "🔔 4단계: Eventarc 트리거를 GCS 버킷 리전에 맞춰 재구성합니다..."

# Eventarc에서 GCS 이벤트를 감지하려면 GCS 버킷의 리전(location)과 트리거의 리전이 완벽히 일치해야 합니다.
# GCS 버킷의 실제 리전을 동적으로 조회합니다.
BUCKET_LOCATION=$(gcloud storage buckets describe "gs://$TRIGGER_BUCKET" --format="value(location)" --project="$GOOGLE_CLOUD_PROJECT" 2>/dev/null | tr '[:upper:]' '[:lower:]' || echo "")
if [ -z "$BUCKET_LOCATION" ]; then
  TRIGGER_LOCATION="$GCP_RESOURCES_LOCATION"
else
  TRIGGER_LOCATION="$BUCKET_LOCATION"
fi
echo "📍 감지된 버킷 리전: $TRIGGER_LOCATION"

# 이전 생성 잔재 트리거를 안전하게 삭제
gcloud eventarc triggers delete "$TRIGGER_NAME" --location="$TRIGGER_LOCATION" --project="$GOOGLE_CLOUD_PROJECT" --quiet >/dev/null 2>&1 || true
gcloud eventarc triggers delete "$TRIGGER_NAME" --location="$GCP_RESOURCES_LOCATION" --project="$GOOGLE_CLOUD_PROJECT" --quiet >/dev/null 2>&1 || true

gcloud eventarc triggers create "$TRIGGER_NAME" \
  --location="$TRIGGER_LOCATION" \
  --project="$GOOGLE_CLOUD_PROJECT" \
  --destination-run-service="$SERVICE_NAME" \
  --destination-run-path="/trigger/eventarc" \
  --destination-run-region="$GCP_RESOURCES_LOCATION" \
  --event-filters="type=google.cloud.storage.object.v1.finalized" \
  --event-filters="bucket=$TRIGGER_BUCKET" \
  --service-account="$SA_EMAIL"

# 6. Frontend Gradio Dashboard 배포 (Cloud Run)
echo "----------------------------------------------------------------------"
echo "🖥️  5단계: Frontend 대시보드를 Cloud Run에 배포합니다... ($FRONTEND_SERVICE_NAME)"
echo "----------------------------------------------------------------------"

# frontend 소스 디렉토리에서 Cloud Run에 다이렉트 소스 빌드 배포를 진행합니다.
# Gradio 구동 포트인 7860을 Cloud Run 서비스에 명시적으로 노출시킵니다.
gcloud run deploy "$FRONTEND_SERVICE_NAME" \
  --source ./frontend \
  --region "$GCP_RESOURCES_LOCATION" \
  --project "$GOOGLE_CLOUD_PROJECT" \
  --port=7860 \
  --allow-unauthenticated \
  --set-env-vars="STAGING_BUCKET_URI=$STAGING_BUCKET_URI" \
  --service-account="$SA_EMAIL"

# 배포된 Frontend URL 획득
FRONTEND_URL=$(gcloud run services describe "$FRONTEND_SERVICE_NAME" --region "$GCP_RESOURCES_LOCATION" --project "$GOOGLE_CLOUD_PROJECT" --format 'value(status.url)')

echo "======================================================================"
echo "🎉 모든 배포 및 Eventarc 트리거 연동이 성공적으로 완료되었습니다!"
echo "======================================================================"
echo "👉 Backend Agent 트리거 URL: $RUN_URL"
echo "👉 Frontend 대시보드 URL : $FRONTEND_URL"
echo "======================================================================"

