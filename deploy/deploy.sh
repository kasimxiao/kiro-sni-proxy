#!/usr/bin/env bash
#############################################
# Kiro SNI Proxy over AWS PrivateLink 自动化部署
# 依据方案文档第 4 点（EC2 + nginx stream SNI 透传）实现
#
# 支持：
#   - 复用已有 VPC / 子网（config.env 填 EXISTING_VPC_ID / EXISTING_SUBNET_ID）
#   - 自动新建 VPC / 子网 / IGW / 路由表（两项留空时）
#
# 依赖：aws cli v2、jq
# 用法：编辑 config.env 后执行  ./deploy.sh
#############################################
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/config.env"

STATE_FILE="${SCRIPT_DIR}/.deploy-state.env"
: > "${STATE_FILE}"   # 清空，记录本次创建的资源，供 cleanup.sh 使用

# ---------- 日志辅助 ----------
c_green()  { printf '\033[0;32m%s\033[0m\n' "$*"; }
c_yellow() { printf '\033[0;33m%s\033[0m\n' "$*"; }
c_red()    { printf '\033[0;31m%s\033[0m\n' "$*" >&2; }
log()  { c_green  "==> $*"; }
warn() { c_yellow "[!] $*"; }
die()  { c_red    "[x] $*"; exit 1; }

save_state() { echo "$1=\"$2\"" >> "${STATE_FILE}"; }

AWSCLI=(aws --region "${AWS_REGION}" --output json)

# ---------- 前置检查 ----------
command -v aws >/dev/null || die "未找到 aws cli，请先安装 AWS CLI v2"
command -v jq  >/dev/null || die "未找到 jq，请先安装 jq"
"${AWSCLI[@]}" sts get-caller-identity >/dev/null 2>&1 \
  || die "AWS 凭证无效或未配置，请先 aws configure / 设置环境变量"

ACCOUNT_ID="$("${AWSCLI[@]}" sts get-caller-identity --query Account --output text)"
log "AWS 账号: ${ACCOUNT_ID}  Region: ${AWS_REGION}"

TAG_SPEC_BASE="Key=Project,Value=${PROJECT_NAME}"

#############################################
# 1. 网络：复用或新建 VPC / 子网
#############################################
CREATED_NETWORK="false"
if [[ -n "${EXISTING_VPC_ID}" && -n "${EXISTING_SUBNET_ID}" ]]; then
  log "复用已有网络 VPC=${EXISTING_VPC_ID} Subnet=${EXISTING_SUBNET_ID}"
  VPC_ID="${EXISTING_VPC_ID}"
  SUBNET_ID="${EXISTING_SUBNET_ID}"
  # 校验子网确属该 VPC
  SUBNET_VPC="$("${AWSCLI[@]}" ec2 describe-subnets --subnet-ids "${SUBNET_ID}" \
      --query 'Subnets[0].VpcId' --output text 2>/dev/null || echo "NONE")"
  [[ "${SUBNET_VPC}" == "${VPC_ID}" ]] \
    || die "子网 ${SUBNET_ID} 不属于 VPC ${VPC_ID}（实际: ${SUBNET_VPC}）"
