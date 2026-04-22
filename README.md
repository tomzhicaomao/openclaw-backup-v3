# OpenClaw Backup

OpenClaw 完整备份仓库 - 支持从 GitHub 完全恢复

## 备份策略

| 位置 | 保留数量 | 频率 |
|------|----------|------|
| 本地 | 10 个最新备份 | 每 6 小时 |
| GitHub 仓库 | 10 个最新备份 | 每 6 小时 |

## 配置

```bash
# 本地保留备份数量
export OPENCLAW_BACKUP_MAX_LOCAL_COUNT=10

# 仓库保留备份数量
export OPENCLAW_BACKUP_MAX_REPO_COUNT=10

# 保留天数（超过此天数的备份会被删除）
export OPENCLAW_BACKUP_RETENTION_DAYS=30
```

## 恢复流程

### 从 GitHub 恢复

```bash
# 1. 克隆备份仓库
git clone https://github.com/tomzhicaomao/openclaw-backup-v3.git ~/openclaw-backup

# 2. 确保有 age 解密密钥
# 密钥位置：~/.openclaw-backup-keys/backup.key

# 3. 解密备份文件
age -d -i ~/.openclaw-backup-keys/backup.key \
    ~/openclaw-backup/backups/LATEST/.openclaw.tar.age | \
    tar -C ~ -xf -

# 4. 恢复 LaunchAgent
cp ~/openclaw-backup/config/*.plist ~/Library/LaunchAgents/
launchctl load -w ~/Library/LaunchAgents/com.openclaw.backup.plist
```

### 一键恢复脚本

见 `scripts/oneclick-restore.sh`

## 备份内容

- `.openclaw/` - OpenClaw 主程序和数据
- `.openclaw-rescue/` - Rescue 环境
- LaunchAgent 配置文件
- 备份加密公钥

## 排除项

- `node_modules/`
- `.git/` (部分)
- `logs/`
- `cache/`
- `workspace-*/projects/` (项目文件过大)

## 监控

备份状态通过飞书通知：
- ✅ 备份成功
- ❌ 备份失败（含错误详情）

## 仓库

- **主仓库**: https://github.com/tomzhicaomao/openclaw-backup-v3
- **无 LFS 依赖** - 所有文件均为普通 Git 文件
