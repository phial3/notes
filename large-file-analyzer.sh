#!/bin/bash

# 配置参数（支持环境变量覆盖）
SIZE_THRESHOLD_MB=${SIZE_THRESHOLD_MB:-1}
DISPLAY_TOP=${DISPLAY_TOP:-20}
SHOW_LAST_COMMIT=${SHOW_LAST_COMMIT:-true}
SHOW_FIRST_COMMIT=${SHOW_FIRST_COMMIT:-true}

# 获取提交信息（合并处理提高性能）
get_commit_data() {
  local path=$1
  {
    # 获取首次提交
    git log --all --format="%H|%ad|%an" --date=iso --no-patch --reverse --max-count=1 -- "$path" 2>/dev/null
    # 获取末次提交
    git log --all --format="%H|%ad|%an" --date=iso --no-patch --max-count=1 -- "$path" 2>/dev/null
  } | awk -F '|' '
    NR==1 {printf "%s %s %s ", $1, $2, $3}
    NR==2 {printf "%s %s %s", $1, $2, $3}
  '
}

# 兼容所有平台的文件大小格式化
format_size() {
  local bytes=$1
  awk -v bytes="$bytes" 'BEGIN {
    suffix="BKMGTPEZY"
    while (bytes >= 1024 && length(suffix) > 1) {
      bytes /= 1024
      suffix = substr(suffix, 2)
    }
    printf (suffix == "B" ? "%d%s" : "%.1f%s"), bytes, substr(suffix,1,1)
  }'
}

# 生成表格格式（兼容无column命令的环境）
format_table() {
  awk -F '|' '
    BEGIN {
      # 定义列宽（根据内容动态调整）
      widths[1]=40   # Hash
      widths[2]=8    # Size
      widths[3]=20   # Path
      widths[4]=40   # First Commit
      widths[5]=20   # First Date
      widths[6]=15   # First Author
      widths[7]=40   # Last Commit
      widths[8]=20   # Last Date
      widths[9]=15   # Last Author
    }
    {
      for (i=1; i<=NF; i++) {
        printf "%-*s", widths[i], $i
        if (i != NF) printf "  "
      }
      print ""
    }
  '
}

# 主处理流程
{
  # 生成表头
  header="Hash|Size|Path"
  [[ "$SHOW_FIRST_COMMIT" == "true" ]] && header+="|First Commit|First Date|First Author"
  [[ "$SHOW_LAST_COMMIT" == "true" ]] && header+="|Last Commit|Last Date|Last Author"
  echo "$header"

  # 处理数据
  git rev-list --objects --all \
  | git cat-file --batch-check='%(objecttype) %(objectname) %(objectsize) %(rest)' \
  | awk -v threshold=$((SIZE_THRESHOLD_MB * 1024 * 1024)) '
      $1 == "blob" && $3 > threshold {print $2, $3, $4}' \
  | sort -k2 -n \
  | tail -n $DISPLAY_TOP \
  | while read hash bytes path; do
      # 初始化行数据
      row=$(printf "%s|%s|%s" \
        "$hash" \
        "$(format_size $bytes)" \
        "$(echo "$path" | cut -c1-20)")  # 限制路径显示长度

      # 添加提交信息
      if [[ "$SHOW_FIRST_COMMIT" == "true" || "$SHOW_LAST_COMMIT" == "true" ]]; then
        read f_hash f_date f_author l_hash l_date l_author < <(get_commit_data "$path")

        [[ "$SHOW_FIRST_COMMIT" == "true" ]] && \
          row+="|$f_hash|$f_date|$f_author"
        [[ "$SHOW_LAST_COMMIT" == "true" ]] && \
          row+="|$l_hash|$l_date|$l_author"
      fi

      echo "$row"
    done
} | format_table