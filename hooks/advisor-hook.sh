#!/bin/bash
# advisor-hook.sh <Event>
#
# Antigravity CLI 훅 디스패처 (Carbon 자문 키트)
#   규격: https://antigravity.google/docs/hooks  (stdin JSON -> stdout JSON)
#   이벤트: SessionStart | PreToolUse | PostToolUse | PreInvocation | Stop
#
# 원칙
#   1. 어떤 경우에도 유효한 JSON 한 개를 출력하고 0으로 종료한다(실패 시 통과).
#   2. 훅 안에서 자문 모델을 직접 돌리지 않는다. 리드에게 "자문을 호출하라"고 안내만 한다.
#      (훅 기본 제한 시간이 30초라서 자문을 훅 안에서 실행하면 시간 초과가 난다.)
#   3. 화면용 이벤트는 TUI의 JSONL 규격(session/phase/decision/advisor/log)으로 state/events.jsonl 에 쓴다.
#
# bash 3.2 (macOS 기본) + jq 로 동작한다.

EVENT="${1:-}"
KIT_DIR="$(cd "$(dirname "$0")" 2>/dev/null && pwd)"
# shellcheck disable=SC1091
[ -f "$KIT_DIR/advisor.conf" ] && . "$KIT_DIR/advisor.conf"

: "${ADVISOR_AGENT_NAME:=carbon-advisor}"
: "${ADVISOR_LEAD_MODEL_REGEX:=argon}"
: "${ADVISOR_PLAN_GATE:=auto}"            # auto | always | off
: "${ADVISOR_STOP_REVIEW:=auto}"          # auto | always | off
: "${ADVISOR_SAME_ERROR_THRESHOLD:=2}"
: "${ADVISOR_MAX_STOP_REVIEWS:=2}"
: "${ADVISOR_DECISION:=auto}"             # auto | off
: "${ADVISOR_CONF_THRESHOLD:=0.70}"
: "${ADVISOR_DECISION_MODEL:=gemini-decision-1}"
: "${ADVISOR_DECISIONS_URL:=https://generativelanguage.googleapis.com/v1beta/decisions}"
: "${ADVISOR_DECISION_TIMEOUT:=4}"
: "${ADVISOR_DECISIONS_KEY_FILE:=$HOME/.config/advisor-kit/decisions.key}"
: "${ADVISOR_TRANSCRIPT_TAIL_KB:=256}"
: "${ADVISOR_SESSION_BRIEF:=on}"          # on | off
: "${ADVISOR_STATE_DIR:=$KIT_DIR/state}"

STATE_DIR="$ADVISOR_STATE_DIR"
EVENTS="$STATE_DIR/events.jsonl"
AF="$STATE_DIR/advisor.json"
HOOK_LOG="$STATE_DIR/hook.log"
WRITE_TOOLS_RE='^(write_to_file|replace_file_content|multi_replace_file_content)$'

fallback() {
  case "$EVENT" in
    PreToolUse|Stop) printf '%s\n' '{"decision":"allow"}' ;;
    *) printf '%s\n' '{}' ;;
  esac
}

INPUT="$(cat 2>/dev/null)"
command -v jq >/dev/null 2>&1 || { fallback; exit 0; }
mkdir -p "$STATE_DIR" 2>/dev/null || { fallback; exit 0; }
if [ -f "$HOOK_LOG" ] && [ "$(wc -c < "$HOOK_LOG" 2>/dev/null || echo 0)" -gt 1048576 ]; then : > "$HOOK_LOG"; fi

# ---------- 공통 도우미 ----------
J() { printf '%s' "$INPUT" | jq -r "$1" 2>/dev/null; }
now() { date +%H:%M:%S; }
dbg() { printf '%s %s %s\n' "$(date +%FT%T)" "$EVENT" "$*" >> "$HOOK_LOG" 2>/dev/null; }
sha() {
  if command -v shasum >/dev/null 2>&1; then printf '%s' "$1" | shasum | cut -c1-16
  else printf '%s' "$1" | cksum | tr -d ' \t'
  fi
}
emit() { [ -n "$1" ] && printf '%s\n' "$1" >> "$EVENTS" 2>/dev/null; }
emit_log() { emit "$(jq -cn --arg t "$(now)" --arg a "$1" --arg c "$2" --arg m "$3" '{type:"log",time:$t,agent:$a,color:$c,message:$m}')"; }
emit_phase() { emit "$(jq -cn --arg p "$1" '{type:"phase",phase:$p}')"; }

