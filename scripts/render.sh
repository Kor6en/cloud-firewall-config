#!/usr/bin/env bash
# render.sh — 把 common + hosts 片段拼装成自包含 /etc/nftables.conf
# 用法: ./render.sh <host> [输出文件]
#   <host> 对应 hosts/<host>.nft；输出默认 /tmp/nftables.<host>.conf
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOST="${1:?用法: render.sh <host> [输出文件]}"
OUT="${2:-$REPO/.render/nftables.${HOST}.conf}"
mkdir -p "$(dirname "$OUT")"
HOSTFILE="$REPO/hosts/${HOST}.nft"
[ -f "$HOSTFILE" ] || { echo "缺少主机配置: $HOSTFILE" >&2; exit 1; }

cat > "$OUT" <<EOF
#!/usr/sbin/nft -f
# 自动生成，请勿手改。来源: firewall git repo (host: $HOST)
# 只定义 inet host_fw 一张表；不 flush ruleset，不影响 Docker/Tailscale/Fail2ban 的动态规则
# 旧表由 deploy.sh 在加载本文件前用 `nft delete table inet host_fw` 删除（幂等）

table inet host_fw {
    chain input {
        type filter hook input priority filter; policy drop;
EOF
# 通用打底规则
cat "$REPO/common/input-base.nft" >> "$OUT"
# 主机专属规则
echo "" >> "$OUT"
cat "$HOSTFILE" >> "$OUT"
cat >> "$OUT" <<EOF
    }

    chain forward {
        type filter hook forward priority filter; policy accept;
EOF
cat "$REPO/common/forward.nft" >> "$OUT"
cat >> "$OUT" <<EOF
    }

    chain output {
        type filter hook output priority filter; policy accept;
EOF
cat "$REPO/common/output.nft" >> "$OUT"
cat >> "$OUT" <<EOF
    }
}
EOF
echo "$OUT"
