#!/usr/bin/env bash
#############################################
# Kiro SNI Proxy 资源清理
# 读取 deploy.sh 生成的 .deploy-state.env，逆序删除本次创建的资源。
# 复用的 VPC/子网不会被删除（CREATED_NETWORK=false 时）。
#############################################
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/config.env"
STATE_FILE="${SCRIPT_DIR}/.deploy-state.env"

[[ -f "${STATE_FILE}" ]] || { echo "未找到 ${STATE_FILE}，无可清理资源"; exit 0; }
source "${STATE_FILE}"

AWSCLI=(aws --region "${AWS_REGION}" --output json)
log()  { printf '\033[0;32m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[0;33m[!] %s\033[0m\n' "$*"; }

echo "将清理以下本次部署创建的资源（复用的网络不动）："
grep -E '=' "${STATE_FILE}" || true
read -r -p "确认删除？输入 yes 继续: " ans
[[ "${ans}" == "yes" ]] || { echo "已取消"; exit 0; }

# 1. EIP（先解绑再释放）
# 多网卡部署记录在 EIP_ALLOC_IDS（空格分隔）；旧状态文件只有单值 EIP_ALLOC_ID
for alloc in ${EIP_ALLOC_IDS:-${EIP_ALLOC_ID:-}}; do
  log "释放 EIP ${alloc}"
  ASSOC="$("${AWSCLI[@]}" ec2 describe-addresses --allocation-ids "${alloc}" \
      --query 'Addresses[0].AssociationId' --output text 2>/dev/null || echo None)"
  [[ "${ASSOC}" != "None" && -n "${ASSOC}" ]] && "${AWSCLI[@]}" ec2 disassociate-address --association-id "${ASSOC}" || true
  "${AWSCLI[@]}" ec2 release-address --allocation-id "${alloc}" || warn "释放 EIP ${alloc} 失败"
done

# 2. EC2 实例
if [[ -n "${INSTANCE_ID:-}" ]]; then
  log "终止实例 ${INSTANCE_ID}"
  "${AWSCLI[@]}" ec2 terminate-instances --instance-ids "${INSTANCE_ID}" >/dev/null || true
  "${AWSCLI[@]}" ec2 wait instance-terminated --instance-ids "${INSTANCE_ID}" || true
fi

# 3. VPCE（删除后必须等其底层网卡 ENI 彻底释放，否则关联的 SG/VPC 删不掉）
VPCE_IDS=()
for svc in q codewhisperer; do
  var="VPCE_${svc}_ID"
  vpce_id="${!var:-}"
  if [[ -n "${vpce_id}" ]]; then
    log "删除 VPCE ${vpce_id} (${svc})"
    "${AWSCLI[@]}" ec2 delete-vpc-endpoints --vpc-endpoint-ids "${vpce_id}" >/dev/null || true
    VPCE_IDS+=("${vpce_id}")
  fi
