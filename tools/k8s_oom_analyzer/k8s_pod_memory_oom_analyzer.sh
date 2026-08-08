#!/bin/bash
CGROUP_ROOT="/sys/fs/cgroup/memory/kubepods"
LOG_FILE="/var/log/messages"
TIME_RANGE="24 hours ago"
MEMORY_THRESHOLD=10240
POD_PREFIX="k8s_POD"
TMP_OOM_EVENTS="/tmp/oom_events.tmp"
TMP_FILTERED_CONTAINERS="/tmp/filtered_containers.tmp"
REPORT_FILE="/tmp/k8s_pod_memory_oom_report.txt"

cleanup() {
    rm -f "$TMP_OOM_EVENTS" "$TMP_FILTERED_CONTAINERS"
}

trap cleanup EXIT

safe_read_memory() {
    local file_path="$1"
    local value=0
    if [ -f "$file_path" ] && [ -r "$file_path" ]; then
        value=$(cat "$file_path" 2>/dev/null | tr -cd '0-9')
        [ -z "$value" ] && value=0
    fi
    echo $((value / 1024))
}

get_container_name() {
    local container_cgroup=$1
    local container_id=$(basename "$container_cgroup")
    
    if command -v docker &> /dev/null; then
        local short_id="${container_id:0:12}"
        local container_name=$(docker inspect --format '{{.Name}}' "$short_id" 2>/dev/null | sed 's/^\///')
        if [ -n "$container_name" ] && [ "$container_name" != "<no value>" ]; then
            echo "$container_name"
            return 0
        fi
    fi

    local pids=$(grep -l "$container_cgroup" /proc/[0-9]*/cgroup 2>/dev/null | grep -oP '(?<=/proc/)\d+(?=/cgroup)')
    if [ -n "$pids" ]; then
        local pid=$(echo "$pids" | head -n 1)
        local cmdline=$(cat /proc/"$pid"/cmdline 2>/dev/null | tr '\0' ' ' | cut -c 1-50)
        if [ -n "$cmdline" ]; then
            echo "PID-$pid: $cmdline"
            return 0
        fi
    fi

    echo "$container_id"
}

echo "===== 正在筛选容器（$POD_PREFIX前缀 + 内存≥$MEMORY_THRESHOLD KB） ====="
echo "时间: $(date)"
echo "cgroup根路径: $CGROUP_ROOT"
echo "=========================================="

if [ ! -d "$CGROUP_ROOT" ]; then
    echo "错误: cgroup根路径 $CGROUP_ROOT 不存在！"
    echo "可能的原因：1. 非Kubernetes节点 2. cgroup驱动不是memory 3. 权限不足"
    exit 1
fi

k8s_pod_containers=()
other_containers=()

container_cgroups=$(find "$CGROUP_ROOT" -mindepth 2 -maxdepth 2 -type d)

for container_cgroup in $container_cgroups; do
    container_name=$(get_container_name "$container_cgroup")
    usage_kb=$(safe_read_memory "$container_cgroup/memory.usage_in_bytes")

    if [[ "$container_name" == "$POD_PREFIX"* ]] && [ "$usage_kb" -ge "$MEMORY_THRESHOLD" ]; then
        k8s_pod_containers+=("$container_cgroup:$container_name:$usage_kb")
    elif [ "$usage_kb" -ge "$MEMORY_THRESHOLD" ]; then
        other_containers+=("$container_cgroup:$container_name:$usage_kb")
    fi
done

> "$TMP_FILTERED_CONTAINERS"
for item in "${k8s_pod_containers[@]}"; do
    echo "$item" >> "$TMP_FILTERED_CONTAINERS"
done
for item in "${other_containers[@]}"; do
    echo "$item" >> "$TMP_FILTERED_CONTAINERS"
done

filtered_count=$(wc -l < "$TMP_FILTERED_CONTAINERS")
if [ "$filtered_count" -eq 0 ]; then
    echo "未找到符合条件的容器（$POD_PREFIX前缀 + 内存≥$MEMORY_THRESHOLD KB）"
