# OpenClaw 一键恢复指南

本文档指导你如何在新 Mac 上恢复 OpenClaw 环境。

## 快速开始

### 方式一：全自动恢复（推荐）

```bash
# 1. 下载并运行初始化脚本
curl -fsSL https://raw.githubusercontent.com/tomzhicaomao/openclaw-backup-v2/main/scripts/init-new-mac.sh | bash

# 2. 运行恢复脚本
cd ~/openclaw-backup
./scripts/oneclick-restore.sh
```

### 方式二：手动步骤

#### 步骤 1：安装依赖

```bash
# 安装 Homebrew
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

# 安装必要工具
brew install git age node
```

#### 步骤 2：克隆备份仓库

```bash
git clone https://github.com/tomzhicaomao/openclaw-backup-v2.git ~/openclaw-backup
```

#### 步骤 3：恢复解密密钥

将 age 解密密钥放置到：
```
~/.openclaw-backup-keys/backup.key
```

#### 步骤 4：运行恢复脚本

```bash
cd ~/openclaw-backup
./scripts/oneclick-restore.sh
```

## 详细说明

### 初始化脚本 (init-new-mac.sh)

自动完成以下任务：
- ✅ 检测并安装 Homebrew
- ✅ 安装 Git、age、Node.js
- ✅ 配置 Git 用户信息
- ✅ 克隆备份仓库
- ✅ 提示恢复解密密钥

### 恢复脚本 (oneclick-restore.sh)

自动完成以下任务：
- ✅ 从备份仓库获取最新备份
- ✅ 使用 age 解密备份文件
- ✅ 恢复 `~/.openclaw` 和 `~/.openclaw-rescue`
- ✅ 备份现有目录（如存在）
- ✅ 恢复 LaunchAgent plist 文件
- ✅ 按优先级加载所有 LaunchAgent
- ✅ 验证服务健康状态

### 恢复的服务

| 服务 | 端口 | 说明 |
|------|------|------|
| 主网关 | 18789 | OpenClaw 主服务 |
| 救援网关 | 19001 | 救援/备份服务 |
| PM01 工作流 | - | 项目管理代理 |
| 健康检查 | - | 服务监控 |
| 定时备份 | - | 自动备份任务 |

## 验证恢复

### 检查服务状态

```bash
# 检查主网关
curl http://127.0.0.1:18789/health

# 检查救援网关
curl http://127.0.0.1:19001/health

# 检查 LaunchAgent
launchctl list | grep openclaw
```

### 检查目录结构

```bash
ls -la ~/.openclaw
ls -la ~/.openclaw-rescue
ls -la ~/.openclaw-backup-keys/
```

## 故障排除

### 问题：找不到解密密钥

**解决**：
1. 从旧 Mac 复制 `~/.openclaw-backup-keys/backup.key`
2. 或使用备份时保存的密钥

### 问题：服务无法启动

**检查日志**：
```bash
# 主网关日志
tail -50 ~/.openclaw/logs/gateway.log

# 救援网关日志
tail -50 ~/.openclaw-rescue/gateway.log
```

### 问题：LaunchAgent 加载失败

**手动加载**：
```bash
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/ai.openclaw.gateway-18789.plist
```

### 问题：端口被占用

**检查占用**：
```bash
lsof -i :18789
lsof -i :19001
```

## 回退策略

如果恢复失败，可以回退：

```bash
# 1. 停止服务
launchctl bootout gui/$(id -u) ~/Library/LaunchAgents/ai.openclaw.gateway-18789.plist

# 2. 恢复备份的目录
mv ~/.openclaw.backup.XXX ~/.openclaw
mv ~/.openclaw-rescue.backup.XXX ~/.openclaw-rescue

# 3. 重新加载服务
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/ai.openclaw.gateway-18789.plist
```

## 备份策略

恢复完成后，建议：

1. **验证定时备份正常运行**
   ```bash
   launchctl list | grep com.openclaw.backup
   ```

2. **检查下次备份时间**
   ```bash
   cat ~/openclaw-backup/LATEST_BACKUP.txt
   ```

3. **测试飞书通知**
   - 等待下次自动备份
   - 确认收到飞书成功通知

## 注意事项

1. **密钥安全**：解密密钥 (`backup.key`) 是恢复的关键，务必安全保存
2. **首次运行**：恢复后首次启动可能需要几分钟初始化
3. **权限问题**：脚本会自动处理权限，如遇问题可使用 `sudo`
4. **网络依赖**：部分服务需要网络连接（飞书通知、GitHub 推送等）

## 支持

如遇问题，请检查：
1. 本文档的故障排除章节
2. 服务日志文件
3. LaunchAgent 状态

## 更新日志

| 日期 | 版本 | 说明 |
|------|------|------|
| 2026-04-03 | 1.0 | 初始版本，支持一键恢复 |
