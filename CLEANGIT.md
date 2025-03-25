
# 终极建议
[BFG Repo-Cleaner](https://github.com/rtyley/bfg-repo-cleaner)
```bash
$ bfg --strip-blobs-bigger-than 1M --replace-text banned.txt repo.git
```

# 一、如何清理 Git 仓库

```bash

## 查找所有包含大文件对象的提交
git rev-list --objects --all | grep "$(git verify-pack -v .git/objects/pack/*.idx | sort -k 3 -n | tail -5 | awk '{print$1}')"

## 清理
git filter-branch --force --index-filter 'git rm -rf --cached --ignore-unmatch 你的大文件名' --prune-empty --tag-name-filter cat -- --all

## 删除备份引用、立即过期所有 reflog，触发垃圾回收。
rm -rf .git/refs/original/
git reflog expire --expire=now --all
git gc --prune=now

## 检查不可达对象
git fsck --full --unreachable

## 重新打包和压缩
git repack -Ad
git gc --aggressive --prune=now

## 强制推送
git push origin master --force
git push origin --tags --force

git remote prune origin
```


# 二、使用 `git-filter-repo` 清理
## 1. 安装 `git-filter-repo`
```bash
pip install git-filter-repo
## or
brew install git-filter-repo
```

## 2. 查找大文件（示例：清理 .zip 文件）

```bash
## 获取文件路径和最后一次提交信息 hash
git rev-list --objects --all | grep "$(git verify-pack -v .git/objects/pack/*.idx | sort -k 3 -n | tail -10 | awk '{print$1}')"

## -k3gr: 按第三列（原始大小）逆序排序
git verify-pack -v .git/objects/pack/*.idx | sort -k3gr | head -10 | awk '{print $1}'

## 查看该文件的所有历史提交记录
git log --all --oneline --find-object=d8a8f8f4d2a1e7834b3b3e3c3e3c3e3c3e3c3e3c
## or
git log --all --oneline --find-renames=40% --follow -- "path/to/your-large-file.zip"

## 定位文件在仓库中的完整路径
echo "d8a8f8f4d2a1e7834b3b3e3c3e3c3e3c3e3c3e3c" | git rev-parse --verify --stdin
git name-rev --name-only d8a8f8f4d2a1e7834b3b3e3c3e3c3e3c3e3c3e3c
```

## 3. 交互式选择要清理的文件
```bash
## 分析超过100MB的文件，显示前50个
SIZE_THRESHOLD_MB=100 DISPLAY_TOP=50 ./large-file-analyzer.sh

## 生成CSV报告（便于后续处理）
./large-file-analyzer.sh | awk -F '|' '{gsub(/ /, "", $1); gsub(/ /, "", $2); print $1 "," $2 "," $3}' > report.csv

## 与清理工具联动
./large-file-analyzer.sh | awk '{print $NF}' | xargs -I{} git filter-repo --path {} --invert-paths

## 集成到CI/CD
if [ $(./large-file-analyzer.sh | wc -l) -gt 0 ]; then
  echo "发现历史大文件，请清理！"
  exit 1
fi



```

## 4. 执行清理操作

> 使用 git-filter-repo 分析模式（更安全）
```bash
## 生成分析报告
git filter-repo --analyze --force

## 查看大文件清单
cat .git/filter-repo/analysis/path-all-sizes.txt \
| awk '$3 > 10 * 1024^2' \
| sort -k3 -n
```

```bash
# 清理单个文件
git filter-repo --path path/to/large-file.zip --invert-paths --force

# 清理整个目录（如 node_modules）
git filter-repo --path node_modules/ --invert-paths --force

# 清理某类文件（所有 .zip 文件）
git filter-repo --path "*.zip" --invert-paths --force

# 多文件联合清理（组合使用）
git filter-repo --path file1.exe --path dir2/ --invert-paths --force
```

## 5. 清理本地仓库残留
```bash
# 强制触发垃圾回收
rm -rf .git/refs/original/
git reflog expire --expire=now --all
git gc --prune=now --aggressive
git repack -Ad
```

## 6. 推送清理后的仓库
```bash
git push origin --force --all
git push origin --force --tags

## 远程仓库清理
git remote prune origin
```

## 7. 验证清理效果
```bash
# 检查仓库大小变化
du -sh .git

# 确认大文件是否彻底消失, 应该无输出
git log --all -- path/to/large-file.zip
```

## 8. 协作成员重置本地仓库
```bash
# 所有团队成员必须执行
git fetch origin
git reset --hard origin/master
git reflog expire --expire=now --all
git gc --prune=now
```
