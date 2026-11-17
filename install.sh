#!/bin/bash
# install.sh - Carbon 자문 키트를 워크스페이스에 설치하거나 제거한다.
#
#   ./install.sh                      현재 폴더에 설치
#   ./install.sh --workspace <폴더>   지정한 워크스페이스에 설치
#   ./install.sh --uninstall [--workspace <폴더>]   제거
#   ./install.sh --global-hooks [--workspace <폴더>]
#        훅 등록만 전역 파일(~/.gemini/config/hooks.json)에 한다. 워크스페이스의 .agents/hooks.json 을
#        CLI 가 읽지 않는 경우의 대안이다. 기존 전역 훅은 백업 후 그대로 두고 "advisor-kit" 항목만 추가한다.
#        훅 스크립트는 이 워크스페이스의 세션에서만 동작하고 다른 폴더에서는 그냥 통과시킨다.
#
# 설치 위치 (모두 워크스페이스 안, 전역 설정은 건드리지 않는다)
#   .agents/agents/carbon-advisor/agent.md   자문 서브에이전트
#   .agents/hooks.json                       훅 등록 (기존 파일이 있으면 백업 후 "advisor-kit" 항목만 추가)
#   .agents/advisor-kit/                     훅 스크립트, 설정, 상태줄 스크립트, state/
set -eu

SRC="$(cd "$(dirname "$0")" && pwd)"
WS="$PWD"; MODE="install"; GLOBAL=0
GLOBAL_HOOKS="${ADVISOR_GLOBAL_HOOKS:-$HOME/.gemini/config/hooks.json}"
while [ $# -gt 0 ]; do
  case "$1" in
    --workspace|-w) WS="${2:?--workspace 뒤에 폴더가 필요합니다}"; shift 2 ;;
    --uninstall) MODE="uninstall"; shift ;;
    --global-hooks) GLOBAL=1; shift ;;
    -h|--help) sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) WS="$1"; shift ;;
  esac
done
[ -d "$WS" ] || { echo "오류: 폴더가 없습니다: $WS" >&2; exit 1; }
WS="$(cd "$WS" && pwd)"
command -v jq >/dev/null 2>&1 || { echo "오류: jq 가 필요합니다 (macOS 15 이상은 기본 포함, 아니면 brew install jq)" >&2; exit 1; }

AG="$WS/.agents"; KITDIR="$AG/advisor-kit"; HOOKS="$AG/hooks.json"; AGENT_DIR="$AG/agents/carbon-advisor"
TS="$(date +%Y%m%d-%H%M%S)"

remove_entry() { # <hooks.json 경로> : 이 워크스페이스의 키트를 가리키는 advisor-kit 항목만 지운다
  local f="$1" rest
  [ -f "$f" ] || return 0
  jq -e --arg k "$KITDIR/" '(.["advisor-kit"] // null) != null and (.["advisor-kit"] | tostring | contains($k))' "$f" >/dev/null 2>&1 || return 0
  cp "$f" "$f.bak.$TS"
  rest="$(jq 'del(.["advisor-kit"])' "$f")"
  if [ "$(printf '%s' "$rest" | jq 'length')" = "0" ]; then rm -f "$f"; echo "삭제: $f (다른 훅 없음, 백업: $f.bak.$TS)"
  else printf '%s\n' "$rest" > "$f"; echo "advisor-kit 항목 제거: $f (백업: $f.bak.$TS)"; fi
}

if [ "$MODE" = "uninstall" ]; then
  remove_entry "$HOOKS"
  remove_entry "$GLOBAL_HOOKS"
  rm -rf "$KITDIR" "$AGENT_DIR"
  rmdir "$AG/agents" 2>/dev/null || true
  rmdir "$AG" 2>/dev/null || true
  echo "제거 완료: $WS"
  echo "상태줄을 설정했다면 agy 안에서 /statusline delete 를 실행하세요."
  exit 0
fi

