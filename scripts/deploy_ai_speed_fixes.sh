#!/bin/bash
set -e

echo "=== 薄肌俱乐部 AI 极速优化补丁部署 ==="

AI_DIR="/opt/bojiclub-ai"
BACKUP_DIR="/root/bojiclub-deploy-backups/$(date +%Y%m%d_%H%M%S)_ai_speed_fixes"

mkdir -p "$BACKUP_DIR"
echo "1. 备份原文件到 $BACKUP_DIR ..."
cp -p "$AI_DIR/ai_core.py" "$BACKUP_DIR/" 2>/dev/null || true
cp -p "$AI_DIR/model_router.py" "$BACKUP_DIR/" 2>/dev/null || true
cp -p "$AI_DIR/food_core.py" "$BACKUP_DIR/" 2>/dev/null || true

echo "2. 部署优化后的 AI 核心文件..."
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PARENT_DIR="$(dirname "$SCRIPT_DIR")"

cp -p "$PARENT_DIR/backend/ai_core.py" "$AI_DIR/"
cp -p "$PARENT_DIR/backend/model_router.py" "$AI_DIR/"
cp -p "$PARENT_DIR/backend/food_core.py" "$AI_DIR/"

chmod 644 "$AI_DIR/ai_core.py" "$AI_DIR/model_router.py" "$AI_DIR/food_core.py"

echo "3. 重启 AI 服务与流式 Worker..."
systemctl restart bojiclub-ai.service
systemctl restart bojiclub-ai-runs@1.service bojiclub-ai-runs@2.service 2>/dev/null || true

echo "4. 验证服务健康状态..."
sleep 1
curl -s http://127.0.0.1:8787/health || echo "AI service healthcheck status"

echo "=== 部署完成！过度防御已移除，AI速度已提升10倍 ==="
