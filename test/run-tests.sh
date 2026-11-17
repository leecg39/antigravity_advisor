#!/bin/bash
# run-tests.sh - 키트를 임시 워크스페이스에 설치하고, 문서 예시 형태의 입력을 훅에 넣어 출력을 확인한다.
# agy 를 실행하지 않으므로 할당량을 쓰지 않는다. Decisions API 는 로컬 가짜 서버로 대신한다.
#   ./test/run-tests.sh
set -u
SRC="$(cd "$(dirname "$0")/.." && pwd)"
export ADVISOR_GLOBAL_HOOKS="/nonexistent/advisor-kit-test/hooks.json"   # 실제 전역 훅 파일은 읽지도 않는다
TMP="$(mktemp -d)"; WS="$TMP/ws"; mkdir -p "$WS" "$TMP/home"
trap '{ [ -n "${MOCK_PID:-}" ] && kill "$MOCK_PID" && wait "$MOCK_PID"; } 2>/dev/null; rm -rf "$TMP"' EXIT

pass=0; fail=0
check() { if [ "$2" = "$3" ]; then pass=$((pass + 1)); echo "  ok   $1"; else fail=$((fail + 1)); echo "  FAIL $1"; echo "       got:  [$2]"; echo "       want: [$3]"; fi; }
has() { case "$2" in *"$3"*) pass=$((pass + 1)); echo "  ok   $1" ;; *) fail=$((fail + 1)); echo "  FAIL $1"; echo "       [$2] 에 [$3] 없음" ;; esac; }

echo "== 설치"
"$SRC/install.sh" --workspace "$WS" >/dev/null
HOOK="$WS/.agents/advisor-kit/advisor-hook.sh"; SD="$WS/.agents/advisor-kit/state"
check "hooks.json 유효" "$(jq -r '.["advisor-kit"] | keys | join(",")' "$WS/.agents/hooks.json")" "PostToolUse,PreInvocation,PreToolUse,SessionStart,Stop"
has "훅 명령이 절대 경로" "$(jq -r '.["advisor-kit"].Stop[0].command' "$WS/.agents/hooks.json")" "$WS/.agents/advisor-kit/advisor-hook.sh' Stop"
check "PreToolUse 는 matcher 구조" "$(jq -r '.["advisor-kit"].PreToolUse[0].hooks[0].type' "$WS/.agents/hooks.json")" "command"
check "agent.md 설치" "$(sed -n '2p' "$WS/.agents/agents/carbon-advisor/agent.md")" "name: carbon-advisor"
check "state 는 git 제외" "$(cat "$SD/.gitignore")" "*"

# 공통 입력
export HOME="$TMP/home"
export ADVISOR_DECISIONS_KEY_FILE="$TMP/nokey"; unset ADVISOR_DECISIONS_API_KEY
CONV="ec33ebf9-0cba-4100-8142-c61503f6c587"; MODEL="gemini-4-argon-high"; USERIN="인증 미들웨어를 리팩터링해줘"
TP="$TMP/transcript.jsonl"; printf '%s\n' '{"step_index":0,"type":"USER_INPUT","content":"hi"}' > "$TP"
base() { jq -cn --arg c "$CONV" --arg ws "$WS" --arg m "$MODEL" --arg t "$TP" --arg u "$USERIN" \
  '{conversationId:$c,workspacePaths:[$ws],transcriptPath:$t,artifactDirectoryPath:"/tmp/a",modelName:$m,lastUserInput:$u}'; }
hook() { printf '%s' "$2" | /bin/bash "$HOOK" "$1"; }
pre_write() { base | jq -c --arg f "$1" '. + {toolCall:{name:"replace_file_content",args:{TargetFile:$f,Description:"auth 미들웨어 수정"}},stepIdx:3}'; }
post() { base | jq -c --arg n "$1" --argjson a "$2" --arg e "$3" '. + {toolCall:{name:$n,args:$a},stepIdx:5,error:$e}'; }
stop() { base | jq -c --arg r "$1" --argjson i "$2" '. + {executionNum:1,terminationReason:$r,error:"",fullyIdle:$i}'; }
st() { jq -r "$1" "$SD/$CONV.json"; }