elif [[ -z "${EXISTING_VPC_ID}" && -z "${EXISTING_SUBNET_ID}" ]]; then
  CREATED_NETWORK="true"
  log "新建 VPC (${NEW_VPC_CIDR}) / 子网 (${NEW_SUBNET_CIDR})"

  VPC_ID="$("${AWSCLI[@]}" ec2 create-vpc --cidr-block "${NEW_VPC_CIDR}" \
      --tag-specifications "ResourceType=vpc,Tags=[{${TAG_SPEC_BASE}},{Key=Name,Value=${PROJECT_NAME}-vpc}]" \
      --query 'Vpc.VpcId' --output text)"
  save_state VPC_ID "${VPC_ID}"
  "${AWSCLI[@]}" ec2 modify-vpc-attribute --vpc-id "${VPC_ID}" --enable-dns-support '{"Value":true}'
  "${AWSCLI[@]}" ec2 modify-vpc-attribute --vpc-id "${VPC_ID}" --enable-dns-hostnames '{"Value":true}'
  "${AWSCLI[@]}" ec2 wait vpc-available --vpc-ids "${VPC_ID}"
  log "VPC 创建完成: ${VPC_ID}"

  # 可用区
  if [[ -z "${NEW_SUBNET_AZ}" ]]; then
    NEW_SUBNET_AZ="$("${AWSCLI[@]}" ec2 describe-availability-zones \
        --query 'AvailabilityZones[0].ZoneName' --output text)"
  fi
  SUBNET_ID="$("${AWSCLI[@]}" ec2 create-subnet --vpc-id "${VPC_ID}" \
      --cidr-block "${NEW_SUBNET_CIDR}" --availability-zone "${NEW_SUBNET_AZ}" \
      --tag-specifications "ResourceType=subnet,Tags=[{${TAG_SPEC_BASE}},{Key=Name,Value=${PROJECT_NAME}-subnet}]" \
      --query 'Subnet.SubnetId' --output text)"
  save_state SUBNET_ID "${SUBNET_ID}"
  # 子网自动分配公网 IP
  "${AWSCLI[@]}" ec2 modify-subnet-attribute --subnet-id "${SUBNET_ID}" --map-public-ip-on-launch
  log "子网创建完成: ${SUBNET_ID} (${NEW_SUBNET_AZ})"

  # IGW + 路由
  IGW_ID="$("${AWSCLI[@]}" ec2 create-internet-gateway \
      --tag-specifications "ResourceType=internet-gateway,Tags=[{${TAG_SPEC_BASE}},{Key=Name,Value=${PROJECT_NAME}-igw}]" \
      --query 'InternetGateway.InternetGatewayId' --output text)"
  save_state IGW_ID "${IGW_ID}"
  "${AWSCLI[@]}" ec2 attach-internet-gateway --internet-gateway-id "${IGW_ID}" --vpc-id "${VPC_ID}"

  RT_ID="$("${AWSCLI[@]}" ec2 create-route-table --vpc-id "${VPC_ID}" \
      --tag-specifications "ResourceType=route-table,Tags=[{${TAG_SPEC_BASE}},{Key=Name,Value=${PROJECT_NAME}-rt}]" \
      --query 'RouteTable.RouteTableId' --output text)"
  save_state RT_ID "${RT_ID}"
  "${AWSCLI[@]}" ec2 create-route --route-table-id "${RT_ID}" \
      --destination-cidr-block "0.0.0.0/0" --gateway-id "${IGW_ID}" >/dev/null
  ASSOC_ID="$("${AWSCLI[@]}" ec2 associate-route-table --route-table-id "${RT_ID}" \
      --subnet-id "${SUBNET_ID}" --query 'AssociationId' --output text)"
  save_state RT_ASSOC_ID "${ASSOC_ID}"
  log "IGW/路由表创建完成: ${IGW_ID} / ${RT_ID}"
else
  die "config.env 网络配置错误：EXISTING_VPC_ID 与 EXISTING_SUBNET_ID 必须【同时填写】或【同时留空】"
fi
save_state CREATED_NETWORK "${CREATED_NETWORK}"
save_state VPC_ID "${VPC_ID}"
save_state SUBNET_ID "${SUBNET_ID}"

# 取 VPC CIDR（供 VPCE 安全组放行内网使用）
VPC_CIDR="$("${AWSCLI[@]}" ec2 describe-vpcs --vpc-ids "${VPC_ID}" \
    --query 'Vpcs[0].CidrBlock' --output text)"
log "VPC CIDR: ${VPC_CIDR}"

#############################################
# 2. 安全组：代理 EC2 + VPCE
#############################################
log "创建代理 EC2 安全组"
PROXY_SG_ID="$("${AWSCLI[@]}" ec2 create-security-group \
    --group-name "${PROJECT_NAME}-proxy-sg" \
    --description "Kiro SNI proxy EC2 SG" --vpc-id "${VPC_ID}" \
    --tag-specifications "ResourceType=security-group,Tags=[{${TAG_SPEC_BASE}},{Key=Name,Value=${PROJECT_NAME}-proxy-sg}]" \
    --query 'GroupId' --output text)"
save_state PROXY_SG_ID "${PROXY_SG_ID}"

# 443 入站
"${AWSCLI[@]}" ec2 authorize-security-group-ingress --group-id "${PROXY_SG_ID}" \
    --protocol tcp --port 443 --cidr "${INGRESS_443_CIDR}" >/dev/null
