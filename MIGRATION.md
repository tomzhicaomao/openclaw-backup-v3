# OpenClaw 备份仓库迁移完成

## 新仓库状态

| 项目 | 旧仓库 | 新仓库 (v2) |
|------|--------|-------------|
| 大小 | 22GB | **69MB** |
| Git 历史 | 30+ 提交 | 2 个提交 |
| LFS 数据 | 21GB | **72MB** |
| 远程 URL | openclaw-backup | **openclaw-backup-v2** |

## 你需要完成的步骤

### 1. 在 GitHub 上创建新仓库

访问: https://github.com/new

- Repository name: `openclaw-backup-v2`
- Private: ✅ 勾选
- Description: `OpenClaw backup repository v2 - incremental backup enabled`

### 2. 推送到新仓库

```bash
cd ~/openclaw-backup
git push origin main
```

### 3. 验证推送成功

```bash
git log --oneline origin/main
```

## 配置变更

备份脚本已自动更新:
- `BACKUP_REPO_URL` 指向新仓库 `openclaw-backup-v2`
- 增量备份已启用
- `workspace-pm01/projects` 已排除

## 下次备份

下次定时备份（约 03:31）将:
1. 只推送**增量数据**（预计几十MB）
2. 推送到新仓库
3. 不再累积历史负担

## 旧仓库备份

旧仓库已备份到: `~/openclaw-backup-old-20260403`
如需恢复，可以:
```bash
rm -rf ~/openclaw-backup
mv ~/openclaw-backup-old-20260403 ~/openclaw-backup
```

## 注意事项

- 新仓库**只包含最新备份**（2026-04-03_213113）
- 历史备份数据仍在旧仓库和本地备份目录中
- 建议保留旧仓库一段时间作为备份
