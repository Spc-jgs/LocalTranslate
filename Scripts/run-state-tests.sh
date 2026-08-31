#!/bin/bash
#
# 编译并运行 Tests/ 下的状态测试。
#
# 这些测试是独立的 `@main` 可执行文件，各自有入口，因此必须分别编译，
# 不能合并到同一个 target。CI 与本机都通过这个脚本运行，避免命令只
# 存在于某篇设计文档里、实际从不执行。
#
# AIUsageRealCorpusSmoke 读取真实的 ~/.codex 等目录，只在本机有意义，
# 默认不在这里运行。

set -euo pipefail

cd "$(dirname "$0")/.."

BUILD_DIR="$(mktemp -d)"
trap 'rm -rf "$BUILD_DIR"' EXIT

FAILED=0

run_suite() {
  local name="$1"
  shift

  echo "──────────────────────────────────────────"
  echo "▸ $name"

  local binary="$BUILD_DIR/$name"

  if ! xcrun swiftc -swift-version 5 "$@" -o "$binary" 2>&1; then
    echo "✗ $name: 编译失败"
    FAILED=1
    return
  fi

  if "$binary"; then
    echo "✓ $name"
  else
    echo "✗ $name: 运行失败"
    FAILED=1
  fi
}

run_suite "LiveSubtitlePipelineStateTests" \
  LocalTranslate/Features/LiveSubtitles/Models/LiveSubtitlePipelineModels.swift \
  Tests/LiveSubtitlePipelineStateTests.swift

run_suite "AIUsageIndexTests" \
  LocalTranslate/Features/AIUsage/Models/UsageModels.swift \
  LocalTranslate/Features/AIUsage/Services/UsageIndex.swift \
  LocalTranslate/Features/AIUsage/Services/UsageScanExecutor.swift \
  Tests/AIUsageIndexTests.swift

run_suite "AIUsageProviderFixtureTests" \
  LocalTranslate/Core/Config/AppSettings.swift \
  LocalTranslate/Core/System/ShellResolver.swift \
  LocalTranslate/Features/Translate/Models/TranslationStyle.swift \
  LocalTranslate/Features/AIUsage/Models/UsageModels.swift \
  LocalTranslate/Features/AIUsage/Services/UsageIndex.swift \
  LocalTranslate/Features/AIUsage/Services/UsageScanExecutor.swift \
  LocalTranslate/Features/AIUsage/Services/AGYUsageProtoParser.swift \
  LocalTranslate/Features/AIUsage/Services/UsageActivityIndexer.swift \
  LocalTranslate/Features/AIUsage/Services/UsageReferencePriceCatalog.swift \
  LocalTranslate/Features/AIUsage/Services/CodexProvider.swift \
  Tests/AIUsageProviderFixtureTests.swift

run_suite "AGYLocalQuotaClientTests" \
  LocalTranslate/Features/AIUsage/Models/UsageModels.swift \
  LocalTranslate/Features/AIUsage/Services/AGYLocalQuotaClient.swift \
  Tests/AGYLocalQuotaClientTests.swift

run_suite "AIUsageDashboardTests" \
  LocalTranslate/Features/AIUsage/Models/UsageModels.swift \
  LocalTranslate/Features/AIUsage/Models/UsageDashboardSnapshot.swift \
  Tests/AIUsageDashboardTests.swift

echo "──────────────────────────────────────────"

if [ "$FAILED" -ne 0 ]; then
  echo "状态测试未全部通过"
  exit 1
fi

echo "状态测试全部通过"
