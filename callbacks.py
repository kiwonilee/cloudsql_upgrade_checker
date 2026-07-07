import logging

# 로깅 환경 설정
logging.basicConfig(level=logging.INFO)
logger = logging.getLogger("cloudsql_upgrade_checker_callbacks")

async def log_final_report_callback(callback_context) -> None:
    """에이전트 구동이 완료된 후, 세션 히스토리에서 최종 생성 및 업로드된 마크다운 보고서 전문을 추출하여 로그로 출력합니다."""
    session = getattr(callback_context, "session", None)
    if not session or not hasattr(session, "events"):
        logger.warning("⚠️ 세션 정보가 누락되어 최종 리포트 로깅을 건너뜁니다.")
        return None

    # 세션 이벤트 목록을 역순으로 탐색하여 최종 보고서 마크다운을 로깅
    for event in reversed(session.events):
        if event.content and (getattr(event, "author", "") == "mysql_upgrade_checker" or getattr(event, "type", "") == "model"):
            logger.info("\n" + "="*80 + "\n📋 [GCS 저장 완료 - 최종 마크다운 리포트 전문 로그]\n" + "="*80 + f"\n{event.content}\n" + "="*80)
            break
    return None
