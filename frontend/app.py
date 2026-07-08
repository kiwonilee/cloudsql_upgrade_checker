import os
from datetime import timedelta
import gradio as gr
from google.cloud import storage
from dotenv import load_dotenv

# .env 파일 로드 (부모 디렉토리 기준)
env_path = os.path.abspath(os.path.join(os.path.dirname(__file__), '../.env'))
load_dotenv(env_path)

STAGING_BUCKET_URI = os.getenv("STAGING_BUCKET_URI")
if not STAGING_BUCKET_URI:
    raise ValueError("STAGING_BUCKET_URI is not set in .env")

# gs:// 접두사 제거하여 bucket name 추출
bucket_name = STAGING_BUCKET_URI.replace("gs://", "")

# GCS 클라이언트 초기화
storage_client = storage.Client()
bucket = storage_client.bucket(bucket_name)

# 캐시/매핑용 딕셔너리 (파일명 -> GCS 전체 경로)
path_map = {}

def get_report_files():
    """GCS reports/ 디렉토리에서 .md 파일을 조회하여 생성일자 기준 내림차순 정렬 후 반환합니다."""
    global path_map
    try:
        blobs = storage_client.list_blobs(bucket, prefix="reports/")
        md_files = []
        for blob in blobs:
            if blob.name.endswith(".md"):
                # 상세 메타데이터(time_created 등) 원격 로드 강제화
                blob.reload()
                # GCS time_created(UTC)를 한국 시간(KST, UTC+9)으로 올바르게 변환 및 포맷팅
                kst_time = blob.time_created + timedelta(hours=9)
                display_name = kst_time.strftime("📅 %Y-%m-%d %H:%M:%S")
                
                md_files.append({
                    "full_path": blob.name,
                    "display_name": display_name,
                    "created": blob.time_created
                })
        
        # 생성 시간(created) 기준 내림차순 정렬 (가장 최근에 생성된 파일이 0번 인덱스)
        md_files.sort(key=lambda x: x["created"], reverse=True)
        
        # path_map 업데이트
        path_map = {f["display_name"]: f["full_path"] for f in md_files}
        
        return md_files
    except Exception as e:
        print(f"GCS 버킷 조회 에러: {e}")
        return []

def read_file_content(blob_name):
    """GCS에서 특정 파일의 텍스트 본문을 읽어옵니다."""
    try:
        blob = bucket.blob(blob_name)
        content = blob.download_as_text(encoding="utf-8")
        return content
    except Exception as e:
        return f"### ❌ 파일 읽기 실패\n\n파일({blob_name})을 읽는 중 오류가 발생했습니다.\n\n**에러 내용:** {str(e)}"

