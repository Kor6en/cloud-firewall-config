# firewall — 六台服务器统一防火墙配置

用原生 nftables 统一管理六台 Ubuntu 服务器的主机防火墙。核心原则：**单一策略源、独立规则表、幂等部署、可回滚**。

## 设计原则

1. **只管理自己的表**：所有自定义规则都在 `inet host_fw` 一张表里。部署时只删除/重建这张表，**绝不 `flush ruleset`**，因此不会影响以下服务各自管理的动态规则：
   - Docker：iptables 后端（`DOCKER-USER` 等链）
   - Fail2ban：独立的 `inet f2b-table`
   - Tailscale：`netfilterMode=on`，自己管理 tailnet 规则
2. **默认策略**：INPUT drop、FORWARD accept（Docker 主机，转发交给 Docker）、OUTPUT accept（Tailscale 出站全覆盖）。
3. **公开仓库不含公网 IP**：规则只按端口放行，不含任何具体公网 IP 或内网拓扑。SSH 来源白名单如需添加，见"常见问题"。
4. **IPv4/IPv6 统一**：用 `inet` 表，一套规则同时覆盖。
5. **延迟自动回滚**：部署后 30 分钟内必须用另一个 SSH 会话验证并 `confirm`，否则自动回滚，防止把自己锁在门外。

## 目录结构

```
firewall/
├── common/                  # 所有主机共用的规则片段（render 时内联）
│   ├── input-base.nft       # INPUT 打底：established/lo/icmp
│   ├── forward.nft          # FORWARD（Docker 主机保持 accept）
│   └── output.nft           # OUTPUT（accept，Tailscale 出站已覆盖）
├── profiles/                # （预留）按角色区分的策略片段
├── hosts/                   # 每台主机的专属端口/接口
│   ├── osaka-arm.nft        # 本机：22/80/443/445 + Tailscale(udp41641)
│   └── ams.nft              # ams：22/443
├── scripts/
│   ├── render.sh            # 拼装成自包含 /etc/nftables.conf
│   ├── validate.sh          # 语法校验（不改规则）
│   ├── deploy.sh            # 部署/确认/回滚
│   └── audit.sh             # 只读审计
└── README.md
```

## 端口现状

| 主机 | 入站放行 |
|---|---|
| osaka-arm（本机） | 22 SSH、80/443 npm、445 samba；UDP 41641 Tailscale 直连、`tailscale0` 接口全放行；UDP 60000-61000 mosh、UDP 61001-61020 tsshd |
| ams | 22 SSH、443 sing-box |

其余四台（osaka、osakabeta、amsbeta、amsarm）尚未纳入，按需新增 `hosts/<hostname>.nft` 后部署。

## 维护命令速查

所有改动都遵循同一流程：**编辑 hosts 片段 → 校验 → 部署 → 另一会话验证 → 确认 → 提交**。

### 加锁/放端口（改 `hosts/<host>.nft`）

```bash
# 放行单个 TCP 端口
tcp dport 8080 accept

# 放行单个 UDP 端口
udp dport 5353 accept

# 放行端口范围（如本机 mosh 60000-61000、tssh 61001-61020）
udp dport 60000-61000 accept
tcp dport 8000-8100 accept

# 只让某来源访问（SSH 来源白名单，公网 IP 固定时推荐）
ip saddr 203.0.113.7 tcp dport 22 accept
ip saddr 203.0.113.0/24 tcp dport 22 accept

# 放行某网卡进来的全部流量（如 Tailscale）
iifname "tailscale0" accept

# 拒绝/丢弃某来源（放在白名单之后、默认策略之前）
ip saddr 198.51.100.0/24 drop
```

### 删端口 / 临时封端口

```bash
# 删除某条规则：直接编辑 hosts/<host>.nft 删掉对应行，再部署
# （配置即真相，不在运行时手删——手删会被下次部署覆盖）

# 临时封禁某 IP（不进 git，立即生效，重启失效；fail2ban 也用类似机制）
sudo nft add rule inet host_fw input ip saddr 198.51.100.99 drop
# 解封：记下 handle 再删
sudo nft -a list table inet host_fw | grep 198.51.100.99
sudo nft delete rule inet host_fw input handle <HANDLE>
```

