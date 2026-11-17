#!/bin/bash
# statusline.sh - Antigravity CLI 사용자 지정 상태줄 (Carbon 자문 키트)
#   규격: https://antigravity.google/docs/cli/statusline  (stdin: 세션 상태 JSON, stdout: 상태줄)
#   설정: agy 안에서  /statusline <이 파일의 절대 경로>
#
# 폭이 모호한 기호(· ● → 등)는 한국어 터미널에서 줄을 틀어지게 할 수 있어서
# ASCII 와 한글만 쓴다. 색은 표준 16색만 쓰고 NO_COLOR 가 있으면 끈다.

INPUT="$(cat 2>/dev/null)"
if ! command -v jq >/dev/null 2>&1; then echo "advisor-kit: jq 가 필요합니다"; exit 0; fi

ADV_NAME="${ADVISOR_AGENT_NAME:-carbon-advisor}"

# 빈 값은 "-" 로 채운다(탭 구분 read 는 빈 칸을 건너뛴다).
IFS=$'\t' read -r STATE MODEL PCT COST SUBCOST RUN TOTAL ADVSTAT PENDING TASKS COLS CONV PROJ QUOTA <<EOF2
$(printf '%s' "$INPUT" | jq -r --arg adv "$ADV_NAME" '
  def isadv: (((.name // "") + " " + (.role // "")) | ascii_downcase | contains($adv | ascii_downcase));
  ((.subagents // []) | map(select(type=="object"))) as $all
  | ($all | map(select(isadv | not))) as $s
  | [ (.agent_state // "idle"),
      (.model.display_name // .model.id // "-"),
      (.context_window.used_percentage // 0),
      (.cost.total_usd // "-"),
      (.cost.subagent_usd // "-"),
      ($s | map(select(.status=="running")) | length),
      ($s | length),
      (($all | map(select(isadv)) | last | .status) // "-"),
      (.tool_confirmation_pending // false),
      (.task_count // 0),
      (.terminal_width // 80),
      (.conversation_id // "-"),
      (.workspace.project_dir // .cwd // "-"),
      ([.quota[]? | .remaining_fraction? // empty] | min // "-")
    ] | map(tostring | if . == "" then "-" else . end) | @tsv' 2>/dev/null)
EOF2
: "${STATE:=idle}" "${MODEL:=-}" "${PCT:=0}" "${COST:=-}" "${SUBCOST:=-}" "${RUN:=0}" "${TOTAL:=0}" "${ADVSTAT:=-}"
: "${PENDING:=false}" "${TASKS:=0}" "${COLS:=80}" "${CONV:=-}" "${PROJ:=-}" "${QUOTA:=-}"

if [ -z "${NO_COLOR:-}" ]; then
  R=$'\033[0m'; B=$'\033[1m'; GRAY=$'\033[90m'; ORANGE=$'\033[33m'; BLUE=$'\033[94m'
  GREEN=$'\033[92m'; PURPLE=$'\033[95m'; RED=$'\033[91m'; WHITE=$'\033[97m'
else
  R=""; B=""; GRAY=""; ORANGE=""; BLUE=""; GREEN=""; PURPLE=""; RED=""; WHITE=""
fi
SEP="${GRAY} | ${R}"
num() { LC_NUMERIC=C printf "$1" "$2" 2>/dev/null || printf '%s' "$2"; }

case "$STATE" in
  idle) S="${GREEN}${B}대기${R}" ;;
  working) S="${ORANGE}${B}작업 중${R}" ;;
  tool_use) S="${ORANGE}${B}도구 실행${R}" ;;
  reviewing) S="${PURPLE}${B}검토 대기${R}" ;;
  authenticating) S="${GRAY}인증 중${R}" ;;
  initializing) S="${GRAY}초기화${R}" ;;
  error) S="${RED}${B}오류${R}" ;;
  *) S="${WHITE}${STATE}${R}" ;;
esac

PCT_INT="${PCT%.*}"; PCT_INT="${PCT_INT:-0}"
case "$PCT_INT" in ''|*[!0-9]*) PCT_INT=0 ;; esac
if [ "$PCT_INT" -ge 90 ]; then PC="$RED"; elif [ "$PCT_INT" -ge 60 ]; then PC="$ORANGE"; else PC="$WHITE"; fi
CTX="${GRAY}ctx ${PC}$(num '%.0f' "$PCT")%${R}"

COSTSEG=""
if [ "$COST" != "-" ]; then
  COSTSEG="${GRAY}비용 ${WHITE}\$$(num '%.2f' "$COST")${R}"
  [ "$SUBCOST" != "-" ] && [ "$SUBCOST" != "0" ] && COSTSEG="${COSTSEG}${GRAY} (하위 \$$(num '%.2f' "$SUBCOST"))${R}"
fi

QUOTASEG=""
if [ "$QUOTA" != "-" ]; then
  QP="$(num '%.0f' "$(jq -n --argjson q "$QUOTA" '$q*100' 2>/dev/null)")"
  case "$QP" in ''|*[!0-9]*) ;; *) if [ "$QP" -le 15 ]; then QUOTASEG="${RED}${B}할당량 ${QP}%${R}"; fi ;; esac
fi

# 자문 키트 상태 (이 워크스페이스에 키트가 설치돼 있을 때만)
SD="$PROJ/.agents/advisor-kit/state"
ADVSEG=""; FORKSEG=""
if [ -d "$SD" ]; then
  if [ -s "$SD/advisor.json" ]; then
    IFS=$'\t' read -r A_CALLS A_ACTIVE <<EOF3
$(jq -r '[(.calls // 0), (.active // false)] | map(tostring) | @tsv' "$SD/advisor.json" 2>/dev/null)
EOF3
    : "${A_CALLS:=0}" "${A_ACTIVE:=false}"
    # 서브에이전트 목록에서 자문이 끝난 것으로 보이면 대기 상태로 되돌린다.
    if [ "$A_ACTIVE" = "true" ] && [ "$ADVSTAT" = "completed" ]; then
      jq '.active=false' "$SD/advisor.json" > "$SD/advisor.json.sl.$$" 2>/dev/null && mv "$SD/advisor.json.sl.$$" "$SD/advisor.json"
      printf '%s\n' "$(jq -cn --argjson c "$A_CALLS" '{type:"advisor",trigger:-1,state:"대기 중",calls:$c}')" >> "$SD/events.jsonl" 2>/dev/null
      A_ACTIVE="false"
    fi
    if [ "$A_ACTIVE" = "true" ]; then ADVSEG="${PURPLE}${B}자문 중${R}${GRAY} (${A_CALLS}회)${R}"
    else ADVSEG="${PURPLE}자문 ${A_CALLS}회${R}"; fi
  fi
  if [ "$CONV" != "-" ] && [ -s "$SD/$CONV.json" ]; then
    IFS=$'\t' read -r F_ALL F_SHARP F_SPLIT <<EOF4
$(jq -r '[(.forks // 0), (.sharp // 0), (.split // 0)] | map(tostring) | @tsv' "$SD/$CONV.json" 2>/dev/null)
EOF4
    if [ "${F_ALL:-0}" != "0" ]; then FORKSEG="${GREEN}분기 ${F_ALL}${GRAY} (sharp ${F_SHARP:-0}, split ${F_SPLIT:-0})${R}"; fi
  fi

  # 화면(TUI)용 swarm 이벤트: 실제 상태(running/completed)만 싣는다. 진행률 값은 CLI 에 없다.
  if [ "${ADVISOR_STATUSLINE_EMIT:-on}" != "off" ] && [ "$TOTAL" != "0" ]; then
    SW="$(printf '%s' "$INPUT" | jq -c --arg adv "$ADV_NAME" '
      def isadv: (((.name // "") + " " + (.role // "")) | ascii_downcase | contains($adv | ascii_downcase));
      ((.subagents // []) | map(select(type=="object")) | map(select(isadv | not))) as $s
      | {type:"swarm", active: ($s | map(select(.status=="running")) | length), max: ($s | length),
         cards: ($s | map({name: (.name // "subagent"), model: "subagent",
                           progress: (if .status=="completed" then 100 else 0 end),
                           description: (.role // ""),
                           status: (if .status=="completed" then "done" else "running" end)})
                    | sort_by(.status) | reverse | .[0:3])}' 2>/dev/null)"
    if [ -n "$SW" ] && [ "$SW" != "$(cat "$SD/.swarm.last" 2>/dev/null)" ]; then
      printf '%s\n' "$SW" >> "$SD/events.jsonl" 2>/dev/null
      printf '%s' "$SW" > "$SD/.swarm.last" 2>/dev/null
    fi
  fi
fi

SUBSEG=""
[ "$TOTAL" != "0" ] && SUBSEG="${BLUE}하위 에이전트 ${B}${RUN}${R}${BLUE} 실행 / ${TOTAL}${R}"
TASKSEG=""
[ "$TASKS" != "0" ] && TASKSEG="${GRAY}백그라운드 ${TASKS}${R}"
PENDSEG=""
[ "$PENDING" = "true" ] && PENDSEG="${RED}${B}승인 대기${R}"

join() { # 비어 있지 않은 조각만 구분자로 잇는다
  local out="" part
  for part in "$@"; do
    [ -n "$part" ] || continue
    if [ -z "$out" ]; then out="$part"; else out="${out}${SEP}${part}"; fi
  done
  printf '%s' "$out"
}

case "$COLS" in ''|*[!0-9]*) COLS=80 ;; esac
LINE1="$(join "$S" "${ORANGE}${MODEL}${R}" "$CTX" "$COSTSEG" "$QUOTASEG" "$PENDSEG")"
LINE2="$(join "$SUBSEG" "$ADVSEG" "$FORKSEG" "$TASKSEG")"

if [ "$COLS" -ge 140 ] && [ -n "$LINE2" ]; then
  printf '%s%s%s\n' "$LINE1" "$SEP" "$LINE2"
elif [ "$COLS" -ge 70 ]; then
  printf '%s\n' "$LINE1"
  [ -n "$LINE2" ] && printf '%s\n' "$LINE2"
else
  # 좁은 화면: 가장 중요한 것만
  printf '%s\n' "$(join "$S" "$CTX" "$PENDSEG")"
  [ -n "$LINE2" ] && printf '%s\n' "$(join "$SUBSEG" "$ADVSEG")"
fi
exit 0
