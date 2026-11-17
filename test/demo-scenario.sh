#!/bin/bash
# demo-scenario.sh [출력 파일]
# agy 없이 훅과 상태줄 스크립트에 한 세션 분량의 입력을 순서대로 넣어 화면용 이벤트 파일을 만든다.
# 대시보드에서 미리 보기:  node ./src/cli.ts --file <출력 파일> --replay-ms 400
set -u
SRC="$(cd "$(dirname "$0")/.." && pwd)"
export ADVISOR_GLOBAL_HOOKS="/nonexistent/advisor-kit-test/hooks.json"   # 실제 전역 훅 파일은 읽지도 않는다
OUTFILE="${1:-$PWD/advisor-demo-events.jsonl}"
TMP="$(mktemp -d)"; WS="$TMP/app"; mkdir -p "$WS" "$TMP/home"
trap '{ [ -n "${MOCK_PID:-}" ] && kill "$MOCK_PID" && wait "$MOCK_PID"; } 2>/dev/null; rm -rf "$TMP"' EXIT
"$SRC/install.sh" --workspace "$WS" >/dev/null
HOOK="$WS/.agents/advisor-kit/advisor-hook.sh"; SL="$WS/.agents/advisor-kit/statusline.sh"; SD="$WS/.agents/advisor-kit/state"
export HOME="$TMP/home"; export ADVISOR_DECISIONS_KEY_FILE="$TMP/nokey"
CTL="$TMP/noul"; echo "0.93" > "$CTL"
if command -v node >/dev/null 2>&1; then
  node "$SRC/test/mock-decisions.mjs" "$CTL" > "$TMP/port" & MOCK_PID=$!
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do [ -s "$TMP/port" ] && break; sleep 0.1; done
  export ADVISOR_DECISIONS_URL="http://127.0.0.1:$(head -1 "$TMP/port")/v1beta/decisions"; export ADVISOR_DECISIONS_API_KEY="demo"
fi
CONV="7f3a9c21-demo"; MODEL="gemini-4-argon-high"; USERIN="API 스펙 변경에 맞춰 핸들러를 수정하고 테스트를 통과시켜줘"
TP="$TMP/transcript.jsonl"; : > "$TP"
base() { jq -cn --arg c "$CONV" --arg ws "$WS" --arg m "$MODEL" --arg t "$TP" --arg u "$USERIN" '{conversationId:$c,workspacePaths:[$ws],transcriptPath:$t,modelName:$m,lastUserInput:$u}'; }
hook() { printf '%s' "$2" | /bin/bash "$HOOK" "$1" >/dev/null; sleep "${STEP_DELAY:-0}"; }
tool() { base | jq -c --arg n "$1" --argjson a "$2" --arg e "${3:-}" '. + {toolCall:{name:$n,args:$a},error:$e}'; }
sub() { jq -cn --arg ws "$WS" --arg c "$CONV" --argjson s "$1" '{conversation_id:$c,workspace:{project_dir:$ws},agent_state:"working",model:{display_name:"Gemini 4 Argon (High)"},subagents:$s,terminal_width:150}' | NO_COLOR=1 /bin/bash "$SL" >/dev/null; }
advice() { printf '%s\n' "$(jq -cn --arg a "$1" '{type:"GENERIC",content:("판정: 수정 후 진행\nCARBON_ADVICE: " + $a)}')" >> "$TP"; }
EDIT() { tool replace_file_content "$(jq -cn --arg f "$WS/$1" '{TargetFile:$f,Description:"핸들러 수정"}')" "${2:-}"; }
ADV='{"Prompt":"\"계획 검토\"","Role":"\"Advisor\"","TypeName":"\"carbon-advisor\""}'
NPM='{"CommandLine":"npm test"}'

hook SessionStart "$(base)"
hook PostToolUse "$(tool invoke_subagent '{"Prompt":"\"저장소 구조 파악\"","Role":"\"search\"","TypeName":"\"research\""}')"
hook PostToolUse "$(tool invoke_subagent '{"Prompt":"\"호출 위치 찾기\"","Role":"\"grep\"","TypeName":"\"research\""}')"
sub '[{"name":"search","role":"저장소 구조 파악","status":"running"},{"name":"grep","role":"호출 위치 찾기","status":"running"}]'
hook PreToolUse "$(EDIT src/api/spec.ts)"                       # 계획 확정 전: Decision 0.93 -> 막고 안내
hook PostToolUse "$(tool invoke_subagent "$ADV")"
sub '[{"name":"search","role":"저장소 구조 파악","status":"completed"},{"name":"grep","role":"호출 위치 찾기","status":"completed"},{"name":"carbon-advisor","role":"advisor","status":"running"}]'
advice "인증과 DB 트랜잭션 호출은 이번 계획에서 제외하세요"
hook PreInvocation "$(base)"
hook PostToolUse "$(EDIT src/api/spec.ts)"
hook PostToolUse "$(EDIT src/api/handler.ts)"
hook PostToolUse "$(tool invoke_subagent '{"Prompt":"\"워크트리 차이 비교\"","Role":"\"audit\"","TypeName":"\"research\""}')"
sub '[{"name":"search","role":"저장소 구조 파악","status":"completed"},{"name":"grep","role":"호출 위치 찾기","status":"completed"},{"name":"audit","role":"워크트리 차이 비교","status":"running"}]'
hook PostToolUse "$(tool run_command "$NPM" "exit status 1")"
hook PostToolUse "$(tool run_command "$NPM" "exit status 1")"   # 같은 오류 2회
hook PreInvocation "$(base)"
hook PostToolUse "$(tool invoke_subagent "$ADV")"
advice "fixture 가 예전 스키마를 쓰고 있습니다. tests/fixtures/spec.json 을 먼저 고치세요"
hook PreInvocation "$(base)"
hook PostToolUse "$(EDIT tests/fixtures/spec.json)"
hook PostToolUse "$(tool run_command "$NPM")"
sub '[{"name":"search","role":"저장소 구조 파악","status":"completed"},{"name":"grep","role":"호출 위치 찾기","status":"completed"},{"name":"audit","role":"워크트리 차이 비교","status":"completed"}]'
echo "0.88" > "$CTL"
hook Stop "$(base | jq -c '. + {terminationReason:"model_stop",fullyIdle:true}')"   # 완료 전
hook PostToolUse "$(tool invoke_subagent "$ADV")"
advice "변경 범위와 테스트 통과를 확인했습니다. 그대로 마무리해도 됩니다"
hook PreInvocation "$(base)"
hook Stop "$(base | jq -c '. + {terminationReason:"model_stop",fullyIdle:true}')"
cp "$SD/events.jsonl" "$OUTFILE"
echo "$OUTFILE ($(wc -l < "$OUTFILE" | tr -d ' ') 줄)"
