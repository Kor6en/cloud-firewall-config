#!/usr/bin/env bash
# audit.sh — 只读审计：打印当前规则集、关键服务状态、暴露端口（脱敏由使用者负责）
# 用法: ./audit.sh
set -euo pipefail
echo "========== HOST =========="
hostnamectl --static 2>/dev/null || hostname
uname -r
grep PRETTY_NAME /etc/os-release 2>/dev/null
echo "========== FIREWALL SERVICES =========="
systemctl is-active nftables fail2ban tailscaled docker 2>/dev/null || true
echo "========== NFT TABLES =========="
sudo -n nft list tables 2>/dev/null || sudo nft list tables
echo "========== host_fw CHAIN POLICIES =========="
sudo -n nft list table inet host_fw 2>/dev/null | grep -E 'chain (input|forward|output)|policy' || echo "(inet host_fw 尚未部署)"
echo "========== F2B TABLE =========="
sudo -n nft list table inet f2b-table 2>/dev/null | head -5 || echo "(无 inet f2b-table)"
echo "========== LISTEN PORTS (公网) =========="
sudo -n ss -lntup 2>/dev/null | grep LISTEN | grep -vE '127\.0\.0\.|\[::1\]:|100\.|fd7a:' | head -20
echo "========== FAIL2BAN =========="
sudo -n fail2ban-client status sshd 2>/dev/null | grep -E 'Currently banned|Total banned' || true
