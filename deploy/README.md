# Kiro SNI Proxy 自动化部署

基于 [kasimxiao/kiro-sni-proxy](https://github.com/kasimxiao/kiro-sni-proxy) 方案第 4 点（EC2 + nginx `stream` SNI 透传）的一键部署脚本。

用 AWS CLI 编排完整栈：网络 → 安全组 → PrivateLink(VPCE) → SSM 角色 → EC2(user-data 自动装 nginx 并写入第4点配置) → EIP。

## 依赖
- AWS CLI v2（已 `aws configure` 或配置好环境变量凭证）
- `jq`

## 使用

```bash
cd kiro-sni-proxy-deploy
chmod +x deploy.sh cleanup.sh

# 1) 编辑配置
vi config.env

# 2) 部署
./deploy.sh

# 3) 清理（仅删除本次创建的资源，复用的 VPC 不动）
./cleanup.sh
```

## 网络两种模式（config.env）

| 模式 | 配置 | 行为 |
|------|------|------|
| **复用已有 VPC/子网** | 填 `EXISTING_VPC_ID` + `EXISTING_SUBNET_ID`（须为公网子网） | 直接在已有网络里创建代理 |
| **新建 VPC/子网** | 两项都留空，用 `NEW_VPC_CIDR` / `NEW_SUBNET_CIDR` | 自动建 VPC/子网/IGW/路由表 |

> 两项必须同时填写或同时留空，否则脚本报错退出。

## 关键开关

- `ENABLE_PRIVATELINK`：`true` 创建 q + codewhisperer 两个 VPCE（走 AWS 骨干网）；`false` 省钱，nginx 零改动，DNS 回落公网。
- `INGRESS_443_CIDR`：常规场景客户端走公网连 EIP，默认 `0.0.0.0/0`。
- `ADMIN_SSH_CIDR`：留空则不开 22（推荐用 SSM 登录）。
- `SNI_DOMAINS`：nginx 白名单域名。默认 Kiro 运行时 5 域名；完全隔离场景追加认证域名。
- `INSTANCE_TYPE` / `INSTANCE_ARCH`：默认 `c6g.large` / `arm64`。
- `ENI_COUNT`：实例网卡数量（含主网卡），默认 `1`，行为与原版一致。`>1` 时在同一子网挂多块 ENI，**每块各绑一个 EIP**；脚本会按实例类型的 ENI 上限做校验。`client-hosts.txt` 会为每块网卡生成一组 hosts，**每个客户端只选其中一组**。多网卡不增加带宽，用途是按入口区分客户端（如公网 / 专线分流、多出口 IP）；nginx 日志中的 `to=` 字段标明流量从哪块网卡进入。

## 部署产物
- `client-hosts.txt`：客户端 hosts 片段（域名 → EIP），直接追加到本地 hosts。
- `.deploy-state.env`：本次创建的资源清单，供 `cleanup.sh` 精确回收。

## 部署后验证
```bash
# 客户端刷新 DNS 后
getent hosts codewhisperer.us-east-1.amazonaws.com
curl -v https://codewhisperer.us-east-1.amazonaws.com/ 2>&1 | grep Connected

# 服务端日志（无需 22 端口）
aws ssm start-session --target <INSTANCE_ID> --region us-east-1
sudo tail -f /var/log/nginx/sni.log
```

## 说明
- EC2 强制 IMDSv2，nginx 配置由 user-data 落盘，约 1-2 分钟就绪。
- 完全隔离场景：hosts 指向**私有 IP**（部署输出中有），并在 `SNI_DOMAINS` 追加认证域名。
- 单点/单 AZ 部署；生产高可用建议改 ASG + NLB（方案文档第 8 点）。