echo "== A. 규칙만으로 동작 (Decision 키 없음)"
OUT="$(hook SessionStart "$(base)")"
has "SessionStart: 자문 사용법 주입" "$(printf '%s' "$OUT" | jq -r '.injectSteps[0].systemMessage.systemMessage')" "carbon-advisor"
check "SessionStart: 이벤트 첫 줄은 reset" "$(head -1 "$SD/events.jsonl")" '{"type":"reset"}'
check "SessionStart: 예시 숫자를 실제 값으로 덮어씀" "$(sed -n '3,5p' "$SD/events.jsonl" | jq -rs '[.[0].calls, .[0].tokens, .[1].forks, .[2].max] | map(tostring) | join(",")')" "0,-,0,0"
check "SessionStart: session 이벤트에 모델" "$(sed -n '2p' "$SD/events.jsonl" | jq -r '.model + "/" + .effort')" "gemini-4-argon-high/high"

OUT="$(hook PreToolUse "$(pre_write "$WS/src/auth.ts")")"
check "계획 확정 전: 첫 수정은 한 번 막음" "$(printf '%s' "$OUT" | jq -r '.decision')" "deny"
has "계획 확정 전: 안내에 트리거 이름" "$(printf '%s' "$OUT" | jq -r '.reason')" "계획 확정 전"
has "계획 확정 전: 사본 경로는 워크스페이스 상대 경로" "$(printf '%s' "$OUT" | jq -r '.reason')" "(.agents/advisor-kit/state/transcript-tail-ec33ebf9.jsonl)"
check "계획 확정 전: 사본 파일 생성" "$(test -s "$SD/transcript-tail-ec33ebf9.jsonl" && echo y)" "y"
check "계획 확정 전: 두 번째 시도는 통과" "$(hook PreToolUse "$(pre_write "$WS/src/auth.ts")" | jq -r '.decision')" "allow"

M2="$MODEL"; MODEL="gemini-4-hydrogen-high"; C2="$CONV"; CONV="sub-1111"
check "하위 에이전트 세션(Hydrogen)은 건드리지 않음" "$(hook PreToolUse "$(pre_write "$WS/src/x.ts")" | jq -c .)" '{"decision":"allow"}'
check "하위 에이전트 세션은 상태 파일 없음" "$(test -e "$SD/sub-1111.json" && echo y || echo n)" "n"
MODEL="$M2"; CONV="$C2"

hook PostToolUse "$(post replace_file_content "$(jq -cn --arg f "$WS/src/auth.ts" '{TargetFile:$f}')" "")" >/dev/null
OUT="$(hook PostToolUse "$(post write_to_file "$(jq -cn --arg f "$WS/src/session.ts" '{TargetFile:$f}')" "")")"
check "PostToolUse 출력은 빈 객체" "$OUT" "{}"
check "수정 횟수 집계" "$(st '.reqEdits')" "2"
check "수정 파일 목록" "$(st '.files | map(split("/")|last) | join(",")')" "auth.ts,session.ts"
hook PostToolUse "$(post write_to_file '{"TargetFile":"/tmp/plan.md","IsArtifact":true}' "")" >/dev/null
check "아티팩트 작성은 수정으로 세지 않음" "$(st '.reqEdits')" "2"

CMD='{"CommandLine":"npm test","Cwd":"/workspace/project","WaitMsBeforeAsync":5000}'
hook PostToolUse "$(post run_command "$CMD" "exit status 1")" >/dev/null
check "오류 1회: 아직 안내 없음" "$(hook PreInvocation "$(base | jq -c '. + {invocationNum:3,initialNumSteps:10}')")" "{}"
hook PostToolUse "$(post run_command "$CMD" "exit status 1")" >/dev/null
check "오류 2회: 안내 대기 상태" "$(st '.pending')" "same_error"
OUT="$(hook PreInvocation "$(base | jq -c '. + {invocationNum:4,initialNumSteps:12}')")"
has "같은 오류 2회: 시스템 메시지 주입" "$(printf '%s' "$OUT" | jq -r '.injectSteps[0].systemMessage.systemMessage')" "같은 오류 2회] run_command"
has "같은 오류 2회: 오류와 명령 포함" "$(printf '%s' "$OUT" | jq -r '.injectSteps[0].systemMessage.systemMessage')" "오류: exit status 1 / 대상: npm test"
check "같은 오류 2회: 한 번만 주입" "$(hook PreInvocation "$(base | jq -c '. + {invocationNum:5,initialNumSteps:13}')")" "{}"
hook PostToolUse "$(post run_command '{"CommandLine":"npm run lint"}' "exit status 2")" >/dev/null
check "다른 오류는 카운터를 새로 시작" "$(st '.errCount')" "1"
hook PostToolUse "$(post run_command '{"CommandLine":"npm run lint"}' "")" >/dev/null
check "같은 명령이 성공하면 카운터 초기화" "$(st '.errCount')" "0"

