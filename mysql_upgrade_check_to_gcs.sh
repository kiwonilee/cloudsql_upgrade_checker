#!/bin/bash

# ==============================================================================
#  Cloud SQL (MySQL) 8.4 Upgrade Checker & GCS Uploader Script
# ==============================================================================
#  설명: Google Cloud SQL (MySQL 8.0) 인스턴스를 대상으로 Cloud SQL Auth Proxy를
#        이용해 보안 터널을 생성한 뒤, MySQL Shell Upgrade Checker를 실행하여
#        8.4 호환성을 검사하고 결과를 GCS의 'check-results/' 하위에 자동 업로드합니다.
# ==============================================================================

set -uo pipefail

# ==============================================================================
#  1. 필수 환경 설정 (🔥 REQUIRED: 필수 작성 정보)
# ==============================================================================
#  ⚠️ [중요] 스크립트 실행 전, 아래 2가지 변수는 본인의 GCP 환경에 맞게 "반드시" 수정해야 합니다.
# ==============================================================================

# [1] 대상 Cloud SQL 인스턴스의 연결 이름 (GCP 콘솔 -> Cloud SQL 개요에서 확인)
# 형식: "프로젝트-ID:리전:인스턴스-ID"
INSTANCE_CONNECTION_NAME="your-project-id:asia-northeast3:your-instance-id"

# [2] 검사 결과(.json)를 업로드할 Cloud Storage (GCS) 버킷 이름 (gs:// 접두사 제외)
GCS_BUCKET="mysql-upgrade-checker"


# ==============================================================================
#  2. 고급 옵션 설정 (⚙️ OPTIONAL: 일반적인 경우 기본값 유지를 권장합니다)
# ==============================================================================
# Cloud SQL Auth Proxy 연동 시, DB_HOST는 반드시 '127.0.0.1' 또는 'localhost'여야 합니다.
DB_HOST="127.0.0.1"                 # Cloud SQL Auth Proxy가 바인딩할 로컬 루프백 주소 
DB_PORT="3306"                      # Proxy 수신 로컬 포트 (기본: 3306)
DB_USER="root"                      # Cloud SQL 접속 계정명 (기본: root)
DB_PASSWORD=""                      # 비밀번호 하드코딩용 (비워두면 실행 시 마스킹 대화형 입력 작동)
GCS_PREFIX="check-results"         # 버킷 내 저장 폴더 경로 접두사 (Eventarc 트리거 타겟)

PROXY_PID=""                       # 자동 실행한 Proxy의 PID를 임시 기록할 변수
# ==============================================================================

# ------------------------------------------------------------------------------
#  2. 필수 도구 설치 여부 확인 및 자동 다운로드 (MySQL Shell 8.4)
# ------------------------------------------------------------------------------
echo "🔍 필수 유틸리티 검사 중..."

MYSQLSH_VERSION="8.4.0" # 향후 마이너 버전 업데이트 대응을 위해 변수화

# CPU 아키텍처 자동 감지 (x86_64, aarch64 대응)
ARCH=$(uname -m)
if [ "$ARCH" = "x86_64" ]; then
    DOWNLOAD_ARCH="linux-glibc2.28-x86-64bit"
elif [ "$ARCH" = "aarch64" ] || [ "$ARCH" = "arm64" ]; then
    DOWNLOAD_ARCH="linux-glibc2.28-arm-64bit"
else
    DOWNLOAD_ARCH="linux-glibc2.28-x86-64bit" # 기본값 폴백
fi

# 로컬 무설치(Portable) MySQL Shell 경로 정의
LOCAL_MYSQLSH_DIR="${HOME}/.mysqlsh-${MYSQLSH_VERSION}"
LOCAL_MYSQLSH="${LOCAL_MYSQLSH_DIR}/bin/mysqlsh"

if [ -f "$LOCAL_MYSQLSH" ]; then
    echo "✅ 로컬 무설치 MySQL Shell ${MYSQLSH_VERSION}이 감지되었습니다. 이를 분석에 사용합니다."
    MYSQLSH_CMD="$LOCAL_MYSQLSH"
