#!/bin/bash

# ==============================================================================
#  Cloud SQL (MySQL) 8.4 Upgrade Checker & GCS Uploader Script
# ==============================================================================
#  설명: Google Cloud SQL (MySQL 8.0) 인스턴스를 대상으로 Cloud SQL Auth Proxy를
#        이용해 보안 터널을 생성한 뒤, MySQL Shell Upgrade Checker를 실행하여
#        8.4 호환성을 검사하고 결과를 GCS의 'check-results/' 하위에 자동 업로드합니다.
# ==============================================================================

# 에러 발생 시 스크립트 즉시 중단 (단, mysqlsh 호환성 에러 코드는 예외 처리)
set -uo pipefail

# ------------------------------------------------------------------------------
#  1. 환경 설정 (Cloud SQL 인스턴스 정보에 맞게 수정하세요)
# ------------------------------------------------------------------------------
# Cloud SQL 인스턴스의 연결 이름 (GCP 콘솔의 Cloud SQL 개요에서 확인 가능)
# 형식: "프로젝트-ID:리전:인스턴스-ID"
INSTANCE_CONNECTION_NAME="your-project-id:asia-northeast3:your-instance-id"

DB_HOST="127.0.0.1"                 # Cloud SQL Auth Proxy가 띄울 루프백 주소
DB_PORT="3306"                      # Proxy 수신 포트
DB_USER="root"                      # Cloud SQL 관리자 계정 또는 root
DB_PASSWORD=""                      # 임시로 비밀번호를 설정할 수 있습니다. (비워둘 시 프롬프트 입력)
GCS_BUCKET="mysql-upgarde_checker" # GCS 버킷 이름 (gs:// 제외)
GCS_PREFIX="check-results"         # Eventarc가 감지하는 경로 접두사

PROXY_PID=""                       # 자동 실행한 Proxy의 PID를 임시 기록할 변수

# [🌟 필수 보정 및 교육적 가이드] DB_HOST 오설정 복구 로직
# 많은 DBA/개발자 분들이 DB_HOST에 실제 Cloud SQL 인스턴스의 공인/사설 IP(예: 136.x.x.x)를 입력하는 실수를 하십니다.
# 하지만 Cloud SQL Auth Proxy 연동 시에는, 프록시 데몬이 로컬 루프백(127.0.0.1)에서 포트를 리슨하고, 
# 실제 구글 클라우드로의 암호화 터널링은 프록시 내부적으로 INSTANCE_CONNECTION_NAME을 기반으로 자동 처리합니다.
# 따라서 로컬 터널을 올바르게 활용하기 위해 DB_HOST는 반드시 '127.0.0.1' 또는 'localhost'여야 합니다.
if [[ "$DB_HOST" != "127.0.0.1" && "$DB_HOST" != "localhost" ]]; then
    echo "⚠️  알림: 설정된 DB_HOST('$DB_HOST')가 로컬 루프백 주소가 아닙니다."
    echo "💡  이유: Cloud SQL Auth Proxy를 사용한 연결 시, DB 클라이언트(mysqlsh)는"
    echo "       원격 IP가 아닌 프록시가 대기하는 로컬 주소(127.0.0.1)로 접속해야 합니다."
    echo "🔄  안전하고 올바른 프록시 바인딩을 위해 DB_HOST를 '127.0.0.1'로 강제 조정한 후 기동합니다."
    DB_HOST="127.0.0.1"
fi

# ------------------------------------------------------------------------------
#  2. 필수 도구 설치 여부 확인 및 자동 다운로드 (MySQL Shell 8.4)
# ------------------------------------------------------------------------------
echo "🔍 필수 유틸리티 검사 중..."

# 로컬 무설치(Portable) MySQL Shell 8.4 경로 정의
LOCAL_MYSQLSH_DIR="${HOME}/.mysqlsh-8.4"
LOCAL_MYSQLSH="${LOCAL_MYSQLSH_DIR}/bin/mysqlsh"

if [ -f "$LOCAL_MYSQLSH" ]; then
    echo "✅ 로컬 무설치 MySQL Shell 8.4가 감지되었습니다. 이를 분석에 사용합니다."
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
        echo "   Cloud SQL 인스턴스(${SYSTEM_VERSION}) 호환성 분석을 위해 MySQL Shell 8.4 (LTS) 무설치 패키지를 자동 다운로드합니다..."
        
        mkdir -p "${LOCAL_MYSQLSH_DIR}"
        TEMP_TAR="/tmp/mysql-shell-8.4.0.tar.gz"
        
        echo "📥 다운로드 진행 중 (공식 CDN에서 안전하게 캐싱)..."
        if curl -L "https://dev.mysql.com/get/Downloads/MySQL-Shell/mysql-shell-8.4.0-linux-glibc2.28-x86-64bit.tar.gz" -o "${TEMP_TAR}"; then
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
    echo "🆕 시스템에 'mysqlsh'가 발견되지 않았습니다. MySQL Shell 8.4 (LTS) 무설치 버전을 다운로드합니다..."
    mkdir -p "${LOCAL_MYSQLSH_DIR}"
    TEMP_TAR="/tmp/mysql-shell-8.4.0.tar.gz"
    
    if curl -L "https://dev.mysql.com/get/Downloads/MySQL-Shell/mysql-shell-8.4.0-linux-glibc2.28-x86-64bit.tar.gz" -o "${TEMP_TAR}"; then
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
TEMP_FILE="mysql_upgrade_report_${TIMESTAMP}.json"

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
#  7. GCS 업로드 및 로컬 파일 정리
# ------------------------------------------------------------------------------
GCS_TARGET_PATH="gs://${GCS_BUCKET}/${GCS_PREFIX}/${TEMP_FILE}"
echo "☁️ GCS 업로드 진행 중 (${GCS_TARGET_PATH})..."

if gcloud storage cp "${TEMP_FILE}" "${GCS_TARGET_PATH}"; then
    echo "🎉 성공: 업그레이드 검사 로그가 GCS에 정상적으로 업로드되었습니다."
    echo "👉 대상 경로: ${GCS_TARGET_PATH}"
    rm -f "${TEMP_FILE}"
    echo "🧹 로컬 임시 파일이 정상적으로 정리되었습니다."
else
    echo "❌ 에러: GCS 업로드에 실패했습니다. gcloud 로그인 상태 및 버킷 쓰기 권한을 확인하세요."
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