### 校验 / 部署 / 回滚

```bash
# 校验语法（不改任何规则）
./scripts/validate.sh <host>

# 部署（30 分钟内必须 confirm，否则自动回滚）
sudo ./scripts/deploy.sh deploy <host>

# 另一 SSH 会话验证通过后，取消回滚
sudo ./scripts/deploy.sh confirm

# 立即回滚（删掉 inet host_fw，回到部署前状态）
sudo ./scripts/deploy.sh rollback

# 查看待执行的回滚定时器
sudo ./scripts/deploy.sh timer
```

### 查询 / 审计

```bash
# 只读审计（规则集、服务状态、暴露端口、fail2ban 状态）
./scripts/audit.sh

# 看当前 host_fw 全部规则
sudo nft list table inet host_fw

# 看某端口是否已放行（在输出里 grep）
sudo nft list table inet host_fw | grep 'dport 443'

# 看规则是否命中（给规则加 counter 后观察计数；默认规则无 counter）
sudo nft list table inet host_fw -a
```

### 新增一台主机

```bash
# 1. 复制模板
cp hosts/ams.nft hosts/<newhost>.nft
# 2. 编辑放行端口（参考上面语法）
# 3. 校验 + 部署 + 确认
./scripts/validate.sh <newhost>
sudo ./scripts/deploy.sh deploy <newhost>
# 另一会话验证 → confirm
# 4. 提交
git add && git commit && git push
```

### 提交变更

```bash
git add -A
git commit -m "说明改了什么端口/哪台主机"
git push
```

## 关于 Tailscale 端口（已查证官方文档）

Tailscale 流量绝大多数是**出站**，OUTPUT accept 已全部覆盖，无需在入站规则里放行：
- TCP 443（协调服务器 + DERP 中继）
- TCP 80（协调服务器优先端口 / captive portal 检测，非必需）
- UDP 3478（STUN）
- UDP 41641（WireGuard 直连的源端口）

入站只需一个**可选**端口：**UDP 41641**——放行它可提升 P2P 直连概率、减少走 DERP 中继，不放行也能连（只是慢）。本机已放行。

### 远程接入端口（本机实测）

| 端口 | 协议 | 用途 | 绑定地址 |
|---|---|---|---|
| 60000-61000 | UDP | mosh（本机 mosh-server 实测监听 60000/60001） | 10.0.0.24 私网 |
| 61001-61020 | UDP | tsshd（rootshell Roam-tssh） | tailscale0 (100.85.129.58) |

这两个范围按你的要求已在 hosts/osaka-arm.nft 放行。注意：mosh/tsshd 实际绑在内网/tailnet 地址、不绑 0.0.0.0，公网本就不可达；放行是为确保 tailnet 内和内网路径畅通。如后续不再用 mosh/tssh，删掉这两行重新部署即可。

参考：Tailscale 官方 KB 1082《What firewall ports should I open to use Tailscale?》。

## 常见问题

- **部署后 SSH 断了怎么办？** 30 分钟后自动回滚（systemd 定时器），或让旁边的人执行 `sudo ./scripts/deploy.sh rollback`。OCI 串行控制台也是兜底手段。
- **会不会影响 Docker 容器端口？** 不会。容器转发由 Docker 的 iptables 链管理，host_fw 的 FORWARD 是 accept，不拦截。端口映射（如本机 80/443）仍需 iptables 层的 docker-proxy 监听，这部分保持不变。
- **fail2ban 封禁会不会失效？** 不会。fail2ban 用独立的 `inet f2b-table`，deploy 只动 `inet host_fw`，不碰它。
- **为什么要独立 git、不放 dotfiles？** 防火墙配置变更频繁且需要单独追溯，与 dotfile 混在一起容易误提交；本仓库不含密钥，可用公开仓库。
- **ams 上旧的 rules.v4 混乱规则怎么办？** 本次先只加 host_fw 验证连通性；旧规则清理作为后续单独步骤（需备份）。在清理前，两套规则会同时作用于 INPUT hook，部署后务必验证 22/443 真正可达再 confirm。