elif command -v mysqlsh &> /dev/null; then
    # 기존 시스템 mysqlsh 버전 확인
    SYSTEM_VERSION=$(mysqlsh --version | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n 1 || echo "0.0.0")
    MAJOR_VER=$(echo "$SYSTEM_VERSION" | cut -d. -f1)
    MINOR_VER=$(echo "$SYSTEM_VERSION" | cut -d. -f2)
    
    # 8.4.x 미만인 경우 (예: 8.0.x)
    # 8.0.x 대의 오래된 MySQL Shell은 8.0.45 서버처럼 새로운 버전의 서버 업그레이드 분석을 할 수 없습니다.
    # 따라서 8.4 LTS 무설치 포터블 패키지를 백그라운드에서 실시간 다운로드하여 실행합니다.
    if [ "$MAJOR_VER" -lt 8 ] || { [ "$MAJOR_VER" -eq 8 ] && [ "$MINOR_VER" -lt 4 ]; }; then
        echo "⚠️  알림: 시스템에 설치된 MySQL Shell 버전(${SYSTEM_VERSION})이 대상 업그레이드 버전(8.4)보다 낮습니다."
        echo "   Cloud SQL 인스턴스(${SYSTEM_VERSION}) 호환성 분석을 위해 MySQL Shell ${MYSQLSH_VERSION} (LTS) 무설치 패키지를 자동 다운로드합니다..."
        
        mkdir -p "${LOCAL_MYSQLSH_DIR}"
        TEMP_TAR="/tmp/mysql-shell-${MYSQLSH_VERSION}.tar.gz"
        
        echo "📥 다운로드 진행 중 (공식 CDN에서 안전하게 캐싱)..."
        if curl -L "https://dev.mysql.com/get/Downloads/MySQL-Shell/mysql-shell-${MYSQLSH_VERSION}-${DOWNLOAD_ARCH}.tar.gz" -o "${TEMP_TAR}"; then
            echo "📦 압축 해제 중..."
            tar -xf "${TEMP_TAR}" -C "${LOCAL_MYSQLSH_DIR}" --strip-components=1
            rm -f "${TEMP_TAR}"
            echo "✅ 다운로드 및 압축 해제 완료! (${LOCAL_MYSQLSH})"
            MYSQLSH_CMD="$LOCAL_MYSQLSH"
        else
            echo "❌ 에러: 무설치 패키지 다운로드에 실패했습니다. 시스템에 제공된 이전 버전으로 폴백합니다."
            MYSQLSH_CMD="mysqlsh"
        fi
    else
        echo "✅ 시스템에 적합한 MySQL Shell 버전(${SYSTEM_VERSION})이 설치되어 있습니다."
        MYSQLSH_CMD="mysqlsh"
    fi
else
    # 아예 없을 경우 다운로드 진행
    echo "🆕 시스템에 'mysqlsh'가 발견되지 않았습니다. MySQL Shell ${MYSQLSH_VERSION} (LTS) 무설치 버전을 다운로드합니다..."
    mkdir -p "${LOCAL_MYSQLSH_DIR}"
    TEMP_TAR="/tmp/mysql-shell-${MYSQLSH_VERSION}.tar.gz"
    
    if curl -L "https://dev.mysql.com/get/Downloads/MySQL-Shell/mysql-shell-${MYSQLSH_VERSION}-${DOWNLOAD_ARCH}.tar.gz" -o "${TEMP_TAR}"; then
        tar -xf "${TEMP_TAR}" -C "${LOCAL_MYSQLSH_DIR}" --strip-components=1
        rm -f "${TEMP_TAR}"
        echo "✅ 다운로드 및 가동 준비 완료!"
        MYSQLSH_CMD="$LOCAL_MYSQLSH"
    else
        echo "❌ 에러: 'mysqlsh'가 설치되어 있지 않고, 자동 다운로드에도 실패했습니다."
        echo "👉 수동 설치 가이드: https://dev.mysql.com/doc/mysql-shell/8.4/en/mysql-shell-install.html"
        exit 1
    fi
fi

if ! command -v gcloud &> /dev/null; then
    echo "❌ 에러: 'gcloud' CLI가 설치되어 있지 않습니다."
    echo "👉 설치 가이드: https://cloud.google.com/sdk/docs/install"
    exit 1
fi

if ! command -v cloud-sql-proxy &> /dev/null; then
    echo "❌ 에러: 'cloud-sql-proxy' 가 설치되어 있지 않습니다."
    echo "👉 설치 가이드: https://cloud.google.com/sql/docs/mysql/sql-proxy#install"
    exit 1
fi

# ------------------------------------------------------------------------------
#  3. Cloud SQL Auth Proxy 작동 상태 검사 및 기동
# ------------------------------------------------------------------------------
# 특정 호스트/포트가 열려 있는지 테스트하는 초경량 함수 (Python socket 모듈 사용으로 이식성 100% 보장)
# nc(netcat) 명령어의 유무나 배포판별 버전에 구애받지 않고 항상 신뢰성 있게 동작합니다.
is_port_open() {
    local host="$1"
    local port="$2"
    python3 -c "import socket; s = socket.socket(); s.settimeout(1); s.connect(('$host', $port))" 2>/dev/null
}