else
    echo "找到符合条件的容器数量: $filtered_count"
    echo -e "\n===== 容器级cgroup内存数据（$POD_PREFIX前缀优先） ====="
    printf "%-60s %-40s %-20s %-20s %-15s %-10s\n" \
        "容器ID" "容器名称" "内存使用(KB)" "内存限制(KB)" "使用百分比" "失败次数"
    echo "------------------------------------------------------------------------------------------------------------------------------------------------------------------------"

    while IFS=':' read -r container_cgroup container_name _; do
        container_id=$(basename "$container_cgroup")
        usage_kb=$(safe_read_memory "$container_cgroup/memory.usage_in_bytes")

        limit_file="$container_cgroup/memory.limit_in_bytes"
        if [ -f "$limit_file" ] && [ -r "$limit_file" ]; then
            limit=$(cat "$limit_file" 2>/dev/null | tr -cd '0-9')
            [ -z "$limit" ] && limit=0
            if [ "$limit" -eq 9223372036854771712 ] || [ "$limit" -eq 0 ]; then
                limit_kb="无限制"
                percent="N/A"
            else
                limit_kb=$((limit / 1024))
                percent=$(echo "scale=2; $usage_kb * 100 / $limit_kb" | bc 2>/dev/null)
                [ -z "$percent" ] && percent="0.00"
            fi
        else
            limit_kb="未知"
            percent="N/A"
        fi

        failcnt_file="$container_cgroup/memory.failcnt"
        failcnt=0
        if [ -f "$failcnt_file" ] && [ -r "$failcnt_file" ]; then
            failcnt=$(cat "$failcnt_file" 2>/dev/null | tr -cd '0-9')
            [ -z "$failcnt" ] && failcnt=0
        fi

        container_name_truncated=$(echo "$container_name" | cut -c 1-40)
        printf "%-60s %-40s %-20d %-20s %-15s %-10d\n" \
            "$container_id" "$container_name_truncated" "$usage_kb" "$limit_kb" "$percent%" "$failcnt"
    done < "$TMP_FILTERED_CONTAINERS"
fi

echo -e "\n===== cgroup内存数据收集完成 ====="
echo "=================================="

echo -e "\n\n===== 正在分析近24小时OOM事件 ====="
echo "日志文件: $LOG_FILE"
echo "时间范围: $TIME_RANGE 至今"
echo "===================================="

if [ ! -f "$LOG_FILE" ] || [ ! -r "$LOG_FILE" ]; then
    echo "警告: 日志文件 $LOG_FILE 不存在或无读取权限，跳过OOM分析"
else
    TIME_LIMIT=$(date -d "$TIME_RANGE" +%s)
    grep -E "invoked oom-killer|killed as a result of limit of|out_of_memory|mem_cgroup_out_of_memory" "$LOG_FILE" | while read -r line; do
        log_time=$(echo "$line" | awk '{print $1, $2, $3}')
        log_timestamp=$(date -d "$log_time" +%s 2>/dev/null)
        if [ -n "$log_timestamp" ] && [ "$log_timestamp" -ge "$TIME_LIMIT" ]; then
            echo "$line"
        fi
    done > "$TMP_OOM_EVENTS"

    if [ ! -s "$TMP_OOM_EVENTS" ]; then
        echo "近24小时内未发现OOM Killer事件"
    else
        oom_count=$(grep -c "invoked oom-killer" "$TMP_OOM_EVENTS")
        echo "发现OOM事件数量: $oom_count"
        echo -e "\nOOM事件详情:"
        echo "----------------------------------------------------------------"
        cat "$TMP_OOM_EVENTS"
        echo "----------------------------------------------------------------"

        echo -e "\nOOM事件关联分析（仅显示符合筛选条件的容器）:"
        echo "----------------------------------------------------------------"
        grep "killed as a result of limit of" "$TMP_OOM_EVENTS" | while read -r oom_line; do
            container_cgroup_path=$(echo "$oom_line" | grep -o -E "/kubepods/pod[a-f0-9-]+/[a-f0-9]+" | head -n 1)
            container_id=$(basename "$container_cgroup_path" 2>/dev/null)
            container_name=$(get_container_name "$container_cgroup_path" 2>/dev/null)

            if grep -q "$container_cgroup_path" "$TMP_FILTERED_CONTAINERS"; then
                echo "✅ 符合筛选条件的OOM容器:"
                echo "OOM触发路径: $container_cgroup_path"
                echo "关联容器ID: $container_id"
                echo "关联容器名称: $container_name"
            else
                echo "❌ 不符合筛选条件的OOM容器（忽略）:"
                echo "OOM触发路径: $container_cgroup_path"
                echo "关联容器名称: $container_name"
            fi
            echo "--------------------------------------------------------"
        done
    fi
