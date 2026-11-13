# ClaudeUsage — Claude 구독 사용량 바탕화면 위젯

Claude Pro/Max 구독의 **5시간 세션 한도**와 **주간 한도** 사용률을 맥 바탕화면에 실시간으로 띄워주는 작은 위젯입니다.

- 1단: 5시간 세션 사용률 막대
- 2단: 주간(전체) · 주간(모델별) 사용률 원형 차트
- 5분마다 자동 갱신 (요청 제한 시 자동으로 간격을 늘림), 초기화까지 남은 시간 표시
- 70% 이상 노란색, 90% 이상 빨간색으로 경고
- 바탕화면에 붙어 있어 다른 창 뒤에 깔림 · 드래그로 이동 (위치 기억)
- 우클릭 → 새로고침 / 종료
- Dock 아이콘 없음

## 요구 사항

- macOS 13 이상 (Apple Silicon, Intel 모두 지원)
- Claude **Pro 또는 Max** 구독
- [Claude Code](https://claude.com/claude-code) CLI 설치 및 로그인
- Xcode Command Line Tools (`xcode-select --install`)

## 설치

```bash
git clone https://github.com/jjimi77/ClaudeUsageWidget.git
cd ClaudeUsageWidget
./build.sh
```

Claude Code CLI에 로그인되어 있지 않다면 먼저 로그인합니다. (Claude 데스크톱 앱 로그인과는 별개입니다.)

```bash
claude auth login
```

위젯 실행:

```bash
open ~/Applications/ClaudeUsage.app
```

처음 실행할 때 **"security가 키체인 항목에 접근하려고 합니다"** 창이 뜨면 **항상 허용**을 눌러주세요.

### 맥 시작 시 자동 실행

```bash
osascript -e 'tell application "System Events" to make login item at end with properties {path:"'"$HOME"'/Applications/ClaudeUsage.app", hidden:true}'
```

해제: 시스템 설정 → 일반 → 로그인 항목에서 ClaudeUsage 제거

## 업데이트 / 수정

`main.swift`를 수정한 뒤 다시 빌드하면 실행 중인 위젯을 종료하고 새 버전을 설치합니다.

```bash
./build.sh && open ~/Applications/ClaudeUsage.app
```

## 작동 방식

1. Claude Code CLI가 저장해 둔 로그인 정보를 macOS 키체인(`Claude Code-credentials`)에서 읽습니다.
2. `https://api.anthropic.com/api/oauth/usage`에서 사용률을 가져옵니다. (Claude Code의 `/usage` 명령이 사용하는 것과 같은 정보)
3. 토큰이 만료되면 갱신해서 키체인에 다시 저장합니다. (Claude Code CLI와 같은 방식)

토큰은 내 맥의 키체인과 Anthropic 서버 사이에서만 오가며, 다른 곳으로 전송되지 않습니다.

## 주의

- **비공식 도구입니다.** Anthropic이 공식 제공하는 기능이 아니며, 사용하는 API 주소는 공개 문서화되지 않은 것이라 언제든 바뀌거나 막힐 수 있습니다.
- 위젯에 "로그인 필요"가 뜨면 터미널에서 `claude`를 한 번 실행하거나 `claude auth login`으로 다시 로그인하세요.

## 문제 해결

| 증상 | 해결 |
|---|---|
| `You have not agreed to the Xcode license` | `build.sh`가 자동으로 Command Line Tools를 사용합니다. 그래도 실패하면 `xcode-select --install` |
| 위젯에 "로그인 필요" | `claude auth login` |
| 위젯이 안 보임 | `open ~/Applications/ClaudeUsage.app` 다시 실행, 모니터 구석 확인 |
| 위치 초기화 | `defaults delete local.claude-usage-widget` 후 재실행 |

## 라이선스

[MIT](LICENSE)
