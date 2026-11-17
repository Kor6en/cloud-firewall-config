#!/usr/bin/env bash
# deploy.sh — 幂等部署 inet host_fw，带备份 + 延迟自动回滚 + 独立会话确认
# 用法:
#   ./deploy.sh deploy <host>   部署（30 分钟内需 confirm，否则自动回滚）
#   ./deploy.sh confirm         验证通过后取消待执行的回滚
#   ./deploy.sh rollback        立即回滚（删除 inet host_fw，回到部署前状态）
#   ./deploy.sh timer           查看待执行的回滚定时器
# 安全设计：
#   - 只 delete 自己的 inet host_fw，绝不 flush ruleset，不动 Docker/Tailscale/Fail2ban 的表
#   - 部署前备份完整 ruleset；回滚粒度=删掉 inet host_fw（本机/ams 部署前均无此表）
#   - 用 systemd-run 延迟 1800s 自动回滚，远程部署后必须用另一个 SSH 会话验证再 confirm
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE=/var/lib/firewall
ROLLBACK_WINDOW=1800
ACTION="${1:?用法: deploy.sh <deploy|confirm|rollback|timer> [host]}"

mkdir -p "$STATE"

case "$ACTION" in
  deploy)
    HOST="${2:?用法: deploy.sh deploy <host>}"
    CONF="$("$REPO/scripts/render.sh" "$HOST")"
    echo "[1/6] 语法校验"
    nft -c -f "$CONF"
    echo "[2/6] 备份当前完整 ruleset 到 $STATE/ruleset.before.nft"
    sudo -n nft list ruleset > "$STATE/ruleset.before.nft"
    echo "[3/6] 写回滚脚本"
    sudo -n tee "$STATE/rollback.sh" >/dev/null <<'EOF'
#!/usr/bin/env bash
# 回滚：仅删除 inet host_fw，恢复到部署前状态
nft delete table inet host_fw 2>/dev/null || true
echo "rolled back at $(date)"
EOF
    sudo -n chmod 700 "$STATE/rollback.sh"
    echo "[4/6] 安排延迟自动回滚（${ROLLBACK_WINDOW}s 后），验证通过后用 confirm 取消"
    # 停掉可能存在的旧回滚定时器
    { sudo -n systemctl list-units --all 2>/dev/null | grep -o 'firewall-rollback-[0-9]*\.timer' || true; } | sort -u | while read -r u; do [ -n "$u" ] && sudo -n systemctl stop "$u" 2>/dev/null || true; done
    TS=$(date +%Y%m%d%H%M%S)
    UNIT="firewall-rollback-${TS}"
    sudo -n systemd-run --on-active="${ROLLBACK_WINDOW}s" --unit="$UNIT" --description="firewall auto-rollback" /usr/bin/env bash "$STATE/rollback.sh"
    echo "$UNIT" | sudo -n tee "$STATE/pending.timer" >/dev/null
    echo "[5/6] 应用新规则（只重建 inet host_fw）"
    sudo -n nft delete table inet host_fw 2>/dev/null || true
    sudo -n nft -f "$CONF"
    echo "[6/6] 部署完成。当前 host_fw 链策略："
    sudo -n nft list table inet host_fw 2>/dev/null | grep -E 'chain (input|forward|output)|policy' || true
    echo
    echo ">>> 请用【另一个 SSH 会话】验证 SSH/端口连通性，然后执行: $0 confirm"
    echo ">>> 若未确认，${ROLLBACK_WINDOW}s 后自动回滚。回滚单元: $UNIT"
    ;;
  confirm)
    U=$(sudo -n cat "$STATE/pending.timer" 2>/dev/null || true)
    if [ -n "$U" ]; then
      sudo -n systemctl stop "$U" 2>/dev/null && echo "已取消回滚定时器: $U"
      sudo -n rm -f "$STATE/pending.timer"
    else
      echo "无待确认的回滚定时器"
    fi
    ;;
  rollback)
    echo "立即回滚: 删除 inet host_fw"
    sudo -n bash "$STATE/rollback.sh"
    U=$(sudo -n cat "$STATE/pending.timer" 2>/dev/null || true)
    [ -n "$U" ] && sudo -n systemctl stop "$U" 2>/dev/null || true
    sudo -n rm -f "$STATE/pending.timer"
    ;;
  timer)
    echo "=== 待执行的回滚定时器 ==="
    sudo -n systemctl list-units --all 2>/dev/null | grep 'firewall-rollback' || echo "(无)"
    ;;
  *)
    echo "未知动作: $ACTION" >&2; exit 1
    ;;
esac
