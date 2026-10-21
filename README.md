# Kiro SNI Proxy over AWS PrivateLink 方案文档

> 📅 2026-04-26 · 作者：王骁

**版本**：v1.0
**状态**：✅ 已部署验证通过

---

## 1. 背景与目标

### 1.1 背景

Kiro 客户端底层依赖 Amazon Q Developer / CodeWhisperer 服务，这些服务的 API 端点部署在海外 AWS Region。企业在中国的团队成员由于网络环境限制，直连海外端点不稳定甚至不可达，需要通过一个固定的海外出口 IP 来稳定访问 Kiro 服务。

### 1.2 目标

- 为中国团队提供稳定的海外出口 IP，确保 Kiro 正常可用
- **不使用** Site-to-Site VPN、Client VPN、SD-WAN 等传统方案
- **不改造** Kiro 客户端本身（不破坏 TLS、不改源码）
- 支持 40 人团队并发使用
- 员工在**公司网络**和**个人家庭网络**下都可使用（无需额外 VPN）

---

## 2. 方案架构

### 2.1 整体拓扑

![Kiro SNI Proxy 架构图](https://raw.githubusercontent.com/kasimxiao/kiro-sni-proxy/main/assets/kiro-sni-proxy.png)

---

## 3. 已部署资源清单

**账号**：<ACCOUNT_ID> | **Region**：us-east-1

### 3.1 新建资源

| 类型 | ID | 用途 |
|------|------|------|
| EC2 | `<EC2_INSTANCE_ID>` | SNI 代理服务器 (**c6g.large**, Ubuntu 24.04 arm64) |
| EIP | `<EIP>` (<EIP_ALLOC_ID>) | 固定公网 IP |
| Security Group | `<EC2_SG_ID>` | 入站：443 全开（待收紧）、22 限制 <ADMIN_SSH_IP>/32 |

### 3.2 复用现有资源

| 类型 | ID | 说明 |
|------|------|------|
| VPC | `<VPC_ID>` (test-vpc, 10.0.0.0/16) | 已有公私分离架构 |
| Public Subnet | `<PUBLIC_SUBNET_ID>` (10.0.1.0/24, us-east-1a) | EC2 所在 |
| IGW | `<IGW_ID>` | |
| Public RT | `<PUBLIC_RT_ID>` | 已关联 public subnet |
| VPCE - q | `<VPCE_Q_ID>` | Private DNS 已开 |
| VPCE - codewhisperer | `<VPCE_CODEWHISPERER_ID>` | Private DNS 已开 |
| Endpoint SG | `<VPCE_SG_ID>` | 已允许 10.0.0.0/16 访问 443 |

---

## 4. EC2 配置详解

> 💡 **自动化部署**：本节的全部配置（网络、安全组、VPCE、EC2 + nginx SNI 透传、EIP）已封装为一键脚本，见 [`deploy/`](./deploy/) 目录。支持复用已有 VPC/子网或自动新建，`config.env` 一处配置后执行 `./deploy.sh` 即可，`./cleanup.sh` 精确回收。下文为手工配置详解与原理说明。

### 4.1 操作系统

- **OS**：Ubuntu 24.04 LTS (Noble Numbat)
- **架构**：arm64 (Graviton c6g.large)
- **AMI**：`<AMI_ID>`
- **IMDSv2**：强制

### 4.2 已装软件

```bash
apt-get install -y nginx libnginx-mod-stream dnsutils
```

### 4.3 nginx 配置 `/etc/nginx/nginx.conf`

```nginx
user www-data;
worker_processes auto;
worker_rlimit_nofile 65535;
pid /run/nginx.pid;
include /etc/nginx/modules-enabled/*.conf;  # 关键：加载 stream 模块

events {
    worker_connections 16384;
    multi_accept on;
    use epoll;
}

stream {
    # SNI 白名单：只转发 Kiro 相关域名
    map $ssl_preread_server_name $backend {
        codewhisperer.us-east-1.amazonaws.com  $ssl_preread_server_name:443;
        q.us-east-1.amazonaws.com              $ssl_preread_server_name:443;
        cli.kiro.dev                           $ssl_preread_server_name:443;  # Kiro CLI 新增
        runtime.us-east-1.kiro.dev             $ssl_preread_server_name:443;  # Kiro CLI 新增
        management.us-east-1.kiro.dev          $ssl_preread_server_name:443;  # Kiro CLI 新增
        default                                "";   # 其他域名直接拒绝
    }

    # VPC DNS：解析 Kiro 域名 → VPCE 私网 IP（走 PrivateLink 核心）
    # 注：*.kiro.dev 无对应 VPCE，169.254.169.253 自动回落到公网 DNS，走公网路径（参见 §8.3 机制）
    resolver 169.254.169.253 valid=30s ipv6=off;
    resolver_timeout 5s;

    # 连接级日志（每个 TCP 连接关闭时写一条）
    log_format sni '$remote_addr [$time_local] sni="$ssl_preread_server_name" '
                   'backend="$backend" status=$status sent=$bytes_sent recv=$bytes_received '
                   'duration=$session_time';
    access_log /var/log/nginx/sni.log sni buffer=64k flush=5s;
    error_log  /var/log/nginx/sni_error.log warn;

    tcp_nodelay on;

    server {
        listen 443 reuseport;            # reuseport 关键优化：多核并行 accept
        proxy_pass $backend;
        ssl_preread on;
        proxy_connect_timeout 10s;
        proxy_timeout 600s;
        proxy_socket_keepalive on;
    }
}

http {
    server {
        listen 80 default_server;
        return 404;   # 不开 HTTP 服务
    }
}
```

---

## 5. 客户端配置（本机）

### 5.1 修改 hosts

**macOS / Linux**：

```bash
sudo tee -a /etc/hosts <<EOF
<EIP>  codewhisperer.us-east-1.amazonaws.com
<EIP>  q.us-east-1.amazonaws.com
<EIP>  cli.kiro.dev
<EIP>  runtime.us-east-1.kiro.dev
<EIP>  management.us-east-1.kiro.dev
EOF

# macOS 清 DNS 缓存
sudo dscacheutil -flushcache && sudo killall -HUP mDNSResponder
```

**Windows**（管理员）：
编辑 `C:\Windows\System32\drivers\etc\hosts` 添加：

```
<EIP>  codewhisperer.us-east-1.amazonaws.com
<EIP>  q.us-east-1.amazonaws.com
<EIP>  cli.kiro.dev
<EIP>  runtime.us-east-1.kiro.dev
<EIP>  management.us-east-1.kiro.dev
```

然后 `ipconfig /flushdns`

### 5.2 完全隔离互联网（仅专线接入 AWS）场景：额外登录/SSO 域名

> ⚠️ **仅适用于「客户端网络完全禁止访问互联网、只通过专线（Direct Connect / VPN）接入 AWS」的客户。** 常规网络环境（客户端能正常出公网）**不需要**本节配置——登录/SSO 认证会走浏览器的公网路径自动完成。

#### 5.2.1 为什么需要

前面 §4.3、§5.1 只覆盖了 Kiro **运行时**（对话推理）流量。但 Kiro 首次**登录**依赖 AWS IAM Identity Center（SSO）+ OIDC 设备授权流程，这套认证会访问一批 `*.aws` / `*.awsapps.com` / `*.sso.amazonaws.com` 域名。

- 常规环境：客户端能出公网，登录页在浏览器里直接打开，认证流量走本地公网，**无需经过代理**。
- **完全隔离环境**：客户端**任何**出网都被掐断，连登录认证都到不了 AWS，Kiro 会卡在登录环节（拿不到 token）。此时必须把这些**认证域名也纳入 SNI 代理白名单 + 客户端 hosts**，让登录流量同样经代理出口。

> 前提：**代理 EC2 本身能出公网**（本方案 EC2 在 public subnet + IGW + EIP，满足条件）。客户端被隔离、代理不被隔离，正是本方案成立的基础。

#### 5.2.2 需要增加的域名

| 域名 | 用途 |
|------|------|
| `app.kiro.dev` | Kiro 登录门户 / 客户端授权入口 |
| `us-east-1.signin.aws` | AWS 登录端点 |
| `us-east-1.signin.aws.amazon.com` | AWS 登录端点 |
| `<idc-directory-id-or-alias>.awsapps.com` | IAM Identity Center 访问门户（**客户专属**，替换为你的 Identity Center 目录 ID 或别名，如 `d-1234567890.awsapps.com`） |
| `portal.sso.us-east-1.amazonaws.com` | SSO 访问门户 API |
| `assets.sso-portal.us-east-1.amazonaws.com` | SSO 门户静态资源 |
| `oidc.us-east-1.amazonaws.com` | SSO OIDC token 端点（设备授权流程发放 token） |

此外，若需在隔离环境内**安装 / 更新 Kiro 插件**，还需放行插件市场及其依赖域名（不装插件可省略）：

| 域名 | 用途 |
|------|------|
| `open-vsx.org` | 插件市场（Open VSX Registry） |
| `openvsx.eclipsecontent.org` | 插件市场 CDN（插件包下载） |
| `github.com` | 部分插件安装时拉取的依赖 |
| `raw.githubusercontent.com` | 部分插件安装时拉取的依赖 |

#### 5.2.3 nginx 白名单（在 §4.3 的 `map` 中追加）

```nginx
map $ssl_preread_server_name $backend {
    codewhisperer.us-east-1.amazonaws.com     $ssl_preread_server_name:443;
    q.us-east-1.amazonaws.com                 $ssl_preread_server_name:443;
    cli.kiro.dev                              $ssl_preread_server_name:443;
    runtime.us-east-1.kiro.dev                $ssl_preread_server_name:443;
    management.us-east-1.kiro.dev             $ssl_preread_server_name:443;

    # ↓↓↓ 完全隔离场景：登录 / SSO 认证域名 ↓↓↓
    app.kiro.dev                              $ssl_preread_server_name:443;
    us-east-1.signin.aws                      $ssl_preread_server_name:443;
    us-east-1.signin.aws.amazon.com           $ssl_preread_server_name:443;
    portal.sso.us-east-1.amazonaws.com        $ssl_preread_server_name:443;
    assets.sso-portal.us-east-1.amazonaws.com $ssl_preread_server_name:443;
    oidc.us-east-1.amazonaws.com              $ssl_preread_server_name:443;
    # IAM Identity Center 门户（客户专属，替换为实际目录 ID/别名）
    ~^[a-z0-9-]+\.awsapps\.com$               $ssl_preread_server_name:443;

    # ↓↓↓ 插件市场及依赖（隔离环境内需安装/更新插件时才需要）↓↓↓
    open-vsx.org                              $ssl_preread_server_name:443;
    openvsx.eclipsecontent.org                $ssl_preread_server_name:443;
    github.com                                $ssl_preread_server_name:443;
    raw.githubusercontent.com                 $ssl_preread_server_name:443;

    default                                   "";
}
```

> 说明：`*.awsapps.com` 用正则匹配是因为其前缀为客户 Identity Center 目录 ID/别名，因客户而异；若想收紧，可改成精确域名 `d-xxxxxxxxxx.awsapps.com $ssl_preread_server_name:443;`。改完执行 `sudo nginx -t && sudo systemctl reload nginx`。

> DNS 解析：这些认证域名多数**没有对应 VPCE**，按 §8.3 的机制，`resolver 169.254.169.253` 会自动回落到公网 DNS 返回真实公网 IP，代理照常透传，nginx 无需其它改动。

#### 5.2.4 客户端 hosts（在 §5.1 基础上追加）

> 🔑 **关键区别：本节 hosts 指向的是 EC2 的私有 IP `<EC2_PRIVATE_IP>`，不是公网 EIP。** 完全隔离环境下客户端通过专线（Direct Connect / VPN）以私网路径到达 EC2 的 ENI，根本够不到公网 EIP。这与 §5.1 常规场景（客户端走公网、指向 EIP）正好相反。请确保：
> - 客户端所在网络的路由 + 专线能到达 EC2 所在 VPC 网段（如 `10.0.0.0/16`）；
> - EC2 安全组放行来自客户端网段的 443 入站。

**macOS / Linux**：

```bash
sudo tee -a /etc/hosts <<EOF
<EC2_PRIVATE_IP>  app.kiro.dev
<EC2_PRIVATE_IP>  us-east-1.signin.aws
<EC2_PRIVATE_IP>  us-east-1.signin.aws.amazon.com
<EC2_PRIVATE_IP>  <idc-directory-id-or-alias>.awsapps.com
<EC2_PRIVATE_IP>  portal.sso.us-east-1.amazonaws.com
<EC2_PRIVATE_IP>  assets.sso-portal.us-east-1.amazonaws.com
<EC2_PRIVATE_IP>  oidc.us-east-1.amazonaws.com
# 插件市场及依赖（需在隔离环境内安装/更新插件时才需要）
<EC2_PRIVATE_IP>  open-vsx.org
<EC2_PRIVATE_IP>  openvsx.eclipsecontent.org
<EC2_PRIVATE_IP>  github.com
<EC2_PRIVATE_IP>  raw.githubusercontent.com
EOF

sudo dscacheutil -flushcache && sudo killall -HUP mDNSResponder
```

**Windows**（管理员，编辑 `C:\Windows\System32\drivers\etc\hosts`）：

```
<EC2_PRIVATE_IP>  app.kiro.dev
<EC2_PRIVATE_IP>  us-east-1.signin.aws
<EC2_PRIVATE_IP>  us-east-1.signin.aws.amazon.com
<EC2_PRIVATE_IP>  <idc-directory-id-or-alias>.awsapps.com
<EC2_PRIVATE_IP>  portal.sso.us-east-1.amazonaws.com
<EC2_PRIVATE_IP>  assets.sso-portal.us-east-1.amazonaws.com
<EC2_PRIVATE_IP>  oidc.us-east-1.amazonaws.com
# 插件市场及依赖（需在隔离环境内安装/更新插件时才需要）
<EC2_PRIVATE_IP>  open-vsx.org
<EC2_PRIVATE_IP>  openvsx.eclipsecontent.org
<EC2_PRIVATE_IP>  github.com
<EC2_PRIVATE_IP>  raw.githubusercontent.com
```

然后 `ipconfig /flushdns`。

> 注意 `<idc-directory-id-or-alias>.awsapps.com` 这行：hosts 不支持通配符，必须写成客户实际的门户域名（如 `d-1234567890.awsapps.com` 或自定义别名 `mycompany.awsapps.com`）。
>
> 提示：完全隔离场景下，§5.1 里运行时域名（codewhisperer / q / *.kiro.dev 等）的 hosts 同样应指向 `<EC2_PRIVATE_IP>` 而非 EIP，否则客户端仍然连不上代理。

### 5.3 验证 hosts 生效

```bash
# ✅ 正确方式（读 hosts）
getent hosts codewhisperer.us-east-1.amazonaws.com
# 应输出：<EIP>  codewhisperer.us-east-1.amazonaws.com

# ✅ 或用 curl
curl -v https://codewhisperer.us-east-1.amazonaws.com/ 2>&1 | grep Connected
# 应输出：Connected to codewhisperer.us-east-1.amazonaws.com (<EIP>)

# ❌ 错误方式：dig 不读 hosts！
# dig 会直接查 DNS 服务器，结果不代表实际流量去向
```

---

## 6. 验证流程

### Step 1：Kiro 实际工作

本机打开 Kiro，登录并发送一条消息 → 正常对话即成功。

### Step 2：服务端日志确认

```bash
# EC2 上
aws ssm start-session --target <EC2_INSTANCE_ID>
sudo tail -f /var/log/nginx/sni.log
```

应看到你本机 IP 的请求，形如：

```
<你的IP> [时间] sni="q.us-east-1.amazonaws.com" backend="q.us-east-1.amazonaws.com:443" status=200 sent=11080 recv=2195 duration=61.6
```

### Step 3：反证（最硬证据）

停掉代理，Kiro 必然挂：

```bash
# 停
aws ssm send-command --region us-east-1 --instance-ids <EC2_INSTANCE_ID> \
  --document-name "AWS-RunShellScript" \
  --parameters 'commands=["systemctl stop nginx"]'

# 此时 Kiro 发消息会 timeout

# 恢复
aws ssm send-command --region us-east-1 --instance-ids <EC2_INSTANCE_ID> \
  --document-name "AWS-RunShellScript" \
  --parameters 'commands=["systemctl start nginx"]'
```

---

## 7. 成本估算

### 7.1 完整月成本（40 人团队，us-east-1）

| 项目 | 规格 | 单价 | 月成本 |
|------|------|------|--------|
| EC2 c6g.large | 2vCPU 4GB Graviton2 on-demand | \$0.068/h | \$49.64 |
| EBS gp3 | 8 GB | \$0.08/GB·月 | \$0.64 |
| EIP（绑定中） | 1 个（2024-02 起收费） | \$0.005/h | \$3.65 |
| VPCE - q | Interface Endpoint × 1 AZ | \$0.01/h/AZ | \$7.30 |
| VPCE - codewhisperer | Interface Endpoint × 1 AZ | \$0.01/h/AZ | \$7.30 |
| VPCE 数据处理 | 前 1 PB | \$0.01/GB | ~\$0.10 - \$1.00 |
| 流量（EIP 出站） | 预估 5-20 GB/月 | \$0.09/GB | ~\$0.45 - \$1.80 |
| **合计** | | | **≈ \$69 - \$71 / 月** |

### 7.2 关键成本说明

- **EIP**：2024-02-01 起 AWS 对所有 EIP 收费，不管是否绑定。无法避免。
- **VPCE 按 AZ 收费**：每个 Interface Endpoint 每 AZ \$0.01/h。当前两个 VPCE 都只在 us-east-1a，如果扩展到多 AZ（HA 场景）每多一个 AZ 再加 \$7.30。
- **数据处理费**：PrivateLink 每 GB \$0.01，Kiro 对话流量不大，40 人每月预估不超过 \$1。
- **VPCE 是固定成本**：不管有没有代理，只要 VPCE 存在就收钱。如果本来就在用 PrivateLink，这部分是沉没成本，代理方案没有额外增加。

---

## 8. 后续扩展方向

### 8.1 多域名支持

如果 Kiro 后续加新域名，在 nginx `map` 里加一行即可：

```nginx
map $ssl_preread_server_name $backend {
    codewhisperer.us-east-1.amazonaws.com  $ssl_preread_server_name:443;
    q.us-east-1.amazonaws.com              $ssl_preread_server_name:443;
    new-domain.amazonaws.com               $ssl_preread_server_name:443;  # 新增
    default                                "";
}
```

### 8.2 高可用

- EC2 换成 ASG + NLB（NLB 也支持 TCP 透传，和 SNI 代理配合无障碍）
- 成本翻倍，按需取舍

### 8.3 架构变体：无 PrivateLink 版

本方案 SNI 代理本身即可工作，**不强依赖 PrivateLink**。降级路径极简：只需**删除两个 VPCE**，nginx 配置零改动。

```bash
aws ec2 delete-vpc-endpoints --region us-east-1 \
  --vpc-endpoint-ids <VPCE_Q_ID> <VPCE_CODEWHISPERER_ID>
```

#### 为什么 nginx 不用改（关键机制）

理解这个机制需先说清楚 `resolver 169.254.169.253` 这个地址是什么。

**`169.254.169.253` 是 AWS VPC 内置 DNS 解析器**的固定地址（AWS 文档称为 *Amazon-provided DNS server* / *Route 53 Resolver*）：

- 属于 `169.254.0.0/16` link-local 段，只在 VPC 内部可访问
- 每个 VPC 自动拥有，无需配置
- 功能：同时应答两类查询
  1. **公网域名** → 转发到 AWS 公共 DNS，返回公网 IP
  2. **启用了 Private DNS 的 Interface VPCE 对应域名** → 返回 VPCE ENI 的私网 IP（这是 PrivateLink 的核心）
- `/etc/resolv.conf` 默认指向这里，EC2 所有域名解析默认走它

**行为对比**：对同一个域名 `q.us-east-1.amazonaws.com`，169.254.169.253 的返回值会随 VPCE 存不存在而变：

| VPCE 状态 | 169.254.169.253 返回 | nginx 实际连到 |
|-----------|---------------------|---------------|
| 存在（Private DNS on） | `10.0.11.177`（VPCE 私网 IP） | AWS 骨干网 |
| **已删除** | **`98.84.x.x / 34.199.x.x / 100.52.x.x` 等**（Kiro 真实公网 IP） | 公网 |

这就是为什么删 VPCE 后 nginx 配置无需修改：**VPC DNS 失去 Private DNS 记录后自动回落到公网解析**，resolver 拿到的就是官方公网 IP，nginx 透传逻辑不感知这个变化。

> 极少数场景你可能想强制走公网 DNS（如调试），可把 resolver 改成 `8.8.8.8` 或 `1.1.1.1`。但常规降级不需要，保留 `169.254.169.253` 反而更健壮（不依赖外部 DNS 可用性，且保留将来重新开启 PrivateLink 的能力）。

#### 对比

| 维度 | 有 PrivateLink | 无 PrivateLink（仅删 VPCE） |
|------|---------------|---------------------------|
| 月成本 | ~\$70 | **~\$55**（省 2 个 VPCE \$14.60） |
| nginx 配置改动 | — | **0 行** |
| 数据路径 | EC2 → VPCE → AWS 骨干网 → Kiro | EC2 → 公网 → Kiro |
| 后端证书 CN | `*.codewhisperer.us-east-1.vpce.amazonaws.com` | `q.us-east-1.amazonaws.com`（Kiro 真实证书） |
| 合规（PCI / HIPAA / 企业内网安全） | ✅ 强 | ⚠️ 弱（数据绕公网） |
| 延迟 | 略低 | 略高（1-5 ms） |
| 架构复杂度 | 2 个 VPCE + Private DNS | 无 VPCE |
| 客户端行为 | 无差别 | 无差别 |
| SNI 白名单、日志、TLS 透传 | ✅ 保留 | ✅ 保留 |

#### 适用场景建议

- **选 PrivateLink**：金融 / 医疗 / 企业合规严格场景、已有 PrivateLink 预算、客户方案演示；PrivateLink 的价值是「数据不离开 AWS 骨干网」，这是合规价值，不是技术价值。
- **选无 PrivateLink**：个人 / 小团队 / 仅为统一出口 IP 审计，对内网严格隔离无硬性需求；每月省 ~\$15，架构更简洁。

已通过对照实验验证：删除两个 VPCE 后 nginx 无需重启 / 重载，当前正常连接的客户端无感切换到公网路径。

---

### 8.4 多网卡（多入口）

单台代理可以挂多块 ENI，同时从多个入口接收转发流量。

- **入站**：nginx 配置 `listen 443 reuseport;` 未指定 IP，等价于监听 `0.0.0.0:443`，所有网卡上的所有 IP 同时生效。客户端 hosts 指向哪个 EIP / 私有 IP，流量就从对应网卡进入。
- **自动化**：`deploy/config.env` 设置 `ENI_COUNT=2`（或更大）即可，脚本会在 `run-instances` 时内联声明多块 ENI，并为每块 ENI 各绑一个 EIP，`client-hosts.txt` 按网卡分组输出。
- **日志**：`log_format` 增加了 `to=$server_addr`，可以直接看出每条连接从哪块网卡进入。
- **路由**：Ubuntu 24.04 + cloud-init 会自动为第二块网卡生成策略路由（`from <eth1 IP> lookup 101`），同子网多网卡不需要手工配 `ip rule`。
- **限制**：多网卡不增加带宽（带宽取决于实例规格，不是 ENI 数量）；实例类型有 ENI 数量上限（c6g.large 为 3）；需要吞吐或高可用请用 §8.2 的 ASG + NLB。

#### 手动操作流程（给已有代理实例加网卡）

不使用 `deploy.sh`、或要给已部署的实例追加网卡时，按下面步骤操作。以下命令中的 `<...>` 需替换为实际值。

**Step 1：确认实例支持更多 ENI**

```bash
aws ec2 describe-instance-types --region us-east-1 --instance-types <INSTANCE_TYPE> \
  --query 'InstanceTypes[0].NetworkInfo.[MaximumNetworkInterfaces,Ipv4AddressesPerInterface]'
```

**Step 2：创建新 ENI**（子网必须与实例在同一可用区，安全组需放行客户端来源的 443）

```bash
aws ec2 create-network-interface --region us-east-1 \
  --subnet-id <SUBNET_ID> --groups <PROXY_SG_ID> \
  --description "kiro-sni-proxy eth1" \
  --query 'NetworkInterface.[NetworkInterfaceId,PrivateIpAddress]' --output text
```

**Step 3：挂载到实例**（`device-index` 主网卡为 0，新网卡从 1 开始）

```bash
aws ec2 attach-network-interface --region us-east-1 \
  --network-interface-id <ENI_ID> --instance-id <INSTANCE_ID> --device-index 1
```

如需实例终止时自动删除该 ENI：

```bash
aws ec2 modify-network-interface-attribute --region us-east-1 \
  --network-interface-id <ENI_ID> \
  --attachment AttachmentId=<ATTACHMENT_ID>,DeleteOnTermination=true
```

**Step 4：为新 ENI 绑定 EIP**（常规公网场景；专线 / 隔离场景可跳过，客户端直接用 ENI 私有 IP）

```bash
aws ec2 allocate-address --region us-east-1 --domain vpc --query AllocationId --output text
aws ec2 associate-address --region us-east-1 \
  --allocation-id <EIP_ALLOC_ID> --network-interface-id <ENI_ID>
```

**Step 5：确认系统已识别新网卡并配好策略路由**（通过 SSM 登录实例）

```bash
aws ssm start-session --target <INSTANCE_ID> --region us-east-1

ip -br addr          # 应看到 ens5、ens6 都有私有 IP
ip rule              # 应看到 from <eth1 私有IP> lookup 101
ip route show table 101
```

- 实例**启动时**就带多块 ENI（`deploy.sh` 的 `ENI_COUNT>1` 方式），Ubuntu 24.04 的 cloud-init 会自动生成这些配置，无需手工处理。
- 对**运行中热挂载**的 ENI，系统可能没有自动配置。此时最简单的办法是重启实例（`sudo reboot`）让 cloud-init 重新生成；不想重启则手工补策略路由（下面的 Step 6）。这一步我只验证了启动时带多块 ENI 的情况，热挂载场景未实测。

**Step 6（仅在 Step 5 缺少配置时）：手工配置策略路由**

原因：两块网卡在同一子网时，默认路由只经 eth0。发往 eth1 私有 IP 的请求，回包若仍走 eth0，源地址不匹配会被丢弃，所以需要让"源地址为 eth1 IP 的包"走 eth1 出去。

```bash
# 变量：按实际值替换
IF=ens6                     # 新网卡名（ip -br addr 查看）
IP=<ENI 私有 IP>            # 例：172.31.37.93
GW=<子网网关>               # 子网 CIDR 的第 1 个地址，例：172.31.32.1
CIDR=<子网 CIDR>            # 例：172.31.32.0/20

sudo ip route add default via $GW dev $IF table 101
sudo ip route add $CIDR dev $IF src $IP table 101
sudo ip rule add from $IP lookup 101
```

以上是临时生效（重启丢失）。持久化可写入 netplan，例如 `/etc/netplan/60-eth1.yaml`：

```yaml
network:
  version: 2
  ethernets:
    ens6:
      dhcp4: true
      dhcp4-overrides:
        use-routes: false
      routes:
        - to: 0.0.0.0/0
          via: <子网网关>
          table: 101
        - to: <子网 CIDR>
          scope: link
          table: 101
      routing-policy:
        - from: <ENI 私有 IP>
          table: 101
```

```bash
sudo netplan try      # 确认网络未中断后回车确认
```

**Step 7：nginx 无需任何改动**

`listen 443` 已监听所有网卡。如需在日志中区分入口，把 `/etc/nginx/nginx.conf` 的 `log_format` 加上 `to=$server_addr`：

```nginx
log_format sni '$remote_addr to=$server_addr [$time_local] sni="$ssl_preread_server_name" '
               'backend="$backend" status=$status sent=$bytes_sent recv=$bytes_received '
               'duration=$session_time';
```

```bash
sudo nginx -t && sudo systemctl reload nginx
```

如果需要**只在指定网卡上监听**，把 `listen 443 reuseport;` 改成按 IP 监听（每个 IP:端口组合各写一条 `listen`；`reuseport` 对同一个 IP:端口只需写一次）：

```nginx
server {
    listen 172.31.37.123:443 reuseport;
    listen 172.31.37.93:443 reuseport;
    ...
}
```

**Step 8：客户端 hosts**

每个客户端只选一个入口，按场景指向对应 IP：

- 公网用户 → 该网卡的 EIP
- 专线 / 隔离网络用户 → 该网卡的私有 IP（参见 §5.2.4）

**Step 9：验证**

对每个入口 IP 分别测试（`--resolve` 不依赖 hosts，可以在配置 hosts 之前直接测）：

```bash
curl -sk -m 15 -o /dev/null -w '%{http_code} %{remote_ip}\n' \
  --resolve q.us-east-1.amazonaws.com:443:<入口IP> https://q.us-east-1.amazonaws.com/
# 期望返回 404（q 服务对根路径的正常响应，说明已透传到真实后端）

# 白名单反证：非白名单域名应被拒绝（连接被关闭，curl 返回 000）
curl -sk -m 10 -o /dev/null -w '%{http_code}\n' \
  --resolve example.com:443:<入口IP> https://example.com/
```

在实例上确认两块网卡都有流量：

```bash
sudo tail -n 20 /var/log/nginx/sni.log
# 应能看到不同的 to=<私有IP>，且 status=200
```

**Step 10：回收（不再需要时）**

```bash
aws ec2 disassociate-address --region us-east-1 --association-id <EIP_ASSOC_ID>
aws ec2 release-address --region us-east-1 --allocation-id <EIP_ALLOC_ID>
aws ec2 detach-network-interface --region us-east-1 --attachment-id <ATTACHMENT_ID>
aws ec2 delete-network-interface --region us-east-1 --network-interface-id <ENI_ID>
```

> 排错提示：如果从公网访问某个 EIP 超时，先检查（1）安全组是否放行了你的**实际出口 IP**（公司网络出口 IP 可能轮换，且 curl 与浏览器的出口可能不同）；（2）Step 5 的策略路由是否存在；（3）`sudo ss -ltnp | grep 443` 确认 nginx 在监听。

实测（us-east-1，t4g.small，Ubuntu 24.04，2 块 ENI 各绑 1 个 EIP）：

| 测试 | 结果 |
|---|---|
| 访问 EIP-A:443，SNI = `q.us-east-1.amazonaws.com` | 透传成功，返回后端 HTTP 404 |
| 访问 EIP-B:443，SNI = `q.us-east-1.amazonaws.com` | 透传成功，返回后端 HTTP 404 |
| 访问 EIP-A:443，SNI = `example.com` | 白名单拒绝（backend 为空，status=500） |

服务端日志可见两个 `to=` 地址（两块网卡的私有 IP）各自出现 `status=200` 的转发记录。

#### 控制台操作流程（Web UI）

上面 Step 1-10 的等价控制台操作。适合不想装 AWS CLI、或习惯图形界面核对资源的场景。网卡挂载、EIP 绑定都能在控制台完成，但**策略路由（CLI Step 6）必须登录实例执行**，控制台侧用 Session Manager 进去操作。

> ⚠️ 两个最容易踩的坑，先记住：
> 1. 新 ENI 的子网**必须与实例同一可用区**，否则挂载时选不到该实例。
> 2. 绑 EIP 时「资源类型」要选 **网络接口**，选「实例」会绑到主网卡（eth0），等于白做。

**Step 1：确认实例类型的 ENI 上限**

EC2 控制台 → 左侧 **实例** → **实例类型** → 搜索你的实例类型（如 `c6g.large`）→ 查看 **网络接口** 和 **每个接口的 IPv4 地址数** 两列。

常见值参考：`c6g.large` = 3 块 ENI / 每块 10 个 IPv4；`t4g.small` = 3 块 / 每块 4 个。网卡数用满后只能换更大规格。

**Step 2：创建新 ENI**

EC2 控制台 → 左侧 **网络和安全** → **网络接口** → 右上 **创建网络接口**：

| 字段 | 填什么 |
|---|---|
| 描述 | `kiro-sni-proxy eth1`（便于识别） |
| 子网 | 与实例**同可用区**的子网 |
| 私有 IPv4 地址 | 自动分配 |
| 安全组 | 代理实例所用的那个 SG（需放行客户端来源的 443） |

点 **创建网络接口**，记下新 ENI 的 ID 和私有 IP。

**Step 3：挂载到实例**

两条路径任选其一：

- 网络接口列表 → 勾选新 ENI → **操作** → **附加** → 选择实例 → **附加**
- 或 EC2 → **实例** → 勾选实例 → **操作** → **网络** → **附加网络接口** → 选择新 ENI

控制台会自动分配下一个可用的设备索引（主网卡是 0，新网卡即 1），无需手填。

挂载完如果希望实例终止时自动删掉这块 ENI（避免残留计费）：网络接口列表 → 勾选该 ENI → **操作** → **更改终止行为** → 勾选 **终止时删除**。控制台单独创建的 ENI 默认是**不**随实例删除的。

**Step 4：分配并绑定 EIP**

> 常规公网场景需要；专线 / 隔离场景可跳过，客户端直接用 ENI 私有 IP（见 §5.2.4）。每个 EIP 约 \$3.65/月。

1. EC2 → **网络和安全** → **弹性 IP** → **分配弹性 IP 地址** → 直接 **分配**
2. 勾选刚分配的 EIP → **操作** → **关联弹性 IP 地址**
3. 关键填法：
   - **资源类型** → 选 **网络接口**（⚠️ 不要选「实例」）
   - **网络接口** → 选 Step 2 创建的 ENI
   - **私有 IP 地址** → 选该 ENI 的私有 IP
4. 点 **关联**

**Step 5：配置策略路由（必须登录实例）**

控制台挂载 ENI 属于**运行中热挂载**，cloud-init 不会重新跑，系统大概率没有自动生成策略路由 —— 此时从新 EIP 访问会超时。两种处理方式：

- **省事**：重启实例让 cloud-init 重新生成配置。EC2 → 勾选实例 → **实例状态** → **重启实例**。
- **不重启**：按下面方式手工补。

进入实例：Systems Manager 控制台 → **会话管理器** → **启动会话** → 选中实例 → **启动会话**（浏览器里直接拿到 shell，不需要开 22 端口）。

先检查是否已自动配好：

```bash
ip -br addr            # 应看到 ens5、ens6 都有私有 IP
ip rule                # 看是否有 from <eth1 私有IP> lookup 101
```

若 `ip rule` 里没有对应条目，按上面 **CLI Step 6** 的命令补上策略路由，并用同一节的 netplan 写法持久化（否则重启丢失）。

也可以不开会话、用 Run Command 批量下发：Systems Manager → **Run Command** → **运行命令** → 文档选 `AWS-RunShellScript` → 目标选实例 → 命令框粘贴 Step 6 的命令。

**Step 6：nginx 无需改动**

`listen 443` 已覆盖所有网卡，不用动配置。若想在日志里区分入口，按 CLI Step 7 给 `log_format` 加 `to=$server_addr`。

**Step 7：客户端 hosts 与验证**

hosts 指向规则同 CLI Step 8（公网用户 → EIP，专线用户 → 私有 IP）。验证建议用 `--resolve` 直接打每个入口，不依赖 hosts：

```bash
curl -sk -m 15 -o /dev/null -w '%{http_code}\n' \
  --resolve q.us-east-1.amazonaws.com:443:<新EIP> https://q.us-east-1.amazonaws.com/
# 期望 404（后端正常响应，说明透传成功）
```

返回 `000` 说明没打通，依次检查：安全组是否放行你的实际出口 IP、Step 5 的策略路由是否存在、`sudo ss -ltnp | grep 443` 确认 nginx 在监听。

**Step 8：回收**

按顺序操作，跳步会因依赖关系失败：

1. **弹性 IP** → 勾选 → **操作** → **取消关联弹性 IP 地址**
2. 同一页 → **操作** → **释放弹性 IP 地址**（不释放会一直计费）
3. **网络接口** → 勾选 → **操作** → **分离**，等状态变为 `available`
4. **网络接口** → 勾选 → **操作** → **删除**

#### 控制台 / CLI 操作对照

| 操作 | 控制台位置 | CLI |
|---|---|---|
| 查 ENI 上限 | EC2 → 实例类型 | `describe-instance-types` |
| 创建 ENI | EC2 → 网络接口 → 创建 | `create-network-interface` |
| 挂载 ENI | 网络接口 → 操作 → 附加 | `attach-network-interface` |
| 终止时删除 | 网络接口 → 操作 → 更改终止行为 | `modify-network-interface-attribute` |
| 分配 EIP | EC2 → 弹性 IP → 分配 | `allocate-address` |
| 绑定 EIP 到 ENI | 弹性 IP → 操作 → 关联（资源类型选**网络接口**） | `associate-address --network-interface-id` |
| 登录实例 | Systems Manager → 会话管理器 | `ssm start-session` |
| 批量下发命令 | Systems Manager → Run Command | `ssm send-command` |

## 9. 方案局限

| 局限 | 影响 | 缓解建议 |
|------|------|----------|
| 单点故障（EC2） | nginx 挂了 Kiro 就断 | EC2 换成 ASG + NLB（NLB 支持 TCP 透传，和 SNI 代理无障碍） |
| **单 AZ 部署风险** | 当前 VPCE 和 EC2 都在 us-east-1a。AZ 级故障时整套失效 | **生产建议至少 2 AZ**：VPCE 各加一个子网 + EC2 在另一 AZ 起一台 + NLB 平衡 |
| EC2 维护 | 需打补丁、升级 nginx | SSM Patch Manager 自动化 |
| 单 Region | 只支持 us-east-1 | 按 region 部署多套，hosts 分别指向 |
| 不加密控制面 | SNI 明文，理论上能看到访问哪个域名（但内容仍加密） | 可接受；如需进一步隐蔽可考虑 Outbound Resolver + Resolver Endpoint |
| 依赖 VPCE Private DNS | 关掉 DNS 方案失效 | 配置 lock + IAM 保护 |

---

## 10. 参考资料

- [AWS PrivateLink for Amazon Q Developer](https://docs.aws.amazon.com/amazonq/latest/qdeveloper-ug/vpc-endpoints.html)
- [Kiro and interface endpoints (AWS PrivateLink)](https://kiro.dev/docs/privacy-and-security/vpc-endpoints/)
- [nginx stream_ssl_preread_module](https://nginx.org/en/docs/stream/ngx_stream_ssl_preread_module.html)
- [TLS SNI 扩展 (RFC 6066)](https://www.rfc-editor.org/rfc/rfc6066#section-3)