OUT="$(hook Stop "$(stop model_stop true)")"
check "완료 전: 종료를 막고 계속" "$(printf '%s' "$OUT" | jq -r '.decision')" "continue"
has "완료 전: 수정 파일 안내" "$(printf '%s' "$OUT" | jq -r '.reason')" "2회 수정했습니다(auth.ts, session.ts)"
check "완료 전: 같은 상태에서 다시 묻지 않음" "$(hook Stop "$(stop model_stop true)" | jq -r '.decision')" "allow"

# 실제 기록에서 본 형태: TypeName 이 따옴표째 들어온다.
hook PostToolUse "$(post invoke_subagent '{"Prompt":"\"변경 검토\"","Role":"\"Reviewer\"","TypeName":"\"carbon-advisor\""}' "")" >/dev/null
check "자문 호출 감지 (따옴표 형태)" "$(jq -r '[.calls,.active,.trigger]|join(",")' "$SD/advisor.json")" "1,true,2"
check "자문 이벤트: 자문 중 + 트리거 2" "$(grep '"type":"advisor"' "$SD/events.jsonl" | tail -1 | jq -r '.state + "/" + (.trigger|tostring) + "/" + (.calls|tostring)')" "자문 중/2/1"
hook PostToolUse "$(post invoke_subagent '{"Subagents":[{"Prompt":"검토","Role":"Reviewer","TypeName":"carbon-advisor"}]}' "")" >/dev/null
check "자문 호출 감지 (문서의 Subagents 배열 형태)" "$(jq -r '.calls' "$SD/advisor.json")" "2"
hook PostToolUse "$(post invoke_subagent '{"Prompt":"\"carbon-advisor 는 부르지 말고 검색만\"","Role":"\"Searcher\"","TypeName":"\"research\""}' "")" >/dev/null
check "프롬프트에 이름만 언급된 호출은 자문이 아님" "$(jq -r '.calls' "$SD/advisor.json")" "2"
has "다른 하위 에이전트는 위임 로그" "$(tail -1 "$SD/events.jsonl" | jq -r '.agent + ": " + .message')" "Hydrogen: 하위 에이전트 위임: Searcher"

printf '%s\n' '{"step_index":9,"type":"GENERIC","content":"판정: 수정 후 진행\n근거:\n- src/auth.ts:42\nCARBON_ADVICE: 세션 토큰 검증 경로는 이번 변경에서 제외하세요"}' >> "$TP"
hook PreInvocation "$(base | jq -c '. + {invocationNum:6,initialNumSteps:20}')" >/dev/null
check "조언 줄 수집" "$(jq -r '.lastAdvice' "$SD/advisor.json")" "세션 토큰 검증 경로는 이번 변경에서 제외하세요"
check "조언 이벤트는 트리거 번호와 함께" "$(grep '"advice"' "$SD/events.jsonl" | tail -1 | jq -r '(.trigger|tostring) + "/" + .state')" "2/대기 중"
hook PreInvocation "$(base | jq -c '. + {invocationNum:7,initialNumSteps:21}')" >/dev/null
check "같은 조언은 한 번만 내보냄" "$(grep '"advice"' "$SD/events.jsonl" | grep -vc '아직 자문 없음')" "1"

check "자문 뒤 종료는 통과" "$(hook Stop "$(stop model_stop true)" | jq -r '.decision')" "allow"
check "종료 시 단계 이벤트: 완료" "$(grep '"type":"phase"' "$SD/events.jsonl" | tail -1 | jq -r '.phase')" "완료"

USERIN="두 번째 요청: 로그 포맷 정리"
hook PostToolUse "$(post replace_file_content "$(jq -cn --arg f "$WS/src/log.ts" '{TargetFile:$f}')" "")" >/dev/null
check "새 요청이면 카운터 초기화" "$(st '.reqEdits')" "1"
check "백그라운드 작업이 남아 있으면 통과" "$(hook Stop "$(stop model_stop false)" | jq -r '.decision')" "allow"
check "오류로 인한 종료는 통과" "$(hook Stop "$(stop error true)" | jq -r '.decision')" "allow"
check "정상 종료는 검토 요청" "$(hook Stop "$(stop model_stop true)" | jq -r '.decision')" "continue"