echo "🔌 Cloud SQL Auth Proxy 연동 상태 분석 중..."

# 로컬 포트 3306이 활성화되어 있는지(이미 별도로 프록시를 켜두었는지) 확인
if is_port_open "$DB_HOST" "$DB_PORT"; then
    echo "✅ 이미 $DB_HOST:$DB_PORT 포트가 열려 있습니다. 기존에 구동 중인 Proxy 터널을 이용합니다."
else
    # 지정한 연결 이름이 플레이스홀더 그대로인지 확인
    if [[ "$INSTANCE_CONNECTION_NAME" == *"your-project-id"* ]]; then
        echo "❌ 에러: INSTANCE_CONNECTION_NAME을 실제 Cloud SQL 연결 이름으로 수정해 주세요."
        exit 1
    fi

    echo "🆕 기존에 켜져 있는 프록시가 없습니다. 백그라운드에서 Cloud SQL Auth Proxy를 자동 기동합니다..."
    
    # [🌟 근본적 해결책] Cloud SQL Auth Proxy v2의 표준 바인딩 플래그 규격을 사용합니다.
    # v1용 '=tcp:IP:port' 매핑 문법은 v2에서 오파싱(Parsing Error)되어 잘못된 인스턴스명으로 API 호출을 시도해 400 에러를 유발합니다.
    # v2의 표준 방식인 --address 및 --port 플래그를 지정하여 강제로 로컬 루프백(127.0.0.1)에 바인딩합니다.
    cloud-sql-proxy --address "$DB_HOST" --port "$DB_PORT" "$INSTANCE_CONNECTION_NAME" &
    PROXY_PID=$!
    
    # 프록시가 완전히 켜져서 포트를 확보할 때까지 잠시 대기 (최대 10초)
    echo "⏳ 프록시 터널이 준비되기를 기다리는 중..."
    for i in {1..10}; do
        if is_port_open "$DB_HOST" "$DB_PORT"; then
            echo "✅ Cloud SQL Auth Proxy 터널 연결 완료! (PID: $PROXY_PID)"
            break
        fi
        sleep 1
        if [ "$i" -eq 10 ]; then
            echo "❌ 에러: Cloud SQL Auth Proxy 기동에 실패했거나 연결 제한 시간이 초과되었습니다."
            kill "$PROXY_PID" 2>/dev/null || true
            exit 1
        fi
    done
fi

# ------------------------------------------------------------------------------
#  4. 입력 파라미터 및 비밀번호 입력 받기
# ------------------------------------------------------------------------------
# 비밀번호가 상단 환경 설정(DB_PASSWORD)에 정의되어 있지 않은 경우에만 대화형 프롬프트로 입력받습니다.
if [ -z "${DB_PASSWORD:-}" ]; then
    read -rsp "🔑 Cloud SQL User [${DB_USER}]의 비밀번호를 입력하세요: " DB_PASSWORD
    echo ""
fi

if [ -z "$DB_PASSWORD" ]; then
    echo "❌ 에러: 비밀번호가 입력되지 않았습니다."
    [ -n "$PROXY_PID" ] && kill "$PROXY_PID" 2>/dev/null || true
    exit 1
fi

# ------------------------------------------------------------------------------
#  5. 파일명 및 임시 경로 정의
# ------------------------------------------------------------------------------
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
TEMP_FILE="mysql_upgrade_checker_${TIMESTAMP}.json"

# ------------------------------------------------------------------------------
#  6. MySQL Shell Upgrade Checker 실행
# ------------------------------------------------------------------------------
echo "🚀 Cloud SQL (MySQL) 8.4 업그레이드 호환성 검사 시작..."
echo "📍 대상 DB (Proxy 경유): ${DB_USER}@${DB_HOST}:${DB_PORT}"

