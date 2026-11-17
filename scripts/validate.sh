#!/usr/bin/env bash
# validate.sh — 语法校验，不改任何规则
# 用法: ./validate.sh <host>
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOST="${1:?用法: validate.sh <host>}"
CONF="$("$REPO/scripts/render.sh" "$HOST")"
echo "校验生成配置: $CONF"
# nft -c 需要 root（netlink 初始化），但 render 只是拼文本、用普通用户执行避免文件变 root 属主
sudo -n nft -c -f "$CONF"
echo "OK: $HOST 配置语法通过"