# 고도화된 세련된 커스텀 CSS (글래스모피즘, 프리미엄 폰트, 입체 카드 디자인)
custom_css = """
@import url('https://fonts.googleapis.com/css2?family=Outfit:wght@300;400;500;600;700&family=JetBrains+Mono:wght@400;500&display=swap');

/* 전체 컨테이너 및 폰트 고도화 */
body, .gradio-container {
    font-family: 'Outfit', -apple-system, BlinkMacSystemFont, sans-serif !important;
}

/* 라이트 모드 배경 (기본) */
body, .gradio-container {
    background-color: #f8fafc !important;
    transition: background-color 0.3s ease;
}

/* 다크 모드 배경 */
.dark body, .dark .gradio-container {
    background-color: #0b0f19 !important;
}

/* 상단 메인 헤더 카드 - 라이트/다크 대응 */
.report-title-card {
    background: linear-gradient(135deg, #ffffff 0%, #f1f5f9 100%) !important;
    border: 1px solid rgba(226, 232, 240, 0.8) !important;
    box-shadow: 0 10px 25px -5px rgba(0, 0, 0, 0.05) !important;
    padding: 30px !important;
    border-radius: 18px !important;
    margin-bottom: 24px !important;
    position: relative;
    overflow: hidden;
    transition: all 0.3s ease;
}

.dark .report-title-card {
    background: linear-gradient(135deg, rgba(17, 24, 39, 0.9) 0%, rgba(31, 41, 55, 0.8) 100%) !important;
    border: 1px solid rgba(255, 255, 255, 0.08) !important;
    box-shadow: 0 10px 30px -10px rgba(0, 0, 0, 0.5) !important;
}

.report-title-card::before {
    content: '';
    position: absolute;
    top: -50%;
    left: -50%;
    width: 200%;
    height: 200%;
    background: radial-gradient(circle, rgba(59, 130, 246, 0.08) 0%, transparent 60%);
    pointer-events: none;
}

.dark .report-title-card::before {
    background: radial-gradient(circle, rgba(59, 130, 246, 0.12) 0%, transparent 60%);
}

.report-title-card h1 {
    font-size: 2.3rem !important;
    font-weight: 700 !important;
    letter-spacing: -0.03em !important;
    background: linear-gradient(to right, #1d4ed8, #6d28d9) !important;
    -webkit-background-clip: text !important;
    -webkit-text-fill-color: transparent !important;
    margin: 0 0 10px 0 !important;
}

.dark .report-title-card h1 {
    background: linear-gradient(to right, #60a5fa, #a78bfa) !important;
    -webkit-background-clip: text !important;
    -webkit-text-fill-color: transparent !important;
}

.report-title-card p {
    color: #475569 !important;
    font-size: 1.05rem !important;
    font-weight: 400 !important;
    margin: 0 !important;
}

.dark .report-title-card p {
    color: #9ca3af !important;
}

/* 제목 라벨 꾸미기 (가시성 확보를 위해 폰트 크기 상향) */
.section-title {
    font-size: 1.45rem !important;
    font-weight: 700 !important;
    color: #1e293b !important;
    margin-bottom: 12px !important;
    letter-spacing: -0.015em;
    transition: color 0.3s ease;
}

.dark .section-title {
    color: #f3f4f6 !important;
}

/* 파일 리스트 스크롤 영역 */
#report-list-container {
    max-height: calc(100vh - 270px) !important;
    overflow-y: auto !important;
    border: 1px solid rgba(226, 232, 240, 0.8) !important;
    border-radius: 16px !important;
    padding: 16px !important;
    background-color: #ffffff !important;
    background: #ffffff !important;
    box-shadow: inset 0 2px 4px rgba(0, 0, 0, 0.02) !important;
    transition: all 0.3s ease;
}

.dark #report-list-container {
    border: 1px solid rgba(255, 255, 255, 0.08) !important;
    background-color: rgba(17, 24, 39, 0.5) !important;
    background: rgba(17, 24, 39, 0.5) !important;
    box-shadow: inset 0 2px 4px rgba(0, 0, 0, 0.2) !important;
}

/* 폼 요소 내부의 Gradio 기본 회색 컴포넌트 배경 및 모든 자식 요소들을 기본 투명화 처리 */
#report-list-container * {
    background-color: transparent !important;
    background: transparent !important;
}

/* fieldset 및 대형 박스 테두리와 그림자 제거 */
#report-list-container .gradio-radio,
#report-list-container fieldset,
#report-list-container .block,
#report-list-container .form,
#report-list-container .wrap {
    border: none !important;
    box-shadow: none !important;
    padding: 0 !important;
    background-color: transparent !important;
    background: transparent !important;
}

/* 카드 라벨 내부의 글씨(span) 등 자식 노드의 배경을 완전히 투명화하여, 카드 배경(흰색, 다크색, 또는 선택 시 파란색 그라디언트)과 충돌하지 않도록 함 */
#report-list-container label *,
#report-list-container label span {
    background-color: transparent !important;
    background: transparent !important;
}

/* 라디오 컴포넌트 안의 "조회할 리포트 선택" 라벨 스타일링 (완전한 화이트 백그라운드 및 세련된 연회색 보더) */
#report-list-container .block-label {
    background-color: #ffffff !important;
    background: #ffffff !important;
    border: 1px solid rgba(226, 232, 240, 0.8) !important;
    font-weight: 700 !important;
    color: #1e293b !important;
    font-size: 0.85rem !important;
    text-transform: uppercase !important;
    letter-spacing: 0.05em !important;
    margin-bottom: 16px !important;
    box-shadow: 0 2px 4px rgba(0, 0, 0, 0.02) !important;
    padding: 10px 16px !important;
    border-radius: 10px !important;
    display: inline-block !important;
    width: auto !important;
    max-width: max-content !important;
}

.dark #report-list-container .block-label {
    background-color: rgba(31, 41, 55, 0.6) !important;
    background: rgba(31, 41, 55, 0.6) !important;
    border-color: rgba(255, 255, 255, 0.05) !important;
    color: #cbd5e1 !important;
}

/* 스크롤바 세련화 */
#report-list-container::-webkit-scrollbar {
    width: 6px;
}
#report-list-container::-webkit-scrollbar-track {
    background: transparent;
}
#report-list-container::-webkit-scrollbar-thumb {
    background: rgba(0, 0, 0, 0.1);
    border-radius: 10px;
}
.dark #report-list-container::-webkit-scrollbar-thumb {
    background: rgba(255, 255, 255, 0.1);
}
#report-list-container::-webkit-scrollbar-thumb:hover {
    background: rgba(0, 0, 0, 0.2);
}
.dark #report-list-container::-webkit-scrollbar-thumb:hover {
    background: rgba(255, 255, 255, 0.2);
}

/* 새로고침 버튼 디자인 */
.refresh-btn-custom {
    background: linear-gradient(135deg, #3b82f6 0%, #2563eb 100%) !important;
    color: white !important;
    border: none !important;
    border-radius: 12px !important;
    font-weight: 600 !important;
    padding: 10px 16px !important;
    box-shadow: 0 4px 14px rgba(59, 130, 246, 0.2) !important;
    transition: all 0.25s cubic-bezier(0.4, 0, 0.2, 1) !important;
}

.refresh-btn-custom:hover {
    transform: translateY(-2px) !important;
    box-shadow: 0 6px 20px rgba(59, 130, 246, 0.35) !important;
}

/* 라디오 목록 카드형 배치 개조 */
#report-list-container .wrap {
    display: flex !important;
    flex-direction: column !important;
    gap: 8px !important;
}

/* 라디오 각 항목 카드 스타일 (투명화 상속에서 제외하고 완벽한 흰색 카드로 고정) */
#report-list-container label {
    border: 1px solid rgba(226, 232, 240, 0.8) !important;
    background-color: #ffffff !important;
    background: #ffffff !important;
    border-radius: 12px !important;
    padding: 14px 18px !important;
    margin: 0 !important;
    cursor: pointer !important;
    transition: all 0.2s cubic-bezier(0.4, 0, 0.2, 1) !important;
    display: flex !important;
    align-items: center !important;
    color: #475569 !important;
}

.dark #report-list-container label {
    border: 1px solid rgba(255, 255, 255, 0.05) !important;
    background-color: rgba(31, 41, 55, 0.4) !important;
    background: rgba(31, 41, 55, 0.4) !important;
    color: #cbd5e1 !important;
}

#report-list-container label:hover {
    transform: translateX(4px) !important;
    border-color: rgba(59, 130, 246, 0.3) !important;
    background: #f1f5f9 !important;
    color: #1e293b !important;
}

.dark #report-list-container label:hover {
    border-color: rgba(59, 130, 246, 0.5) !important;
    background: rgba(31, 41, 55, 0.7) !important;
    color: #ffffff !important;
}

/* 선택된 라디오 카드 스타일 */
#report-list-container label.selected {
    background: linear-gradient(135deg, #eff6ff 0%, #dbeafe 100%) !important;
    border-color: #3b82f6 !important;
    box-shadow: 0 4px 15px rgba(59, 130, 246, 0.1) !important;
    color: #1d4ed8 !important;
    font-weight: 600 !important;
}

.dark #report-list-container label.selected {
    background: linear-gradient(135deg, rgba(37, 99, 235, 0.15) 0%, rgba(30, 58, 138, 0.25) 100%) !important;
    border-color: #3b82f6 !important;
    box-shadow: 0 4px 20px rgba(37, 99, 235, 0.2) !important;
    color: #60a5fa !important;
}

/* 라디오 기본 아이콘(동그라미)을 숨겨서 카드를 온전히 버튼 박스처럼 활용 */
#report-list-container label input[type="radio"] {
    display: none !important;
}

.report-content-box {
    background: #ffffff !important;
    border: 1px solid rgba(226, 232, 240, 0.8) !important;
    border-radius: 18px !important;
    padding: 35px !important;
    box-shadow: 0 10px 25px -5px rgba(0, 0, 0, 0.05) !important;
    color: #334155 !important;
    font-size: 1.15rem !important; /* 본문 가독성을 위해 기존 1.05rem에서 한 단계 더 글자 크기 확대 */
    line-height: 1.7 !important; /* 가독성 확보를 위한 넉넉한 줄간격 */
    transition: all 0.3s ease;
}

.dark .report-content-box {
    background: rgba(17, 24, 39, 0.7) !important;
    border: 1px solid rgba(255, 255, 255, 0.08) !important;
    box-shadow: 0 10px 30px rgba(0, 0, 0, 0.3) !important;
    color: #e5e7eb !important;
}

/* 마크다운 내부 타이포그래피 정밀 튜닝 */
.report-content-box h1 {
    font-size: 2.0rem !important; /* 제목 가시성 대폭 확대 */
    font-weight: 700 !important;
    color: #1e293b !important;
    border-bottom: 2px solid #e2e8f0 !important;
    padding-bottom: 14px !important;
    margin-top: 0 !important;
    margin-bottom: 20px !important;
    letter-spacing: -0.025em;
    transition: color 0.3s, border-color 0.3s;
}

.dark .report-content-box h1 {
    color: #ffffff !important;
    border-bottom: 2px solid rgba(255, 255, 255, 0.1) !important;
}

.report-content-box h2 {
    font-size: 1.55rem !important; /* 소제목 크기 상향 */
    font-weight: 600 !important;
    color: #334155 !important;
    margin-top: 24px !important;
    margin-bottom: 14px !important;
    letter-spacing: -0.015em;
    transition: color 0.3s;
}

.dark .report-content-box h2 {
    color: #f3f4f6 !important;
}

.report-content-box h3 {
    font-size: 1.25rem !important; /* 하위 헤더 크기 상향 */
    font-weight: 600 !important;
    color: #475569 !important;
    margin-top: 18px !important;
    margin-bottom: 10px !important;
    transition: color 0.3s;
}

.dark .report-content-box h3 {
    color: #e5e7eb !important;
}

/* 마크다운 테이블 디자인 극대화 */
.report-content-box table {
    width: 100% !important;
    border-collapse: collapse !important;
    margin: 24px 0 !important;
    font-size: 0.95rem !important;
}

.report-content-box th {
    background-color: #f8fafc !important;
    color: #475569 !important;
    font-weight: 600 !important;
    text-align: left !important;
    padding: 14px 18px !important;
    border-bottom: 2px solid #e2e8f0 !important;
    transition: background-color 0.3s, color 0.3s, border-color 0.3s;
}

.dark .report-content-box th {
    background-color: rgba(31, 41, 55, 0.8) !important;
    color: #9ca3af !important;
    border-bottom: 2px solid rgba(255, 255, 255, 0.1) !important;
}

.report-content-box td {
    padding: 14px 18px !important;
    border-bottom: 1px solid #e2e8f0 !important;
    color: #475569 !important;
    transition: border-color 0.3s, color 0.3s;
}

.dark .report-content-box td {
    border-bottom: 1px solid rgba(255, 255, 255, 0.05) !important;
    color: #cbd5e1 !important;
}

.report-content-box tr:hover {
    background-color: #f1f5f9 !important;
}

.dark .report-content-box tr:hover {
    background-color: rgba(255, 255, 255, 0.02) !important;
}

/* 코드 스타일 고도화 */
.report-content-box code {
    font-family: 'JetBrains Mono', monospace !important;
    font-size: 0.88em !important;
    background-color: #f1f5f9 !important;
    color: #0f172a !important;
    padding: 3px 6px !important;
    border-radius: 6px !important;
    border: 1px solid #e2e8f0 !important;
    transition: background-color 0.3s, color 0.3s, border-color 0.3s;
}

.dark .report-content-box code {
    background-color: rgba(31, 41, 55, 0.8) !important;
    color: #38bdf8 !important;
    border: 1px solid rgba(255, 255, 255, 0.05) !important;
}

.report-content-box pre {
    background-color: #f8fafc !important;
    border: 1px solid #e2e8f0 !important;
    border-radius: 12px !important;
    padding: 0 !important;
    margin: 16px 0 !important;
    overflow: hidden;
    transition: background-color 0.3s, border-color 0.3s;
}

.dark .report-content-box pre {
    background-color: rgba(17, 24, 39, 0.9) !important;
    border: 1px solid rgba(255, 255, 255, 0.08) !important;
}

.report-content-box pre code {
    padding: 18px !important;
    display: block !important;
    overflow-x: auto !important;
    color: #334155 !important;
    background-color: transparent !important;
    border: none !important;
}

.dark .report-content-box pre code {
    color: #cbd5e1 !important;
}
"""