# 22 入站（可选）
if [[ -n "${ADMIN_SSH_CIDR}" ]]; then
  "${AWSCLI[@]}" ec2 authorize-security-group-ingress --group-id "${PROXY_SG_ID}" \
      --protocol tcp --port 22 --cidr "${ADMIN_SSH_CIDR}" >/dev/null
  warn "已放行 22 端口来源 ${ADMIN_SSH_CIDR}"
else
  log "未开放 22 端口（使用 SSM Session Manager 登录）"
fi
log "代理安全组: ${PROXY_SG_ID}"

#############################################
# 3. PrivateLink VPCE（可选）
#############################################
if [[ "${ENABLE_PRIVATELINK}" == "true" ]]; then
  log "创建 VPCE 专用安全组（放行 VPC 内 443）"
  VPCE_SG_ID="$("${AWSCLI[@]}" ec2 create-security-group \
      --group-name "${PROJECT_NAME}-vpce-sg" \
      --description "Kiro VPCE SG" --vpc-id "${VPC_ID}" \
      --tag-specifications "ResourceType=security-group,Tags=[{${TAG_SPEC_BASE}},{Key=Name,Value=${PROJECT_NAME}-vpce-sg}]" \
      --query 'GroupId' --output text)"
  save_state VPCE_SG_ID "${VPCE_SG_ID}"
  "${AWSCLI[@]}" ec2 authorize-security-group-ingress --group-id "${VPCE_SG_ID}" \
      --protocol tcp --port 443 --cidr "${VPC_CIDR}" >/dev/null

  for svc in "q" "codewhisperer"; do
    SVC_NAME="com.amazonaws.${AWS_REGION}.${svc}"
    log "创建 VPCE: ${SVC_NAME}"
    VPCE_ID="$("${AWSCLI[@]}" ec2 create-vpc-endpoint \
        --vpc-id "${VPC_ID}" --vpc-endpoint-type Interface \
        --service-name "${SVC_NAME}" \
        --subnet-ids "${SUBNET_ID}" \
        --security-group-ids "${VPCE_SG_ID}" \
        --private-dns-enabled \
        --tag-specifications "ResourceType=vpc-endpoint,Tags=[{${TAG_SPEC_BASE}},{Key=Name,Value=${PROJECT_NAME}-vpce-${svc}}]" \
        --query 'VpcEndpoint.VpcEndpointId' --output text)"
    save_state "VPCE_${svc}_ID" "${VPCE_ID}"
    log "  -> ${VPCE_ID}"
  done
  warn "VPCE 需数分钟变为 available，EC2 启动期间会并行就绪"
else
  warn "ENABLE_PRIVATELINK=false，跳过 VPCE（DNS 将回落公网解析）"
fi

#############################################
# 4. SSM 角色（免密登录/运维）
#############################################
log "配置 IAM 角色（SSM）"
ROLE_NAME="${PROJECT_NAME}-ec2-role"
INSTANCE_PROFILE="${PROJECT_NAME}-ec2-profile"