done
if [[ ${#VPCE_IDS[@]} -gt 0 ]]; then
  warn "等待 VPCE 彻底删除（网卡释放）..."
  for i in $(seq 1 18); do   # 最长约 3 分钟
    remain="$("${AWSCLI[@]}" ec2 describe-vpc-endpoints \
        --vpc-endpoint-ids "${VPCE_IDS[@]}" \
        --query 'VpcEndpoints[?State!=`deleted`].VpcEndpointId' --output text 2>/dev/null || echo "")"
    [[ -z "${remain}" ]] && { log "VPCE 已全部删除"; break; }
    warn "  VPCE 仍在删除中 (${i}/18): ${remain}"; sleep 10
  done
fi

# 4. 安全组（VPCE SG、代理 SG）——SG 依赖 ENI 释放，重试更久并保留末次错误
delete_sg_with_retry() {
  local sg="$1"; local max=12
  log "删除安全组 ${sg}"
  for i in $(seq 1 "${max}"); do
    if "${AWSCLI[@]}" ec2 delete-security-group --group-id "${sg}" 2>/dev/null; then
      log "  安全组 ${sg} 删除成功"; return 0
    fi
    if [[ "${i}" -eq "${max}" ]]; then
      warn "  安全组 ${sg} 重试 ${max} 次仍失败，末次错误："
      "${AWSCLI[@]}" ec2 delete-security-group --group-id "${sg}" 2>&1 | sed 's/^/    /' || true
      return 1
    fi
    warn "  安全组仍被占用，重试 ${i}/${max}..."; sleep 10
  done
}
for sg in "${VPCE_SG_ID:-}" "${PROXY_SG_ID:-}"; do
  [[ -n "${sg}" ]] && delete_sg_with_retry "${sg}"
done

# 5. IAM（仅删除本脚本创建的）
if [[ "${IAM_PROFILE_CREATED:-}" == "true" && -n "${IAM_PROFILE_NAME:-}" ]]; then
  log "清理实例配置文件 ${IAM_PROFILE_NAME}"
  aws iam remove-role-from-instance-profile --instance-profile-name "${IAM_PROFILE_NAME}" \
      --role-name "${IAM_ROLE_NAME}" 2>/dev/null || true
  aws iam delete-instance-profile --instance-profile-name "${IAM_PROFILE_NAME}" 2>/dev/null || true
fi
if [[ "${IAM_ROLE_CREATED:-}" == "true" && -n "${IAM_ROLE_NAME:-}" ]]; then
  log "清理 IAM 角色 ${IAM_ROLE_NAME}"
  aws iam detach-role-policy --role-name "${IAM_ROLE_NAME}" \
      --policy-arn "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore" 2>/dev/null || true
  aws iam delete-role --role-name "${IAM_ROLE_NAME}" 2>/dev/null || true
fi

# 6. 网络（仅当本脚本新建时）
if [[ "${CREATED_NETWORK:-false}" == "true" ]]; then
  log "清理新建的网络资源"
  [[ -n "${RT_ASSOC_ID:-}" ]] && "${AWSCLI[@]}" ec2 disassociate-route-table --association-id "${RT_ASSOC_ID}" 2>/dev/null || true
  [[ -n "${RT_ID:-}"       ]] && "${AWSCLI[@]}" ec2 delete-route-table --route-table-id "${RT_ID}" 2>/dev/null || true
  if [[ -n "${IGW_ID:-}" ]]; then
    "${AWSCLI[@]}" ec2 detach-internet-gateway --internet-gateway-id "${IGW_ID}" --vpc-id "${VPC_ID}" 2>/dev/null || true
    "${AWSCLI[@]}" ec2 delete-internet-gateway --internet-gateway-id "${IGW_ID}" 2>/dev/null || true
  fi
  [[ -n "${SUBNET_ID:-}" ]] && "${AWSCLI[@]}" ec2 delete-subnet --subnet-id "${SUBNET_ID}" 2>/dev/null || true
  # VPC 删除同样可能因残留依赖（SG/ENI）短暂失败，重试几次
  if [[ -n "${VPC_ID:-}" ]]; then
    for i in $(seq 1 6); do
      if "${AWSCLI[@]}" ec2 delete-vpc --vpc-id "${VPC_ID}" 2>/dev/null; then
        log "VPC ${VPC_ID} 删除成功"; VPC_ID=""; break
      fi
      warn "VPC 仍有依赖，重试 ${i}/6..."; sleep 10
    done
    [[ -n "${VPC_ID:-}" ]] && warn "VPC ${VPC_ID} 删除失败，末次错误：" && \
      "${AWSCLI[@]}" ec2 delete-vpc --vpc-id "${VPC_ID}" 2>&1 | sed 's/^/  /' || true
  fi
else
  warn "网络为复用资源，保留不删"
fi

rm -f "${STATE_FILE}"
log "清理完成 ✅"