def on_page_load():
    """사용자가 웹 UI에 접속(페이지 로드)할 때 실시간으로 GCS 목록과 최신 리포트 본문을 로드합니다."""
    files = get_report_files()
    choices = [f["display_name"] for f in files]
    
    if choices:
        selected = choices[0]
        content = read_file_content(path_map[selected])
    else:
        selected = None
        content = "### 📭 리포트 없음\n\n`reports/` 폴더에 조회 가능한 markdown 리포트 파일이 존재하지 않습니다."
        
    return (
        gr.Radio(choices=choices, value=selected),
        content,
        f"**총 {len(choices)} 개의 리포트가 조회되었습니다.**"
    )

def on_select_change(selected_name):
    """파일 리스트에서 다른 파일이 선택되었을 때 호출되는 이벤트 핸들러"""
    if not selected_name:
        return "### 📂 리포트를 선택해 주세요."
    full_path = path_map.get(selected_name)
    if not full_path:
        return "### ❌ 파일을 찾을 수 없습니다."
    return read_file_content(full_path)

def on_refresh():
    """새로고침 버튼이 클릭되었을 때 호출되는 이벤트 핸들러"""
    files = get_report_files()
    new_choices = [f["display_name"] for f in files]
    
    if new_choices:
        new_selected = new_choices[0]
        new_content = read_file_content(path_map[new_selected])
    else:
        new_selected = None
        new_content = "### 📭 리포트 없음\n\n`reports/` 폴더에 조회 가능한 markdown 리포트 파일이 존재하지 않습니다."
        
    return (
        gr.Radio(choices=new_choices, value=new_selected),
        new_content,
        f"**총 {len(new_choices)} 개의 리포트가 조회되었습니다.**"
    )

