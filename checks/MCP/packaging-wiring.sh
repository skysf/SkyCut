#!/usr/bin/env bash
# MCP helper packaging and signing-order scans, sourced by scripts/check-mcp.sh.
# This block only inspects build scripts; it never packages or signs an app.

echo "==> 打包脚本：小程序进 Helpers、先签它再签外层"
# 签名只经 scripts/signing/sign-app.sh 一处（docs/architecture/code-signing-and-permissions.md）：
# build-app.sh 要先把小程序拷进去再调它，它里面要先签小程序再签外层。
BUILD_SCRIPT="scripts/build-app.sh"
SIGN_SCRIPT="scripts/signing/sign-app.sh"
COPY_LINE="$(grep -n 'cp "$BUILD_DIR/skycut-mcp" "$APP/Contents/Helpers/skycut-mcp"' "${BUILD_SCRIPT}" | cut -d: -f1 || true)"
CALL_SIGN="$(grep -n '^scripts/signing/sign-app.sh "$APP"$' "${BUILD_SCRIPT}" | cut -d: -f1 || true)"
SIGN_HELPER="$(grep -n '^sign_code "${APP}/Contents/Helpers/skycut-mcp"$' "${SIGN_SCRIPT}" | cut -d: -f1 || true)"
SIGN_APP="$(grep -n '^sign_code --entitlements "${SIGNING_ENTITLEMENTS}" "${APP}"$' "${SIGN_SCRIPT}" | cut -d: -f1 || true)"
if [ -z "${COPY_LINE}" ] || [ -z "${CALL_SIGN}" ] || [ -z "${SIGN_HELPER}" ] || [ -z "${SIGN_APP}" ]; then
  echo "✗ ${BUILD_SCRIPT} 没把 skycut-mcp 拷进 Contents/Helpers，或 ${SIGN_SCRIPT} 没签它：AI 客户端配置里写的那个路径会不存在" >&2
  exit 1
fi
if [ "${COPY_LINE}" -gt "${CALL_SIGN}" ]; then
  echo "✗ ${BUILD_SCRIPT} 先签名再拷 skycut-mcp：拷进去的小程序没签名，外层签名也立即失效" >&2
  exit 1
fi
if [ "${SIGN_HELPER}" -gt "${SIGN_APP}" ]; then
  echo "✗ ${SIGN_SCRIPT} 先签了外层再签 skycut-mcp：嵌套的可执行文件必须先签，否则外层签名立即失效" >&2
  exit 1
fi
echo "   ✓ ${BUILD_SCRIPT} 第 ${COPY_LINE} 行拷进去、第 ${CALL_SIGN} 行才签；${SIGN_SCRIPT} 第 ${SIGN_HELPER} 行签小程序、第 ${SIGN_APP} 行才签外层"