fi

echo -e "\n===== OOM事件分析完成 ====="
echo "==========================="

echo -e "\n\n========== k8s_POD容器内存&OOM监控报告 ==========" > "$REPORT_FILE"
echo "生成时间: $(date)" >> "$REPORT_FILE"
echo "筛选条件: 1. 容器名称以'$POD_PREFIX'开头（优先） 2. 内存使用≥$MEMORY_THRESHOLD KB（10MB）" >> "$REPORT_FILE"
echo "报告说明: 包含筛选后的容器内存数据和近24小时OOM事件分析" >> "$REPORT_FILE"
echo "================================================" >> "$REPORT_FILE"

echo -e "\n===== 筛选后的容器级cgroup内存数据 =====" >> "$REPORT_FILE"
printf "%-60s %-40s %-20s %-20s %-15s %-10s\n" \
    "容器ID" "容器名称" "内存使用(KB)" "内存限制(KB)" "使用百分比" "失败次数" >> "$REPORT_FILE"
echo "------------------------------------------------------------------------------------------------------------------------------------------------------------------------" >> "$REPORT_FILE"

while IFS=':' read -r container_cgroup container_name _; do
    container_id=$(basename "$container_cgroup")
    usage_kb=$(safe_read_memory "$container_cgroup/memory.usage_in_bytes")
    limit_file="$container_cgroup/memory.limit_in_bytes"
    
    if [ -f "$limit_file" ] && [ -r "$limit_file" ]; then
        limit=$(cat "$limit_file" 2>/dev/null | tr -cd '0-9')
        [ -z "$limit" ] && limit=0
        if [ "$limit" -eq 9223372036854771712 ] || [ "$limit" -eq 0 ]; then
            limit_kb="无限制"
            percent="N/A"
        else
            limit_kb=$((limit / 1024))
            percent=$(echo "scale=2; $usage_kb * 100 / $limit_kb" | bc 2>/dev/null)
            [ -z "$percent" ] && percent="0.00"
        fi
    else
        limit_kb="未知"
        percent="N/A"
    fi
    
    failcnt_file="$container_cgroup/memory.failcnt"
    failcnt=0
    if [ -f "$failcnt_file" ] && [ -r "$failcnt_file" ]; then
        failcnt=$(cat "$failcnt_file" 2>/dev/null | tr -cd '0-9')
        [ -z "$failcnt" ] && failcnt=0
    fi
    
    container_name_truncated=$(echo "$container_name" | cut -c 1-40)
    printf "%-60s %-40s %-20d %-20s %-15s %-10d\n" \
        "$container_id" "$container_name_truncated" "$usage_kb" "$limit_kb" "$percent%" "$failcnt" >> "$REPORT_FILE"
done < "$TMP_FILTERED_CONTAINERS"

echo -e "\n\n===== OOM事件分析 =====" >> "$REPORT_FILE"
if [ -s "$TMP_OOM_EVENTS" ]; then
    echo "近24小时OOM事件数量: $oom_count" >> "$REPORT_FILE"
    echo -e "\nOOM事件详情:" >> "$REPORT_FILE"
    cat "$TMP_OOM_EVENTS" >> "$REPORT_FILE"
    echo -e "\nOOM事件关联分析（筛选后容器）:" >> "$REPORT_FILE"
    grep "killed as a result of limit of" "$TMP_OOM_EVENTS" | while read -r oom_line; do
        container_cgroup_path=$(echo "$oom_line" | grep -o -E "/kubepods/pod[a-f0-9-]+/[a-f0-9]+" | head -n 1)
        if grep -q "$container_cgroup_path" "$TMP_FILTERED_CONTAINERS"; then
            echo "OOM触发路径: $container_cgroup_path" >> "$REPORT_FILE"
            echo "关联容器名称: $(get_container_name "$container_cgroup_path")" >> "$REPORT_FILE"
        fi
    done
else
    echo "近24小时内未发现OOM Killer事件" >> "$REPORT_FILE"
fi

echo -e "\n报告已保存至: $REPORT_FILE"
echo -e "\n========== 脚本执行完成 =========="

exit 0