# 테마를 세련된 Soft 테마로 선택하고, 라이트 모드와 다크 모드의 설정을 명확히 분리합니다.
theme = gr.themes.Soft(
    primary_hue="blue",
    secondary_hue="slate",
    neutral_hue="slate"
).set(
    # 라이트 모드는 Soft 테마 본연의 깨끗하고 세련된 화이트를 사용하도록 비워두고,
    # 다크 모드에만 고급스러운 어두운 블루/네이비 색상들을 주입합니다.
    body_background_fill_dark="#0b0f19",
    block_background_fill_dark="#111827",
    block_border_color_dark="rgba(255, 255, 255, 0.08)",
    button_secondary_background_fill_dark="rgba(31, 41, 55, 0.5)"
)

# Gradio Blocks를 사용한 웹 UI 구성
with gr.Blocks(title="Cloud SQL Upgrade Checker Dashboard") as demo:
    # 상단 타이틀 카드 (HTML 사용)
    gr.HTML(f"""
    <div class="report-title-card">
        <h1>📊 Cloud SQL Upgrade Reports Dashboard</h1>
        <p>GCS 버킷 <code>{STAGING_BUCKET_URI}</code>의 <code>reports/</code> 하위에서 실시간 리포트를 탐색합니다.</p>
    </div>
    """)
    
    with gr.Row():
        # 왼쪽 프레임: 파일 리스트 (전체 너비의 1/5, 최소 너비 단축으로 공간 확보)
        with gr.Column(scale=1, min_width=260):
            gr.HTML('<div class="section-title">📂 Reports Directory</div>')
            
            # 리포트 통계 정보 (기본 로딩 상태 표시)
            stats_text = gr.Markdown("⏳ 리포트 목록을 조회하는 중...")
            
            # 새로고침 버튼
            refresh_btn = gr.Button("🔄 Refresh List", variant="secondary", elem_classes="refresh-btn-custom")
            
            # 스크롤 영역 지정을 위한 Group 블록
            with gr.Group(elem_id="report-list-container"):
                file_selector = gr.Radio(
                    choices=[],
                    value=None,
                    label="조회할 리포트 선택",
                    interactive=True
                )
        
        # 오른쪽 프레임: 파일 내용 (전체 너비의 4/5, 공간 확장)
        with gr.Column(scale=4):
            gr.HTML('<div class="section-title">📝 Report Analysis</div>')
            
            # Markdown 리포트 출력 영역 (기본 로딩 상태 표시)
            markdown_viewer = gr.Markdown(
                value="⏳ GCS에서 최신 리포트 분석 결과를 불러오는 중입니다...",
                line_breaks=True,
                elem_classes="report-content-box"
            )
                
    # 최초 접속 시(페이지 로드) 최신 목록 및 보고서 내용을 실시간 로딩
    demo.load(
        fn=on_page_load,
        inputs=[],
        outputs=[file_selector, markdown_viewer, stats_text]
    )

    # 파일 선택 변경 이벤트 연결
    file_selector.change(
        fn=on_select_change,
        inputs=[file_selector],
        outputs=[markdown_viewer]
    )
    
    # 새로고침 버튼 이벤트 연결
    refresh_btn.click(
        fn=on_refresh,
        inputs=[],
        outputs=[file_selector, markdown_viewer, stats_text]
    )

if __name__ == "__main__":
    # Gradio 앱 실행 (Gradio 6.0 스펙에 최적화하여 launch() 내에 css, theme 주입)
    demo.launch(
        server_name="0.0.0.0",
        server_port=7860,
        share=False,
        css=custom_css,
        theme=theme
    )