mkdir -p "$KITDIR/state" "$AGENT_DIR"
cp "$SRC/hooks/advisor-hook.sh" "$KITDIR/advisor-hook.sh"
cp "$SRC/statusline/statusline.sh" "$KITDIR/statusline.sh"
chmod +x "$KITDIR/advisor-hook.sh" "$KITDIR/statusline.sh"
if [ -f "$KITDIR/advisor.conf" ]; then echo "설정 유지: $KITDIR/advisor.conf (기존 파일을 덮어쓰지 않음)"
else cp "$SRC/hooks/advisor.conf" "$KITDIR/advisor.conf"; fi
# 상태 폴더에는 대화 기록 사본이 들어가므로 git 에 올라가지 않게 한다.
printf '*\n' > "$KITDIR/state/.gitignore"

if [ -f "$AGENT_DIR/agent.md" ] && ! cmp -s "$SRC/agents/carbon-advisor/agent.md" "$AGENT_DIR/agent.md"; then
  cp "$AGENT_DIR/agent.md" "$AGENT_DIR/agent.md.bak.$TS"; echo "기존 agent.md 백업: agent.md.bak.$TS"
fi
cp "$SRC/agents/carbon-advisor/agent.md" "$AGENT_DIR/agent.md"

# 훅 명령은 절대 경로로 등록한다(훅 실행 시 작업 폴더를 가정하지 않기 위해).
QHOOK="'$(printf '%s' "$KITDIR/advisor-hook.sh" | sed "s/'/'\\\\''/g")'"
NEW="$(jq --arg h "$QHOOK" 'walk(if type=="string" then (split("__HOOK__") | join($h)) else . end)' "$SRC/hooks/hooks.json")"
if [ "$GLOBAL" = "1" ]; then
  remove_entry "$HOOKS"            # 두 곳에 등록되면 훅이 두 번 실행되므로 워크스페이스 쪽은 지운다
  HOOKS="$GLOBAL_HOOKS"; mkdir -p "$(dirname "$HOOKS")"
else
  remove_entry "$GLOBAL_HOOKS"
fi
if [ -f "$HOOKS" ]; then
  jq -e 'type=="object"' "$HOOKS" >/dev/null 2>&1 || { echo "오류: 기존 $HOOKS 가 올바른 JSON 객체가 아닙니다. 직접 확인해 주세요." >&2; exit 1; }
  cp "$HOOKS" "$HOOKS.bak.$TS"
  printf '%s\n' "$NEW" | jq -s '.[0] + .[1]' "$HOOKS" - > "$HOOKS.tmp.$$" && mv "$HOOKS.tmp.$$" "$HOOKS"
  echo "advisor-kit 항목 추가: $HOOKS (백업: $HOOKS.bak.$TS)"
else
  printf '%s\n' "$NEW" > "$HOOKS"
fi
jq -e '.["advisor-kit"].Stop[0].command' "$HOOKS" >/dev/null

cat <<MSG

설치 완료: $WS
  자문 에이전트   .agents/agents/carbon-advisor/agent.md
  훅 등록         $HOOKS  (항목 이름: advisor-kit)
  훅/설정         .agents/advisor-kit/advisor-hook.sh, advisor.conf
  상태/이벤트     .agents/advisor-kit/state/  (git 제외)

다음 단계
  1. 이 폴더에서 agy 를 새로 시작합니다. (리드 모델이 Argon 일 때만 트리거가 동작합니다. advisor.conf 참고)
       agy --model gemini-4-argon-high
  2. 상태줄(선택): agy 안에서
       /statusline $KITDIR/statusline.sh
  3. 대시보드(선택): 다른 터미널에서
       node ./src/cli.ts --file .agents/advisor-kit/state/events.jsonl --follow
  4. Decision 1 사용(선택): 키를 파일에 저장합니다. 없으면 규칙만으로 동작합니다.
       mkdir -p ~/.config/advisor-kit && printf '%s' '<키>' > ~/.config/advisor-kit/decisions.key && chmod 600 ~/.config/advisor-kit/decisions.key
  5. 동작 확인: .agents/advisor-kit/state/hook.log 에 이벤트마다 한 줄씩 남습니다.
     아무 줄도 생기지 않으면 CLI 가 워크스페이스 훅을 읽지 않는 것이니
       $SRC/install.sh --global-hooks --workspace "$WS"
     로 전역 파일에 등록하세요. (~/.gemini/antigravity-cli/cli.log 의 "loaded N named hooks" 줄로도 확인할 수 있습니다.)
MSG