# 입력에서 필요한 값을 jq 한 번으로 뽑는다(훅은 자주 실행되므로 프로세스 수를 줄인다).
{ read -r CONV; read -r MODEL; read -r WS; read -r TPATH; read -r TOOL; read -r ERR; read -r REQ_RAW; } <<EOF
$(printf '%s' "$INPUT" | jq -r 'def one: (. // "") | tostring | gsub("[\r\n]+"; " ");
  (.conversationId | one), (.modelName | one), (.workspacePaths[0]? | one), (.transcriptPath | one),
  (.toolCall.name? | one), (.error | one), ((.lastUserInput // "") | @json)' 2>/dev/null)
EOF
CONV="$(printf '%s' "${CONV:-}" | tr -cd 'A-Za-z0-9_-')"
[ -n "$CONV" ] || CONV="unknown"
case "${TPATH:-}" in "~/"*) TPATH="$HOME/${TPATH#\~/}" ;; esac
REQ_KEY="$(sha "${REQ_RAW:-}")"
SF="$STATE_DIR/$CONV.json"

STATE_DEFAULT='{"reqKey":"","reqEdits":0,"files":[],"gateAsked":false,"advisorThisReq":false,"editsAtAdvisor":-1,"stopReviews":0,"stopAskedAtEdits":-1,"errSig":"","errKey":"","errCount":0,"errTool":"","errDetail":"","pending":"","trigger":-1,"forks":0,"sharp":0,"split":0,"routes":{}}'
AF_DEFAULT='{"calls":0,"active":false,"trigger":-1,"lastAdvice":""}'

state_init() { { [ -s "$SF" ] && jq -e . "$SF" >/dev/null 2>&1; } || printf '%s\n' "$STATE_DEFAULT" > "$SF"; }
af_init() { { [ -s "$AF" ] && jq -e . "$AF" >/dev/null 2>&1; } || printf '%s\n' "$AF_DEFAULT" > "$AF"; }
st_get() { jq -r "$1" "$SF" 2>/dev/null; }
af_get() { jq -r "$1" "$AF" 2>/dev/null; }
st_set() { jq "$@" "$SF" > "$SF.tmp.$$" 2>>"$HOOK_LOG" && mv "$SF.tmp.$$" "$SF"; }
af_set() { jq "$@" "$AF" > "$AF.tmp.$$" 2>>"$HOOK_LOG" && mv "$AF.tmp.$$" "$AF"; }

# 병렬 도구 호출로 훅이 동시에 돌 수 있어서 상태 파일을 잠근다. 2초 넘게 잡힌 잠금은 버려진 것으로 본다.
LOCK="$STATE_DIR/.lock"
lock() {
  local i=0
  while ! mkdir "$LOCK" 2>/dev/null; do
    i=$((i + 1))
    if [ "$i" -gt 40 ]; then rm -rf "$LOCK" 2>/dev/null; mkdir "$LOCK" 2>/dev/null; break; fi
    sleep 0.05
  done
  printf '%s' "$$" > "$LOCK/pid" 2>/dev/null
}
unlock() { [ "$(cat "$LOCK/pid" 2>/dev/null)" = "$$" ] && rm -rf "$LOCK" 2>/dev/null; return 0; }

# invoke_subagent 가 자문 에이전트를 부르는 호출인지 확인한다.
# 실제 기록에서는 args.TypeName 에 따옴표째("\"research\"") 들어오고, 문서에는 args.Subagents[].TypeName 으로 나온다.
JQ_UNQ='def unq: . as $x | if type=="string" then (try fromjson catch $x) else . end;'
is_advisor_call() {
  printf '%s' "$INPUT" | jq -e --arg n "$ADVISOR_AGENT_NAME" "$JQ_UNQ"'
    (.toolCall.args // {}) as $a
    | [ ($a.TypeName | unq), (($a.Subagents | unq) | if type=="array" then .[] | (.TypeName | unq) else empty end) ]
    | map(select(type=="string")) | any(. == $n)' >/dev/null 2>&1
}
subagent_label() {
  printf '%s' "$INPUT" | jq -r "$JQ_UNQ"'
    (.toolCall.args // {}) as $a
    | [ ($a.Role | unq), (($a.Subagents | unq) | if type=="array" then (.[0].Role | unq) else empty end),
        ($a.TypeName | unq), (($a.Subagents | unq) | if type=="array" then (.[0].TypeName | unq) else empty end) ]
    | map(select(type=="string" and . != "")) | (.[0] // "subagent")' 2>/dev/null | cut -c1-80
}

# 이 키트가 설치된 워크스페이스의 세션인지 확인한다.
# (훅을 전역 hooks.json 에 등록한 경우 다른 폴더의 세션에서도 호출되기 때문)
KIT_WS="$(cd "$KIT_DIR/../.." 2>/dev/null && pwd)"
in_scope() {
  [ -n "${ADVISOR_ANY_WORKSPACE:-}" ] && return 0
  [ -z "$WS" ] && return 0
  [ "$WS" = "$KIT_WS" ] && return 0
  case "$WS" in "$KIT_WS"/*) return 0 ;; esac
  return 1
}
# 리드 세션에만 트리거를 건다. 하위 에이전트(Hydrogen)와 자문(Carbon) 세션은 통과시킨다.
is_lead() {
  in_scope || return 1
  [ -z "$MODEL" ] && return 0
  printf '%s' "$MODEL" | grep -Eiq -- "$ADVISOR_LEAD_MODEL_REGEX"
}

# 사용자 요청이 바뀌면 요청 단위 카운터를 초기화한다.
roll_request() {
  [ "$(st_get '.reqKey')" = "$REQ_KEY" ] && return 0
  st_set --arg k "$REQ_KEY" '.reqKey=$k | .reqEdits=0 | .files=[] | .gateAsked=false | .advisorThisReq=false
    | .editsAtAdvisor=-1 | .stopReviews=0 | .stopAskedAtEdits=-1 | .errSig="" | .errKey="" | .errCount=0 | .pending=""'
}

# 대화 기록의 최근 부분을 워크스페이스 안으로 복사한다(자문이 읽을 사본, 크기 제한).
SNAP=""; SNAP_REL=""
snapshot_transcript() {
  SNAP=""; SNAP_REL=""
  [ -n "$TPATH" ] && [ -r "$TPATH" ] || return 0
  local limit size out
  limit=$((ADVISOR_TRANSCRIPT_TAIL_KB * 1024))
  size="$(wc -c < "$TPATH" 2>/dev/null | tr -d ' ')"
  out="$STATE_DIR/transcript-tail-$(printf '%s' "$CONV" | cut -c1-8).jsonl"
  if [ "${size:-0}" -le "$limit" ]; then cp "$TPATH" "$out" 2>/dev/null || return 0
  else tail -c "$limit" "$TPATH" 2>/dev/null | sed '1d' > "$out" 2>/dev/null || return 0
  fi
  SNAP="$out"; SNAP_REL="$out"
  if [ -n "$WS" ]; then case "$out" in "$WS"/*) SNAP_REL="${out#"$WS"/}" ;; esac; fi
}
snap_clause() { [ -n "$SNAP_REL" ] && printf ', 대화 기록 사본 경로(%s)' "$SNAP_REL"; }

trigger_label() { case "$1" in 0) echo "계획 확정 전" ;; 1) echo "같은 오류 ${ADVISOR_SAME_ERROR_THRESHOLD}회" ;; 2) echo "완료 전" ;; *) echo "자문" ;; esac; }

emit_advisor() { # <trigger> <state> [advice]
  local calls; calls="$(af_get '.calls')"; [ -n "$calls" ] || calls=0
  if [ -n "${3:-}" ]; then
    emit "$(jq -cn --argjson t "$1" --arg s "$2" --argjson c "$calls" --arg a "$3" '{type:"advisor",trigger:$t,state:$s,calls:$c,advice:$a}')"
  else
    emit "$(jq -cn --argjson t "$1" --arg s "$2" --argjson c "$calls" '{type:"advisor",trigger:$t,state:$s,calls:$c}')"
  fi
}

advisor_idle() {
  af_init
  [ "$(af_get '.active')" = "true" ] || return 0
  af_set '.active=false'
  emit_advisor -1 "대기 중"
}

# 자문 답변의 마지막 줄 "CARBON_ADVICE: ..." 를 대화 기록에서 찾아 화면용 이벤트로 내보낸다.
# 기록 파일의 스키마에 의존하지 않도록 표식 문자열만 찾는다.
harvest_advice() {
  [ -n "$TPATH" ] && [ -r "$TPATH" ] || return 0
  af_init
  local adv trig
  adv="$(tail -c 400000 "$TPATH" 2>/dev/null | grep -o 'CARBON_ADVICE:[^"\\]*' | tail -1 \
        | sed 's/^CARBON_ADVICE:[[:space:]]*//; s/[[:space:]]*$//' | cut -c1-300)"
  [ -n "$adv" ] || return 0
  case "$adv" in "("*|"["*|"."*|"<"*) return 0 ;; esac   # 형식 설명 줄이나 스크립트 본문이 잡힌 경우는 무시
  [ "$adv" = "$(af_get '.lastAdvice')" ] && return 0
  trig="$(af_get '.trigger')"; case "$trig" in 0|1|2) ;; *) trig=0 ;; esac
  af_set --arg a "$adv" '.lastAdvice=$a | .active=false'
  emit_advisor "$trig" "대기 중" "$adv"
  emit_advisor -1 "대기 중"
  emit_log "Carbon" "purple" "조언: $adv"
}

# ---------- Decision 1 (Gemini Decisions API) ----------
# 규격: https://aistudio.google.com/docs/decisions-api
#   POST /v1beta/decisions  {model, input, questions:{<key>:{type:"noul", instructions, criteria}}}
#   응답 .answers.<key> = {type:"noul", noul:<예 확률>, confidence:<max(noul, 1-noul)>}
# 결과: D_STATUS = sharp_yes | sharp_no | split | unavailable
D_NOUL=""; D_CONF=""; D_STATUS="unavailable"
decisions_key() {
  if [ -n "${ADVISOR_DECISIONS_API_KEY:-}" ]; then printf '%s' "$ADVISOR_DECISIONS_API_KEY"
  elif [ -r "$ADVISOR_DECISIONS_KEY_FILE" ]; then tr -d ' \t\r\n' < "$ADVISOR_DECISIONS_KEY_FILE"
  fi
}
decide() { # <화면 이름> <질문> <예 기준> <아니오 기준> <입력 텍스트>
  D_NOUL=""; D_CONF=""; D_STATUS="unavailable"
  [ "$ADVISOR_DECISION" = "off" ] && return 0
  command -v curl >/dev/null 2>&1 || return 0
  local key body resp
  key="$(decisions_key)"; [ -n "$key" ] || return 0
  body="$STATE_DIR/.req.$$.json"
  jq -cn --arg m "$ADVISOR_DECISION_MODEL" --arg i "$5" --arg q "$2" --arg t "$3" --arg f "$4" \
    '{model:$m,input:$i,questions:{gate:{type:"noul",instructions:$q,criteria:{true_description:$t,false_description:$f}}}}' \
    > "$body" 2>>"$HOOK_LOG" || { rm -f "$body"; return 0; }
  # API 키가 프로세스 목록(ps)에 보이지 않도록 헤더를 표준 입력으로 넘긴다.
  resp="$(printf 'header = "x-goog-api-key: %s"\n' "$key" | curl -sS -K - --max-time "$ADVISOR_DECISION_TIMEOUT" \
           -X POST "$ADVISOR_DECISIONS_URL" -H "Content-Type: application/json" --data-binary "@$body" 2>>"$HOOK_LOG")"
  rm -f "$body"
  D_NOUL="$(printf '%s' "$resp" | jq -r '.answers.gate.noul // empty' 2>/dev/null)"
  if [ -z "$D_NOUL" ]; then dbg "decision 응답 없음/오류: $(printf '%s' "$resp" | cut -c1-200)"; return 0; fi
  D_CONF="$(printf '%s' "$resp" | jq -r '.answers.gate.confidence // empty' 2>/dev/null)"
  [ -n "$D_CONF" ] || D_CONF="$(jq -n --argjson p "$D_NOUL" 'if $p >= 0.5 then $p else 1 - $p end')"
  D_STATUS="$(jq -rn --argjson p "$D_NOUL" --argjson c "$D_CONF" --argjson t "$ADVISOR_CONF_THRESHOLD" \
    'if $c < $t then "split" elif $p >= 0.5 then "sharp_yes" else "sharp_no" end' 2>/dev/null)"
  [ -n "$D_STATUS" ] || { D_STATUS="unavailable"; return 0; }

  # 화면의 p 는 "확신도(confidence)"로 통일한다. 0.70 이상이면 sharp, 미만이면 split.
  local kind hint
  if [ "$D_STATUS" = "split" ]; then kind="split"; else kind="sharp"; fi
  hint="$(jq -rn --argjson p "$D_NOUL" '"예 확률 " + (($p * 100 | round) / 100 | tostring)')"
  st_set --arg n "$1" --argjson c "$D_CONF" --arg h "$hint" --arg k "$kind" \
    '.forks+=1 | (if $k=="sharp" then .sharp+=1 else .split+=1 end) | .routes[$n]={p:$c,hint:$h}'
  emit "$(jq -c '{type:"decision",forks:.forks,routes:[.routes|to_entries[]|{name:.key,p:.value.p,targetHint:.value.hint}]}' "$SF" 2>/dev/null)"
  printf '%s\n' "$(jq -cn --arg t "$(date +%FT%T)" --arg c "$CONV" --arg n "$1" --argjson p "$D_NOUL" --argjson cf "$D_CONF" --arg s "$D_STATUS" \
    '{time:$t,conversation:$c,route:$n,noul:$p,confidence:$cf,status:$s}')" >> "$STATE_DIR/decisions.jsonl" 2>/dev/null
  emit_log "Decision 1" "green" "$(jq -rn --arg n "$1" --argjson p "$D_NOUL" --argjson c "$D_CONF" --arg s "$D_STATUS" \
    '$n + " -> " + (if $s=="sharp_yes" then "필요" elif $s=="sharp_no" then "불필요" else "판정 갈림" end)
     + "  예=" + (($p*100|round)/100|tostring) + " 확신도=" + (($c*100|round)/100|tostring)
     + (if $s=="split" then " split -> 리드 판단" else " sharp -> 코드" end)')"
}

# ---------- 이벤트 처리 ----------
allow() { printf '%s\n' '{"decision":"allow"}'; }
empty() { printf '%s\n' '{}'; }

on_session_start() {
  is_lead || { empty; return; }
  lock
  printf '%s\n' "$STATE_DEFAULT" > "$SF"
  printf '%s\n' "$AF_DEFAULT" > "$AF"
  : > "$EVENTS"
  local effort=""
  case "$MODEL" in *-low) effort="low" ;; *-medium) effort="medium" ;; *-xhigh) effort="" ;; *-high) effort="high" ;; *-max) effort="max" ;; esac
  local cwd="$WS"
  case "$cwd" in "$HOME"/*) cwd="~/${cwd#"$HOME"/}" ;; esac
  emit '{"type":"reset"}'
  emit "$(jq -cn --arg cwd "$cwd" --arg m "$MODEL" --arg e "$effort" \
    '{type:"session",cwd:$cwd} + (if $m!="" then {model:$m} else {} end) + (if $e!="" then {effort:$e} else {} end)')"
  # 대시보드의 초기 자리표시 숫자(예시 값)를 실제 값으로 덮어쓴다. 모르는 값은 "-" 로 둔다.
  emit '{"type":"advisor","trigger":-1,"state":"대기 중","calls":0,"tokens":"-","advice":"(아직 자문 없음)"}'
  emit '{"type":"decision","forks":0,"routes":[]}'
  emit '{"type":"swarm","active":0,"max":0,"cards":[{"name":"-","model":"subagent","progress":0,"description":"하위 에이전트 없음","status":"idle"}]}'
  emit '{"type":"phase","phase":"탐색","argonBuilds":1}'
  emit_log "Argon" "orange" "세션 시작${MODEL:+ ($MODEL)}"
  unlock
  if [ "$ADVISOR_SESSION_BRIEF" = "off" ]; then empty; return; fi
  jq -cn --arg n "$ADVISOR_AGENT_NAME" '{injectSteps:[{systemMessage:{systemMessage:
    ("이 워크스페이스에는 읽기 전용 자문 서브에이전트 \"" + $n + "\"가 있습니다. 훅이 [자문 트리거] 안내를 보내면 invoke_subagent 도구로 TypeName \"" + $n + "\"를 호출하고, 답을 받은 뒤 다음 단계로 진행하세요. 안내가 없으면 호출하지 않아도 됩니다. 조언을 적용할지와 그 방법은 당신이 결정합니다."),
    metadata:{source:"advisor-kit",trigger:"session_brief"}}}]}'
}

on_pre_tool() {
  is_lead || { allow; return; }
  printf '%s' "$TOOL" | grep -Eq "$WRITE_TOOLS_RE" || { allow; return; }
  [ "$ADVISOR_PLAN_GATE" = "off" ] && { allow; return; }
  # 구현 계획 같은 아티팩트 작성은 코드 수정이 아니므로 통과시킨다.
  [ "$(J '(.toolCall.args.IsArtifact // false) | tostring | test("true")')" = "true" ] && { allow; return; }
  lock; state_init; roll_request
  if [ "$(st_get '.gateAsked')" = "true" ] || [ "$(st_get '.advisorThisReq')" = "true" ]; then unlock; allow; return; fi
  st_set '.gateAsked=true'

  local verdict="gate" head
  if [ "$ADVISOR_PLAN_GATE" = "auto" ]; then
    decide "수정 전 검토" \
      "Is this code change broad or risky enough that a senior engineer should review the plan before any file is edited?" \
      "Touches authentication, payments, database schema or transactions, public API contracts, security, or data deletion; spans several modules; or the request is ambiguous." \
      "Small, local, easily reversible edit with clear intent, such as a typo, rename, comment, single-function fix, or a test or docs only change." \
      "$(printf '%s' "$INPUT" | jq -r '"User request:\n" + ((.lastUserInput // "")[0:2000])
          + "\n\nProposed tool call: " + (.toolCall.name // "")
          + "\nTarget file: " + ((.toolCall.args.TargetFile // "") | tostring)
          + "\nDescription: " + (((.toolCall.args.Description // .toolCall.args.Instruction // "") | tostring)[0:600])' 2>/dev/null)"
    case "$D_STATUS" in sharp_no) verdict="skip" ;; sharp_yes) verdict="gate_yes" ;; split) verdict="gate_split" ;; esac
  fi
  if [ "$verdict" = "skip" ]; then unlock; allow; return; fi

  local conf_fmt=""
  [ -n "$D_CONF" ] && conf_fmt="$(jq -rn --argjson c "$D_CONF" '($c*100|round)/100' 2>/dev/null)"
  snapshot_transcript
  st_set '.trigger=0'
  emit_phase "계획 확정"
  emit_log "Carbon" "purple" "계획 확정 전 - 자문 호출 안내"
  case "$verdict" in
    gate_yes) head="Decision 1이 수정 전 검토가 필요하다고 판정했습니다(확신도 $conf_fmt). invoke_subagent로 TypeName \"$ADVISOR_AGENT_NAME\"를 호출해 계획을 검토받은 뒤 수정하세요." ;;
    gate_split) head="Decision 1의 판정이 갈렸습니다(확신도 $conf_fmt). 변경 범위가 넓거나 위험하다고 판단하면 invoke_subagent로 TypeName \"$ADVISOR_AGENT_NAME\"를 호출해 계획을 검토받으세요." ;;
    *) head="변경 범위가 넓거나 위험하면(인증, 결제, DB, 공개 API, 여러 모듈) invoke_subagent로 TypeName \"$ADVISOR_AGENT_NAME\"를 호출해 계획을 검토받으세요." ;;
  esac
  unlock
  jq -cn --arg r "[자문 트리거 · 계획 확정 전] 첫 파일 수정 전에 한 번 멈췄습니다. $head 프롬프트에는 목표, 수정할 파일 목록, 계획 요약$(snap_clause)를 넣으세요. 단순하고 되돌리기 쉬운 수정이라고 판단하면 자문 없이 같은 호출을 그대로 다시 실행하면 됩니다. 이 안내는 사용자 요청당 한 번만 나옵니다." \
    '{decision:"deny",reason:$r}'
}

on_post_tool() {
  is_lead || { empty; return; }
  lock; state_init; af_init; roll_request
  local key
  key="$(J '(.toolCall.args.CommandLine // .toolCall.args.TargetFile // .toolCall.args.AbsolutePath // "") | tostring' | cut -c1-400)"

  if printf '%s' "$TOOL" | grep -Eq "$WRITE_TOOLS_RE"; then
    if [ -z "$ERR" ] && [ "$(J '(.toolCall.args.IsArtifact // false) | tostring | test("true")')" != "true" ]; then
      local f; f="$(J '(.toolCall.args.TargetFile // "") | tostring | gsub("^\"|\"$";"")')"
      st_set --arg f "$f" '.reqEdits+=1 | .files=((.files+[$f]) | map(select(.!="")) | unique | .[-30:])'
      [ "$(st_get '.reqEdits')" = "1" ] && emit_phase "수정 적용"
      emit_log "Argon" "orange" "수정 적용: $(basename "${f:-파일}")"
      advisor_idle
    fi
  elif [ "$TOOL" = "invoke_subagent" ] && [ -z "$ERR" ]; then
    if is_advisor_call; then
      local trig; trig="$(st_get '.trigger')"
      case "$trig" in 0|1|2) ;; *) if [ "$(st_get '.reqEdits')" -gt 0 ] 2>/dev/null; then trig=2; else trig=0; fi ;; esac
      st_set '.advisorThisReq=true | .editsAtAdvisor=.reqEdits | .errSig="" | .errKey="" | .errCount=0 | .pending="" | .trigger=-1'
      af_set --argjson t "$trig" '.calls+=1 | .active=true | .trigger=$t'
      emit_advisor "$trig" "자문 중"
      emit_log "Carbon" "purple" "$(trigger_label "$trig") - 자문 시작"
    else
      emit_log "Hydrogen" "blue" "하위 에이전트 위임: $(subagent_label)"
    fi
  fi

  if [ -n "$ERR" ]; then
    local sig cnt
    sig="$(sha "$TOOL|$key|$ERR")"
    if [ "$(st_get '.errSig')" = "$sig" ]; then
      st_set '.errCount+=1'
    else
      st_set --arg s "$sig" --arg k "$(sha "$TOOL|$key")" --arg t "$TOOL" --arg d "$(printf '오류: %s / 대상: %s' "$ERR" "$key" | cut -c1-500)" \
        '.errSig=$s | .errKey=$k | .errCount=1 | .errTool=$t | .errDetail=$d'
    fi
    cnt="$(st_get '.errCount')"
    emit_log "Argon" "orange" "$TOOL 실패 (같은 오류 ${cnt}회): $(printf '%s' "$ERR" | cut -c1-80)"
    if [ "$cnt" -ge "$ADVISOR_SAME_ERROR_THRESHOLD" ] 2>/dev/null && [ $((cnt % ADVISOR_SAME_ERROR_THRESHOLD)) -eq 0 ]; then
      st_set '.pending="same_error" | .trigger=1'
      emit_phase "오류 수정"
    fi
  elif [ -n "$key" ] && [ "$(st_get '.errKey')" = "$(sha "$TOOL|$key")" ]; then
    # 같은 명령이 성공했으면 오류 카운터를 지운다.
    st_set '.errSig="" | .errKey="" | .errCount=0 | .pending=""'
  fi
  unlock
  empty
}

on_pre_invocation() {
  is_lead || { empty; return; }
  [ -s "$SF" ] || { empty; return; }
  lock
  harvest_advice
  if [ "$(st_get '.pending')" = "same_error" ]; then
    local cnt tool detail msg
    cnt="$(st_get '.errCount')"; tool="$(st_get '.errTool')"; detail="$(st_get '.errDetail')"
    snapshot_transcript
    st_set '.pending=""'
    emit_log "Carbon" "purple" "같은 오류 ${cnt}회 - 자문 호출 안내"
    msg="[자문 트리거 · 같은 오류 ${cnt}회] ${tool} 호출이 같은 오류로 ${cnt}회 실패했습니다. ${detail}. 같은 방법을 다시 시도하기 전에 invoke_subagent로 TypeName \"$ADVISOR_AGENT_NAME\"를 호출해 원인 진단을 받으세요. 프롬프트에는 실패한 명령과 오류 전문, 지금까지 시도한 수정, 관련 파일 경로$(snap_clause)를 넣으세요."
    unlock
    jq -cn --arg m "$msg" '{injectSteps:[{systemMessage:{systemMessage:$m,metadata:{source:"advisor-kit",trigger:"same_error"}}}]}'
    return
  fi
  unlock
  empty
}

on_stop() {
  lock
  in_scope && harvest_advice   # 자문 세션 자신의 종료에서도 조언 줄을 찾는다(훅이 서브에이전트에서도 돈다면).
  if ! is_lead || [ ! -s "$SF" ]; then unlock; allow; return; fi
  af_init; roll_request
  local reason idle req at asked reviews
  reason="$(J '.terminationReason // ""')"
  # 주의: jq 의 // 는 false 도 "없음"으로 취급하므로 여기서는 쓰면 안 된다.
  idle="$(J 'if .fullyIdle == false then "false" else "true" end')"
  req="$(st_get '.reqEdits')"; at="$(st_get '.editsAtAdvisor')"
  asked="$(st_get '.stopAskedAtEdits')"; reviews="$(st_get '.stopReviews')"

  if [ "$ADVISOR_STOP_REVIEW" != "off" ] && [ "$reason" = "model_stop" ] && [ "$idle" = "true" ] \
     && [ "${req:-0}" -gt 0 ] && [ "${at:--1}" -lt "$req" ] && [ "${asked:--1}" -ne "$req" ] \
     && [ "${reviews:-0}" -lt "$ADVISOR_MAX_STOP_REVIEWS" ]; then
    local verdict="review" files
    files="$(st_get '.files | map(split("/") | last) | join(", ")' | cut -c1-300)"
    st_set '.stopReviews+=1 | .stopAskedAtEdits=.reqEdits'
    if [ "$ADVISOR_STOP_REVIEW" = "auto" ]; then
      decide "완료 전 검토" \
        "Should an independent reviewer check these code changes before the task is declared complete?" \
        "Several files changed, or the change touches authentication, payments, database, public API, or security, or tests were not clearly run and passing." \
        "A small, low-risk change in one place whose result is already verified." \
        "$(printf '%s' "$INPUT" | jq -r --arg n "$req" --arg f "$files" '"User request:\n" + ((.lastUserInput // "")[0:2000]) + "\n\nSuccessful file edits in this request: " + $n + "\nEdited files: " + $f' 2>/dev/null)"
      [ "$D_STATUS" = "sharp_no" ] && verdict="skip"
    fi
    if [ "$verdict" = "review" ]; then
      snapshot_transcript
      st_set '.trigger=2'
      emit_phase "검증 중"
      emit_log "Carbon" "purple" "완료 전 - 자문 호출 안내"
      unlock
      jq -cn --arg r "[자문 트리거 · 완료 전] 이번 요청에서 파일을 ${req}회 수정했습니다(${files}). 완료를 선언하기 전에 invoke_subagent로 TypeName \"$ADVISOR_AGENT_NAME\"를 호출해 변경 사항과 테스트 결과를 검토받으세요. 프롬프트에는 변경한 파일 경로, 실행한 테스트와 그 결과$(snap_clause)를 넣으세요. 검토에서 문제가 없으면 그대로 마무리하면 됩니다." \
        '{decision:"continue",reason:$r}'
      return
    fi
  fi
  advisor_idle
  if [ "$reason" = "model_stop" ] && [ "$idle" = "true" ]; then emit_phase "완료"; fi
  unlock
  allow
}

main() {
  dbg "conv=$CONV model=${MODEL:--} tool=${TOOL:--} err=$([ -n "$ERR" ] && echo y || echo n) lead=$(is_lead && echo y || echo n)"
  case "$EVENT" in
    SessionStart) on_session_start ;;
    PreToolUse) on_pre_tool ;;
    PostToolUse) on_post_tool ;;
    PreInvocation) on_pre_invocation ;;
    Stop) on_stop ;;
    *) fallback ;;
  esac
}

OUT="$(main 2>>"$HOOK_LOG")"
unlock
if printf '%s' "$OUT" | jq -e 'type=="object"' >/dev/null 2>&1; then
  printf '%s\n' "$OUT" | jq -c . 2>/dev/null || fallback
else
  [ -n "$OUT" ] && dbg "잘못된 출력을 통과 처리로 대체: $(printf '%s' "$OUT" | cut -c1-200)"
  fallback
fi
exit 0