if ! aws iam get-role --role-name "${ROLE_NAME}" >/dev/null 2>&1; then
  aws iam create-role --role-name "${ROLE_NAME}" \
    --assume-role-policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ec2.amazonaws.com"},"Action":"sts:AssumeRole"}]}' \
    --tags "${TAG_SPEC_BASE//Key=/Key=}" >/dev/null 2>&1 || \
  aws iam create-role --role-name "${ROLE_NAME}" \
    --assume-role-policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ec2.amazonaws.com"},"Action":"sts:AssumeRole"}]}' >/dev/null
  save_state IAM_ROLE_CREATED "true"
  aws iam attach-role-policy --role-name "${ROLE_NAME}" \
    --policy-arn "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore" >/dev/null
  log "IAM 角色创建完成: ${ROLE_NAME}"
else
  warn "IAM 角色 ${ROLE_NAME} 已存在，复用"
fi
save_state IAM_ROLE_NAME "${ROLE_NAME}"

if ! aws iam get-instance-profile --instance-profile-name "${INSTANCE_PROFILE}" >/dev/null 2>&1; then
  aws iam create-instance-profile --instance-profile-name "${INSTANCE_PROFILE}" >/dev/null
  aws iam add-role-to-instance-profile --instance-profile-name "${INSTANCE_PROFILE}" \
    --role-name "${ROLE_NAME}" >/dev/null
  save_state IAM_PROFILE_CREATED "true"
  log "实例配置文件创建完成，等待 IAM 传播..."
  sleep 12
else
  warn "实例配置文件 ${INSTANCE_PROFILE} 已存在，复用"
fi
save_state IAM_PROFILE_NAME "${INSTANCE_PROFILE}"

#############################################
# 5. 生成 user-data（装 nginx + 写第4点配置）
#############################################
log "生成 user-data（nginx stream SNI 配置）"

# 组装 SNI map 行
MAP_LINES=""
for d in "${SNI_DOMAINS[@]}"; do
  # 对齐补齐到 45 列，便于阅读；功能上空格无所谓
  MAP_LINES+="        ${d}"
  MAP_LINES+='  $ssl_preread_server_name:443;'$'\n'
done

USERDATA_FILE="$(mktemp)"
cat > "${USERDATA_FILE}" <<USERDATA
#!/bin/bash
set -euxo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y nginx libnginx-mod-stream dnsutils

cat > /etc/nginx/nginx.conf <<'NGINXCONF'
user www-data;
worker_processes auto;
worker_rlimit_nofile 65535;
pid /run/nginx.pid;
include /etc/nginx/modules-enabled/*.conf;

events {
    worker_connections 16384;
    multi_accept on;
    use epoll;
}

stream {
    map \$ssl_preread_server_name \$backend {
${MAP_LINES}        default                                "";
    }

    resolver 169.254.169.253 valid=30s ipv6=off;
    resolver_timeout 5s;

    log_format sni '\$remote_addr [\$time_local] sni="\$ssl_preread_server_name" '
                   'backend="\$backend" status=\$status sent=\$bytes_sent recv=\$bytes_received '
                   'duration=\$session_time';
    access_log /var/log/nginx/sni.log sni buffer=64k flush=5s;
    error_log  /var/log/nginx/sni_error.log warn;

    tcp_nodelay on;

    server {
        listen 443 reuseport;
        proxy_pass \$backend;
        ssl_preread on;
        proxy_connect_timeout 10s;
        proxy_timeout 600s;
        proxy_socket_keepalive on;
    }
}

http {
    server {
        listen 80 default_server;
        return 404;
    }
}
NGINXCONF

nginx -t
systemctl enable nginx
systemctl restart nginx
echo "kiro-sni-proxy nginx ready" > /var/log/kiro-sni-proxy-bootstrap.log
USERDATA

#############################################
# 6. 查最新 Ubuntu 24.04 AMI + 启动 EC2
#############################################
log "查询 Ubuntu 24.04 (${INSTANCE_ARCH}) 最新 AMI"
AMI_ID="$("${AWSCLI[@]}" ssm get-parameter \
    --name "/aws/service/canonical/ubuntu/server/24.04/stable/current/${INSTANCE_ARCH}/hvm/ebs-gp3/ami-id" \
    --query 'Parameter.Value' --output text 2>/dev/null || echo "")"
if [[ -z "${AMI_ID}" || "${AMI_ID}" == "None" ]]; then
  # 回退：用官方 owner 过滤
  AMI_ID="$("${AWSCLI[@]}" ec2 describe-images --owners 099720109477 \
      --filters "Name=name,Values=ubuntu/images/hvm-ssd*/ubuntu-noble-24.04-${INSTANCE_ARCH}-server-*" \
                "Name=state,Values=available" \
      --query 'reverse(sort_by(Images,&CreationDate))[0].ImageId' --output text)"
fi
[[ -n "${AMI_ID}" && "${AMI_ID}" != "None" ]] || die "未找到 Ubuntu 24.04 AMI"
log "AMI: ${AMI_ID}"

RUN_ARGS=(
  ec2 run-instances
  --image-id "${AMI_ID}"
  --instance-type "${INSTANCE_TYPE}"
  --subnet-id "${SUBNET_ID}"
  --security-group-ids "${PROXY_SG_ID}"
  --iam-instance-profile "Name=${INSTANCE_PROFILE}"
  --associate-public-ip-address
  --metadata-options "HttpTokens=required,HttpEndpoint=enabled"
  --block-device-mappings "DeviceName=/dev/sda1,Ebs={VolumeSize=${EBS_SIZE_GB},VolumeType=gp3,DeleteOnTermination=true}"
  --user-data "file://${USERDATA_FILE}"
  --tag-specifications "ResourceType=instance,Tags=[{${TAG_SPEC_BASE}},{Key=Name,Value=${PROJECT_NAME}-ec2}]"
)
[[ -n "${KEY_NAME}" ]] && RUN_ARGS+=(--key-name "${KEY_NAME}")

log "启动 EC2 实例..."
INSTANCE_ID="$("${AWSCLI[@]}" "${RUN_ARGS[@]}" --query 'Instances[0].InstanceId' --output text)"
save_state INSTANCE_ID "${INSTANCE_ID}"
rm -f "${USERDATA_FILE}"
log "实例已创建: ${INSTANCE_ID}，等待 running..."
"${AWSCLI[@]}" ec2 wait instance-running --instance-ids "${INSTANCE_ID}"

#############################################
# 7. 分配并绑定 EIP
#############################################
log "分配 EIP 并绑定"
EIP_ALLOC_ID="$("${AWSCLI[@]}" ec2 allocate-address --domain vpc \
    --tag-specifications "ResourceType=elastic-ip,Tags=[{${TAG_SPEC_BASE}},{Key=Name,Value=${PROJECT_NAME}-eip}]" \
    --query 'AllocationId' --output text)"
save_state EIP_ALLOC_ID "${EIP_ALLOC_ID}"
"${AWSCLI[@]}" ec2 associate-address --instance-id "${INSTANCE_ID}" \
    --allocation-id "${EIP_ALLOC_ID}" >/dev/null
EIP="$("${AWSCLI[@]}" ec2 describe-addresses --allocation-ids "${EIP_ALLOC_ID}" \
    --query 'Addresses[0].PublicIp' --output text)"
save_state EIP "${EIP}"

PRIVATE_IP="$("${AWSCLI[@]}" ec2 describe-instances --instance-ids "${INSTANCE_ID}" \
    --query 'Reservations[0].Instances[0].PrivateIpAddress' --output text)"

#############################################
# 8. 输出结果 + 生成客户端 hosts 片段
#############################################
HOSTS_FILE="${SCRIPT_DIR}/client-hosts.txt"
{
  echo "# === Kiro SNI Proxy 客户端 hosts（常规场景：指向 EIP）==="
  for d in "${SNI_DOMAINS[@]}"; do
    printf '%-15s %s\n' "${EIP}" "${d}"
  done
} > "${HOSTS_FILE}"

echo
c_green "=================================================="
c_green "         部署完成 ✅"
c_green "=================================================="
cat <<SUMMARY
  Region        : ${AWS_REGION}
  VPC           : ${VPC_ID} (${VPC_CIDR}) $( [[ ${CREATED_NETWORK} == true ]] && echo '[新建]' || echo '[复用]' )
  Subnet        : ${SUBNET_ID}
  实例 ID       : ${INSTANCE_ID} (${INSTANCE_TYPE}, ${INSTANCE_ARCH})
  公网 EIP      : ${EIP}
  私有 IP       : ${PRIVATE_IP}   （完全隔离场景 hosts 指向此 IP）
  PrivateLink   : ${ENABLE_PRIVATELINK}
  客户端 hosts  : ${HOSTS_FILE}

  下一步：
   1) nginx 由 user-data 自动安装，约 1-2 分钟就绪。
   2) 客户端追加 ${HOSTS_FILE} 内容到 hosts 后刷新 DNS 缓存：
        macOS : sudo dscacheutil -flushcache && sudo killall -HUP mDNSResponder
        Windows: ipconfig /flushdns
   3) 验证：
        getent hosts codewhisperer.${AWS_REGION}.amazonaws.com
        curl -v https://codewhisperer.${AWS_REGION}.amazonaws.com/ 2>&1 | grep Connected
   4) 登录 EC2 看日志（无需 22）：
        aws ssm start-session --target ${INSTANCE_ID} --region ${AWS_REGION}
        sudo tail -f /var/log/nginx/sni.log

  资源清理： ./cleanup.sh
SUMMARY
