# profiles/ — 按角色区分的策略片段（预留）

当前六台都是 Docker 代理主机，角色一致，暂不需要 profile 区分，规则全放 common + hosts 即可。

未来若出现不同角色，可在此放可复用片段，由 render.sh 按需内联：
- `standard.nft`：无容器的普通 VPS（FORWARD 可改 drop）
- `docker.nft`：Docker 主机（FORWARD accept，当前默认）
- `proxy.nft`：代理/网关主机
- `router.nft`：Tailscale subnet router / exit node（需明确转发 + NAT 规则）

使用方式：在对应 `hosts/<host>.nft` 的注释里声明角色，render 时把对应 profile 片段内联进相应链。当前 render.sh 尚未启用 profile 内联，需要时再扩展。