WS_SAVE="$WS"; CONV_SAVE="$CONV"; WS="$TMP/other-project"; CONV="other-0001"
check "다른 워크스페이스의 세션은 통과" "$(hook PreToolUse "$(pre_write "$TMP/other-project/a.ts")" | jq -c .)" '{"decision":"allow"}'
check "다른 워크스페이스는 상태를 남기지 않음" "$(test -e "$SD/other-0001.json" && echo y || echo n)" "n"
WS="$WS_SAVE"; CONV="$CONV_SAVE"

echo "== B. 잘못된 입력에도 유효한 JSON"
check "PreToolUse 에 깨진 입력" "$(printf 'not json' | /bin/bash "$HOOK" PreToolUse)" '{"decision":"allow"}'
check "PostToolUse 에 빈 입력" "$(printf '' | /bin/bash "$HOOK" PostToolUse)" '{}'
check "Stop 에 깨진 입력" "$(printf '{{' | /bin/bash "$HOOK" Stop)" '{"decision":"allow"}'
check "모르는 이벤트" "$(printf '{}' | /bin/bash "$HOOK" Whatever)" '{}'
check "잠금이 남지 않음" "$(test -e "$SD/.lock" && echo y || echo n)" "n"

echo "== C. ~ 로 시작하는 기록 경로"
printf '%s\n' '{"step_index":0,"type":"USER_INPUT","content":"x"}' > "$HOME/t.jsonl"
CONV="tilde-0001"; USERIN="물결표 경로"; TP_SAVE="$TP"; TP="~/t.jsonl"
OUT="$(hook PreToolUse "$(pre_write "$WS/src/a.ts")")"
check "~/ 경로를 홈으로 풀어 사본 생성" "$(test -s "$SD/transcript-tail-tilde-00.jsonl" && echo y || echo n)" "y"
TP="$TP_SAVE"

echo "== D. Decision 1 (가짜 서버)"
if command -v node >/dev/null 2>&1 && command -v curl >/dev/null 2>&1; then
  CTL="$TMP/noul"; echo "0.05" > "$CTL"
  node "$SRC/test/mock-decisions.mjs" "$CTL" > "$TMP/port" 2>"$TMP/mock.err" & MOCK_PID=$!
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do [ -s "$TMP/port" ] && break; sleep 0.1; done
  PORT="$(head -1 "$TMP/port")"
  export ADVISOR_DECISIONS_URL="http://127.0.0.1:$PORT/v1beta/decisions"
  export ADVISOR_DECISIONS_API_KEY="test-key-123"

  CONV="dec-0001"; USERIN="README 오타 수정"
  check "확신 있는 불필요(예 0.05): 막지 않음" "$(hook PreToolUse "$(pre_write "$WS/README.md")" | jq -r '.decision')" "allow"
  check "decision 이벤트의 p 는 확신도" "$(grep '"type":"decision"' "$SD/events.jsonl" | tail -1 | jq -r '.routes[0] | .name + "=" + (.p|tostring) + " (" + .targetHint + ")"')" "수정 전 검토=0.95 (예 확률 0.05)"
  check "sharp 집계" "$(st '[.forks,.sharp,.split]|join(",")')" "1,1,0"
  check "판정 기록 파일" "$(tail -1 "$SD/decisions.jsonl" | jq -r '.status')" "sharp_no"
  check "요청 형식 (엔드포인트, 모델, noul, criteria, 키 헤더)" "$(tail -1 "$CTL.log" | jq -r '[.method,.url,.model,.qtype,(.hasCriteria|tostring),.key]|join(" ")')" "POST /v1beta/decisions gemini-decision-1 noul true test-key-123"

  CONV="dec-0002"; USERIN="결제 트랜잭션 로직 변경"; echo "0.93" > "$CTL"
  OUT="$(hook PreToolUse "$(pre_write "$WS/src/pay.ts")")"
  check "확신 있는 필요(예 0.93): 막음" "$(printf '%s' "$OUT" | jq -r '.decision')" "deny"
  has "안내에 Decision 판정과 확신도" "$(printf '%s' "$OUT" | jq -r '.reason')" "Decision 1이 수정 전 검토가 필요하다고 판정했습니다(확신도 0.93)"

  CONV="dec-0003"; USERIN="유틸 함수 정리"; echo "0.55" > "$CTL"
  OUT="$(hook PreToolUse "$(pre_write "$WS/src/util.ts")")"
  has "판정 갈림(예 0.55): 리드에게 판단을 넘김" "$(printf '%s' "$OUT" | jq -r '.reason')" "판정이 갈렸습니다(확신도 0.55)"
  check "split 집계" "$(st '[.forks,.sharp,.split]|join(",")')" "1,0,1"

  hook PostToolUse "$(post replace_file_content "$(jq -cn --arg f "$WS/src/util.ts" '{TargetFile:$f}')" "")" >/dev/null
  echo "0.04" > "$CTL"
  check "완료 전: 확신 있는 불필요면 그냥 종료" "$(hook Stop "$(stop model_stop true)" | jq -r '.decision')" "allow"
  hook PostToolUse "$(post replace_file_content "$(jq -cn --arg f "$WS/src/util2.ts" '{TargetFile:$f}')" "")" >/dev/null
  echo "0.90" > "$CTL"
  check "완료 전: 확신 있는 필요면 검토 요청" "$(hook Stop "$(stop model_stop true)" | jq -r '.decision')" "continue"
  check "화면용 판정 행이 두 개" "$(grep '"type":"decision"' "$SD/events.jsonl" | tail -1 | jq -r '[.routes[].name]|join(",")')" "수정 전 검토,완료 전 검토"

  kill "$MOCK_PID" 2>/dev/null; wait "$MOCK_PID" 2>/dev/null; MOCK_PID=""
  CONV="dec-0004"; USERIN="서버가 죽었을 때"
  T0="$(date +%s)"; OUT="$(hook PreToolUse "$(pre_write "$WS/src/z.ts")")"; T1="$(date +%s)"
  check "API 실패 시 규칙으로 되돌아감(막고 안내)" "$(printf '%s' "$OUT" | jq -r '.decision')" "deny"
  check "API 실패가 훅을 오래 붙잡지 않음(5초 이내)" "$([ $((T1 - T0)) -le 5 ] && echo y || echo n)" "y"
  unset ADVISOR_DECISIONS_URL ADVISOR_DECISIONS_API_KEY
