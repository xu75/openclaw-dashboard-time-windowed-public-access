# openclaw-dashboard-time-windowed-public-access

安全地“临时”公网暴露 OpenClaw Dashboard：默认关闭、脚本开启、自动回收。

## Why

OpenClaw Dashboard 属于高权限管理面，长期公网暴露风险高（扫描、爆破、凭据泄露、未知漏洞命中）。  
本项目采用“时间窗暴露”模型：

- 默认 `CLOSED`（`deny all;`）
- 仅允许脚本临时 `OPEN`（最长 4 小时）
- 到时自动 `CLOSE`
- 叠加认证：`HTTPS + BasicAuth + OpenClaw Token`

## Scope

- 只通过 `443` 暴露 `https://<domain>/openclaw/`
- 上游固定代理到 `127.0.0.1:18789`
- `80` 仅做 `/openclaw/` -> HTTPS 跳转
- 不使用 IP 白名单
- 不在 Nginx 注入 OpenClaw token
- 不改动现有业务 location，采用独立 conf 接入

## Features

- `windowctl open --minutes N`（`1..240`，默认 `60`）
- `windowctl close` 立即收口
- `windowctl status` 输出 `OPEN/CLOSED` + 自动关闭任务信息
- 幂等操作（重复执行不会破坏状态）
- `flock` 并发锁防冲突
- `open/close` 前后都 `nginx -t`，通过后 `reload`
- 自动回收优先 `systemd-run --on-active=<Nm>`，失败回退 `nohup + sleep`
- 审计日志（`logger`，记录谁在何时 open/close）

## Threat Model

防护目标：

- 减少管理面暴露时间
- 降低持续扫描命中概率
- 增加未授权访问门槛（BasicAuth + Token）

不覆盖：

- 0day 漏洞本身
- 弱口令/凭据泄露导致的账户接管
- 主机已失陷后的横向移动

## Requirements

- Linux（推荐 systemd 环境）
- Nginx
- OpenClaw Dashboard 本地监听：`127.0.0.1:18789`
- 可用 TLS 证书与私钥文件
- root/sudo 权限

## Repo Layout

- `scripts/bootstrap.sh`
- `scripts/windowctl.sh`
- `scripts/uninstall.sh`
- `templates/nginx-openclaw.conf.tpl`
- `templates/window.conf.closed`
- `templates/window.conf.open`
- `tests/smoke.sh`
- `.github/workflows/shellcheck.yml`

## Quick Start

1. 初始化部署（一次性）：

```bash
sudo ./scripts/bootstrap.sh \
  --domain <DOMAIN_PLACEHOLDER> \
  --cert <SSL_CERT_PATH_PLACEHOLDER> \
  --key <SSL_KEY_PATH_PLACEHOLDER> \
  --basic-user <BASIC_USER_PLACEHOLDER>
```

2. 查看状态（默认应为 `CLOSED`）：

```bash
sudo /usr/local/sbin/openclaw-windowctl status
```

3. 临时开放 10 分钟：

```bash
sudo /usr/local/sbin/openclaw-windowctl open --minutes 10
```

4. 立即关闭：

```bash
sudo /usr/local/sbin/openclaw-windowctl close
```

### No Domain Fallback

如果当前没有可用公网域名，可以先用隔离主机名 `openclaw.local` + 自签证书部署（不影响现有 `server_name _` 业务）：

```bash
sudo mkdir -p /etc/nginx/openclaw/tls
sudo openssl req -x509 -nodes -newkey rsa:2048 -days 365 \
  -subj "/CN=openclaw.local" \
  -keyout /etc/nginx/openclaw/tls/openclaw.local.key \
  -out /etc/nginx/openclaw/tls/openclaw.local.crt

sudo BASIC_PASS='<BASIC_PASS_PLACEHOLDER>' bash ./scripts/bootstrap.sh \
  --domain openclaw.local \
  --cert /etc/nginx/openclaw/tls/openclaw.local.crt \
  --key /etc/nginx/openclaw/tls/openclaw.local.key \
  --basic-user <BASIC_USER_PLACEHOLDER>
```

访问端临时加 hosts：

```text
<SERVER_IP_PLACEHOLDER> openclaw.local
```

## Validation / Acceptance

1. 部署后初始状态必须是 `CLOSED`：

```bash
sudo /usr/local/sbin/openclaw-windowctl status
curl -k -I https://<DOMAIN_PLACEHOLDER>/openclaw/
```

预期：`STATE=CLOSED`，请求被拒绝（典型 `403`）。

2. `open --minutes 10` 后：

```bash
sudo /usr/local/sbin/openclaw-windowctl open --minutes 10
curl -k -I https://<DOMAIN_PLACEHOLDER>/openclaw/
```

预期：未带 BasicAuth 为 `401`；带 BasicAuth 后进入 OpenClaw，再进行 OpenClaw token 登录。

3. 10 分钟后自动恢复 `CLOSED`：

```bash
sudo /usr/local/sbin/openclaw-windowctl status
```

4. 参数边界：

```bash
sudo /usr/local/sbin/openclaw-windowctl open --minutes 241
```

预期：报错退出（非 0）。

5. 业务隔离：
- 仅新增独立 conf，其他业务路由不受影响。

## Rollback

快速封禁入口（推荐）：

```bash
sudo /usr/local/sbin/openclaw-windowctl close
```

卸载接入（移除 conf 与控制脚本）：

```bash
sudo ./scripts/uninstall.sh
```

## Failure Scenarios

- `nginx -t` 失败：先修复证书路径、模板渲染或 include 路径，再重试。
- `open` 后无自动回收：检查 `status` 输出的自动任务信息与系统日志。
- `systemd-run` 不可用：脚本会自动降级到 `nohup + sleep`。
- BasicAuth 通过但页面异常：排查本机 `127.0.0.1:18789` 上游服务状态。

## Audit

查看审计日志：

```bash
journalctl -t openclaw-windowctl --since "1 day ago"
```

## Security Notice

- 本仓库不包含真实域名、证书、私钥、token、账号或 IP。
- 所有敏感信息必须在部署时以占位符替换并通过安全渠道注入。
