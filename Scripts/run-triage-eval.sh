#!/bin/bash

set -euo pipefail

cd "$(dirname "$0")/.."

MODEL="${1:-qwen3.5:4b}"
CASES="Tests/Fixtures/triage-evaluation.json"
REPORT="${2:-$(mktemp -t localtranslate-triage).tsv}"
ENDPOINT="${OLLAMA_BASE_URL:-http://127.0.0.1:11434}"
SERVICE_SOURCE="LocalTranslate/Features/Triage/Services/TriageService.swift"

command -v jq >/dev/null || { echo "缺少 jq" >&2; exit 2; }
curl --fail --silent --show-error --max-time 3 "$ENDPOINT/api/tags" >/dev/null

SYSTEM_PROMPT="$(awk '
    /private static let systemPrompt = """/ { reading = 1; next }
    reading && /^        """/ { exit }
    reading { sub(/^        /, ""); print }
' "$SERVICE_SOURCE")"
test -n "$SYSTEM_PROMPT" || { echo "无法从 TriageService 提取 prompt" >&2; exit 2; }

SCHEMA='{"type":"object","properties":{"route":{"type":"string","enum":["enough","escalate"]},"kind":{"type":"string","enum":["ordinary","ambiguous","entity","current","technical"]},"explanation":{"type":"string"},"uncertainty_reason":{"type":"string"},"handoff_question":{"type":"string"}},"required":["route","kind","explanation","uncertainty_reason","handoff_question"]}'
CASE_COUNT="$(jq 'length' "$CASES")"

printf 'id\texpected\tactual\tkind\tfalse_safe_candidate\tlatency_ms\texplanation\tuncertainty_reason\treference\n' >"$REPORT"

while IFS= read -r item; do
    id="$(jq -r '.id' <<<"$item")"
    selected="$(jq -r '.selected' <<<"$item")"
    context="$(jq -r '.context' <<<"$item")"
    expected="$(jq -r '.expected_route' <<<"$item")"
    reference="$(jq -r '.reference' <<<"$item")"
    adjacent="$(jq -nr --arg context "$context" --arg selected "$selected" \
        '$context | split($selected) | join("【选中位置】")')"
    printf -v user_content \
        '<selected>\n%s\n</selected>\n<context>\n%s\n</context>' \
        "$selected" "$adjacent"

    payload="$(jq -n \
        --arg model "$MODEL" \
        --arg system "$SYSTEM_PROMPT" \
        --arg user "$user_content" \
        --argjson schema "$SCHEMA" \
        '{model:$model,messages:[{role:"system",content:$system},{role:"user",content:$user}],stream:false,think:false,format:$schema,options:{temperature:0,num_predict:192},keep_alive:"10m"}')"

    response="$(curl --fail --silent --show-error --max-time 60 \
        -H 'Content-Type: application/json' \
        -d "$payload" \
        "$ENDPOINT/api/chat")"
    content="$(jq -r '.message.content' <<<"$response")"
    actual="$(jq -r '.route // "invalid"' <<<"$content" 2>/dev/null || echo invalid)"
    kind="$(jq -r '.kind // "invalid"' <<<"$content" 2>/dev/null || echo invalid)"
    explanation="$(jq -r '.explanation // ""' <<<"$content" 2>/dev/null || true)"
    uncertainty="$(jq -r '.uncertainty_reason // ""' <<<"$content" 2>/dev/null || true)"
    latency_ms="$(jq -r '((.total_duration // 0) / 1000000 | floor)' <<<"$response")"
    false_safe=false
    if [[ "$expected" == "escalate" && "$actual" == "enough" ]]; then
        false_safe=true
    fi

    sanitize() { tr '\t\r\n' '   ' <<<"$1"; }
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$id" "$expected" "$actual" "$kind" "$false_safe" "$latency_ms" \
        "$(sanitize "$explanation")" "$(sanitize "$uncertainty")" \
        "$(sanitize "$reference")" >>"$REPORT"
    printf '✓ %s: %s → %s (%sms)\n' "$id" "$expected" "$actual" "$latency_ms"
done < <(jq -c '.[]' "$CASES")

false_safe_count="$(awk -F '\t' 'NR > 1 && $5 == "true" { count++ } END { print count + 0 }' "$REPORT")"
route_mismatch_count="$(awk -F '\t' 'NR > 1 && $2 != $3 { count++ } END { print count + 0 }' "$REPORT")"

echo "报告：$REPORT"
echo "false-safe candidates: $false_safe_count/$CASE_COUNT"
echo "route mismatches: $route_mismatch_count/$CASE_COUNT"
echo "注意：expected=enough 的事实正确性仍需人工按 reference 复核。"

if (( false_safe_count > 2 )); then
    echo "分诊门禁失败：false-safe 超过 2 个。" >&2
    exit 1
fi