else
  echo "  (node 또는 curl 이 없어 건너뜀)"
fi

echo "== E. 상태줄"
SL="$WS/.agents/advisor-kit/statusline.sh"
CONV="ec33ebf9-0cba-4100-8142-c61503f6c587"
PAY="$(jq -cn --arg ws "$WS" --arg c "$CONV" '{cwd:$ws,conversation_id:$c,model:{id:"Gemini 4 Argon (High)",display_name:"Gemini 4 Argon (High)",effort:"high"},
  workspace:{current_dir:$ws,project_dir:$ws},context_window:{used_percentage:14.24},agent_state:"tool_use",terminal_width:150,
  cost:{total_usd:0.4213,subagent_usd:0.1},quota:{"gemini-weekly":{remaining_fraction:0.9378}},tool_confirmation_pending:true,task_count:1,
  subagents:[{name:"search",role:"repo search",status:"running"},{name:"grep",role:"call sites",status:"completed"},{name:"audit",role:"diff audit",status:"running"},{name:"carbon-advisor",role:"advisor",status:"completed"}]}')"
OUT="$(printf '%s' "$PAY" | NO_COLOR=1 /bin/bash "$SL")"
check "넓은 화면은 한 줄" "$(printf '%s\n' "$OUT" | wc -l | tr -d ' ')" "1"
has "상태, 모델, 컨텍스트" "$OUT" "도구 실행 | Gemini 4 Argon (High) | ctx 14%"
has "비용과 승인 대기" "$OUT" "비용 \$0.42 (하위 \$0.10) | 승인 대기"
has "하위 에이전트는 자문을 뺀 실제 수" "$OUT" "하위 에이전트 2 실행 / 3"
has "자문 횟수" "$OUT" "자문 2회"
check "swarm 이벤트: 실행 중 2, 전체 3" "$(grep '"type":"swarm"' "$SD/events.jsonl" | tail -1 | jq -r '[.active,.max,(.cards|length)]|join(",")')" "2,3,3"
check "swarm 카드에 지어낸 진행률 없음(0 또는 100)" "$(grep '"type":"swarm"' "$SD/events.jsonl" | tail -1 | jq -r '[.cards[].progress]|unique|join(",")')" "0,100"
printf '%s' "$PAY" | NO_COLOR=1 /bin/bash "$SL" >/dev/null
check "같은 상태는 다시 내보내지 않음" "$(grep '"type":"swarm"' "$SD/events.jsonl" | grep -vc '"max":0')" "1"
check "좁은 화면(60칸)은 두 줄" "$(printf '%s' "$PAY" | jq -c '.terminal_width=60' | NO_COLOR=1 /bin/bash "$SL" | wc -l | tr -d ' ')" "2"
DOC='{"cwd":"/home/user/my-project","conversation_id":"12345678","model":{"id":"Gemini 4 Argon (Medium)","display_name":"Gemini 4 Argon (Medium)","effort":"medium"},"workspace":{"current_dir":"/home/user/my-project","project_dir":"/home/user/my-project"},"context_window":{"used_percentage":14.24},"agent_state":"idle","terminal_width":111,"cost":{"total_usd":0.4213,"subagent_usd":0,"estimated":false}}'
check "문서 예시 입력(키트 없는 폴더)" "$(printf '%s' "$DOC" | NO_COLOR=1 /bin/bash "$SL")" "대기 | Gemini 4 Argon (Medium) | ctx 14% | 비용 \$0.42"
check "깨진 입력에도 종료 코드 0" "$(printf 'xx' | NO_COLOR=1 /bin/bash "$SL" >/dev/null 2>&1; echo $?)" "0"