# mysqlsh는 호환성 위반 사항(Warning/Error)을 찾으면 Exit Code 1 또는 2를 반환할 수 있습니다.
# 따라서 스크립트가 도중에 튕기지 않도록 '|| true' 처리를 해줍니다.
# 디버깅 편의성을 위해 에러 출력(stderr)은 임시 로그 파일에 별도로 기록합니다.
# [🌟 근본적 해결책] mysqlsh의 --check-for-server-upgrade는 독립된 CLI 옵션이 아니라
# mysqlsh 내부의 util API에 매핑된 함수명이므로, '-- util checkForServerUpgrade' 형식의 표준 커맨드로 수행해야 합니다.
# 프로세스 목록(ps -ef)에서 비밀번호 노출을 방지하기 위해 MYSQLSH_USER_PASSWORD 환경 변수를 활용합니다.
# --password 플래그를 생략하면 mysqlsh가 이 환경 변수를 안전하게 자동 인식합니다.
ERR_LOG="${TEMP_FILE}.err"

"${MYSQLSH_CMD}" -- util checkForServerUpgrade { \
            --user="${DB_USER}" \
            --host="${DB_HOST}" \
            --port="${DB_PORT}" \
            --password="${DB_PASSWORD}" \
        } \
        --target-version=8.4 \
        --output-format=JSON > "${TEMP_FILE}" 2> "${ERR_LOG}" || true

# 파일이 정상적으로 생성되고 비어있지 않은지 확인
if [ ! -s "${TEMP_FILE}" ]; then
    echo "❌ 에러: 업그레이드 검사 결과 파일 생성에 실패했거나 파일이 비어 있습니다."
    if [ -s "${ERR_LOG}" ]; then
        echo "🔍 [상세 에러 로그]"
        cat "${ERR_LOG}"
    fi
    echo "👉 DB 비밀번호 혹은 gcloud 권한(Cloud SQL Client) 등을 확인하세요."
    [ -f "${TEMP_FILE}" ] && rm -f "${TEMP_FILE}"
    [ -f "${ERR_LOG}" ] && rm -f "${ERR_LOG}"
    [ -n "$PROXY_PID" ] && kill "$PROXY_PID" 2>/dev/null || true
    exit 1
fi

# 정상 작동한 경우 에러 파일 정리
[ -f "${ERR_LOG}" ] && rm -f "${ERR_LOG}"

echo "✅ 검사 완료! 결과가 로컬 파일에 임시 저장되었습니다: ${TEMP_FILE}"

# ------------------------------------------------------------------------------
#  7. GCS 업로드 진행
# ------------------------------------------------------------------------------
GCS_TARGET_PATH="gs://${GCS_BUCKET}/${GCS_PREFIX}/${TEMP_FILE}"
echo "☁️ GCS 업로드 진행 중 (${GCS_TARGET_PATH})..."

if gcloud storage cp "${TEMP_FILE}" "${GCS_TARGET_PATH}"; then
    echo "🎉 성공: 업그레이드 검사 로그가 GCS에 정상적으로 업로드되었습니다."
    echo "👉 대상 경로: ${GCS_TARGET_PATH}"
else
    echo "❌ 에러: GCS 업로드에 실패했습니다. gcloud 로그인 상태 및 버킷 쓰기 권한을 확인하세요."
    [ -f "${TEMP_FILE}" ] && rm -f "${TEMP_FILE}"
    [ -n "$PROXY_PID" ] && kill "$PROXY_PID" 2>/dev/null || true
    exit 1
fi

# ------------------------------------------------------------------------------
#  8. 자동 구동했던 Cloud SQL Auth Proxy 안전하게 종료
# ------------------------------------------------------------------------------
if [ -n "$PROXY_PID" ]; then
    echo "🔌 임시 가동했던 Cloud SQL Auth Proxy 터널을 정상 차단합니다..."
    kill "$PROXY_PID" 2>/dev/null || true
    echo "✅ 프록시 정리 완료."
fi

echo "=============================================================================="
echo "🎯 모든 작업이 성공적으로 종료되었습니다."
echo "   Cloud Run 에이전트가 GCS 업로드를 자동으로 감지하여 보고서를 작성할 것입니다."
echo "=============================================================================="

# ------------------------------------------------------------------------------
#  9. 생성된 검사 결과 출력 (STDOUT) 및 로컬 파일 최종 정리
# ------------------------------------------------------------------------------
echo ""
echo "📋 [검사 결과 리포트 원문 (JSON)]"
echo "------------------------------------------------------------------------------"
if [ -f "${TEMP_FILE}" ]; then
    cat "${TEMP_FILE}"
    echo ""
    echo "------------------------------------------------------------------------------"
    rm -f "${TEMP_FILE}"
    echo "🧹 로컬 임시 파일이 성공적으로 정리되었습니다."
else
    echo "⚠️ 알림: 출력할 임시 리포트 원본 파일이 발견되지 않았습니다."
fi
echo "=============================================================================="


