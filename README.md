# RackNerd Hysteria2 + WARP Installer

适用于 Debian/Ubuntu VPS 的 Hysteria2 + Cloudflare WARP 精简安装脚本。当前版本：`v1.1.1`。

## 主要功能

- 安装并配置 Hysteria2，默认监听 UDP `40000-42000`。
- 安装 Cloudflare 官方 WARP 客户端，并以本机 SOCKS5 Proxy 模式运行。
- Google、YouTube 等指定域名通过 WARP，其余流量保持服务器原生 IPv4 直连。
- 使用自签名 TLS 证书，并为兼容客户端生成 `pinSHA256` 证书指纹。
- 自动生成单端口、官方端口跳跃、PassWall2 `mport` 兼容和旧客户端兜底四种链接。
- 修改配置前自动备份，并在 Hysteria2 启动失败时恢复原配置。

## 一键安装

使用 root 登录 Debian/Ubuntu VPS，运行：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/dachun214-netizen/racknerd-hy2-warp-installer/main/racknerd-hy2-warp-installer.sh)
```

安装完成后查看节点：

```bash
cat /root/hy2-client-links.txt
```

官方 Hysteria2 客户端配置保存在：

```text
/root/hy2-client-config.yaml
```

以上两个文件均包含节点密码，默认权限为 `600`，请勿公开上传或转发。

## 节点备注

- `RN-CHI-HY2-Single-Port-Pinned`：单端口 + 证书指纹，优先推荐。
- `RN-CHI-HY2-Official-Port-Hop`：Hysteria2 官方端口跳跃格式。
- `RN-CHI-HY2-PassWall2-MPort-Hop`：部分 PassWall2/Clash 可识别的 `mport` 兼容格式。
- `RN-CHI-HY2-Legacy-No-Pin`：不支持证书指纹的旧客户端兜底链接。

## 可选参数

可以在命令前设置环境变量，例如修改端口范围：

```bash
HY2_PORT_START=41000 HY2_PORT_END=43000 bash <(curl -fsSL https://raw.githubusercontent.com/dachun214-netizen/racknerd-hy2-warp-installer/main/racknerd-hy2-warp-installer.sh)
```

常用变量：`HY2_PASSWORD`、`HY2_PORT_START`、`HY2_PORT_END`、`HY2_SNI`、`WARP_PROXY_PORT`、`DIRECT_MODE`、`FORCE_NEW_CERT`。

## 版本记录

### v1.1.1

- 节点备注改为明确、易区分的英文名称。
- 明确区分单端口、官方端口跳跃、PassWall2 `mport` 和 Legacy 链接。

### v1.1.0

- 增加 `pinSHA256` 证书指纹校验。
- 增加四种客户端链接和官方客户端 YAML。
- 加强备份、配置验证、文件权限和失败回滚。

### v1.0.0

- 初始版本：Hysteria2 + Cloudflare WARP Proxy。
- Google/YouTube 按域名分流到 WARP，其他流量直连。

## 注意事项

- 端口跳跃能否通过分享链接自动导入，取决于客户端或 PassWall2 的解析能力。
- `mport` 是部分客户端使用的兼容参数，不是 Hysteria2 官方统一 URI 格式。
- 脚本更新时建议固定具体 Git commit，确认变更后再用于生产服务器。