echo "== F. 기존 hooks.json 과 병합, 제거"
WS2="$TMP/ws2"; mkdir -p "$WS2/.agents"
printf '%s\n' '{"other-hook":{"Stop":[{"type":"command","command":"true","timeout":5}]}}' > "$WS2/.agents/hooks.json"
"$SRC/install.sh" --workspace "$WS2" >/dev/null
check "기존 훅 유지 + 키트 추가" "$(jq -r 'keys|join(",")' "$WS2/.agents/hooks.json")" "advisor-kit,other-hook"
check "백업 파일 생성" "$(ls "$WS2/.agents" | grep -c 'hooks.json.bak')" "1"
"$SRC/install.sh" --uninstall --workspace "$WS2" >/dev/null
check "제거 후 기존 훅만 남음" "$(jq -r 'keys|join(",")' "$WS2/.agents/hooks.json")" "other-hook"
check "제거 후 키트 폴더 없음" "$(test -e "$WS2/.agents/advisor-kit" && echo y || echo n)" "n"
WS3="$TMP/w s'3"; mkdir -p "$WS3"
"$SRC/install.sh" --workspace "$WS3" >/dev/null
check "공백과 따옴표가 있는 경로에서도 훅 실행" "$(printf '{}' | sh -c "$(jq -r '.["advisor-kit"].Stop[0].command' "$WS3/.agents/hooks.json")")" '{"decision":"allow"}'

WS4="$TMP/ws4"; mkdir -p "$WS4" "$TMP/g"
export ADVISOR_GLOBAL_HOOKS="$TMP/g/hooks.json"
printf '%s\n' '{"orca-status":{"Stop":[{"type":"command","command":"true","timeout":10}]}}' > "$ADVISOR_GLOBAL_HOOKS"
"$SRC/install.sh" --global-hooks --workspace "$WS4" >/dev/null
check "전역 등록: 기존 전역 훅 유지 + 키트 추가" "$(jq -r 'keys|join(",")' "$ADVISOR_GLOBAL_HOOKS")" "advisor-kit,orca-status"
check "전역 등록: 워크스페이스 hooks.json 은 만들지 않음" "$(test -e "$WS4/.agents/hooks.json" && echo y || echo n)" "n"
"$SRC/install.sh" --workspace "$WS4" >/dev/null
check "워크스페이스 등록으로 바꾸면 전역 항목 제거(이중 실행 방지)" "$(jq -r 'keys|join(",")' "$ADVISOR_GLOBAL_HOOKS")" "orca-status"
"$SRC/install.sh" --global-hooks --workspace "$WS4" >/dev/null
"$SRC/install.sh" --uninstall --workspace "$WS4" >/dev/null
check "제거: 전역 파일에서 키트 항목만 삭제" "$(jq -r 'keys|join(",")' "$ADVISOR_GLOBAL_HOOKS")" "orca-status"
export ADVISOR_GLOBAL_HOOKS="/nonexistent/advisor-kit-test/hooks.json"

echo
echo "결과: 통과 $pass, 실패 $fail"
[ "$fail" -eq 0 ]
