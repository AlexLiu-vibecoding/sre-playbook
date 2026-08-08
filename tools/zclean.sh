#!/bin/bash
# version: 0.9.2 (multi-dir support)
export LANG=C
export PATH=/sbin:/bin:/usr/local/sbin:/usr/sbin:/usr/local/bin:/usr/bin:/usr/local/bin:/bin:/usr/bin:/usr/X11R6/bin:/home/admin/bin

# 支持多个日志目录
readonly LOGS_DIRS=(
    /home/admin/logs
    /home/admin/app-run/target/lib/logs
)

readonly CONF_FILE=/home/admin/conf/zclean.conf
readonly RESERVE=14
DELETE_FLAG='-delete'
DEBUG=''
CHUNK_SIZE=''
INTERACTIVE=0
ZCLEAN_DIGEST="/home/admin/logs/zclean.log.$(date +%F)"

{
    readonly ZCLEAN_OK=1
    readonly ZCLEAN_CRUSH=2
    readonly ZCLEAN_ERROR=3
    readonly ZCLEAN_IGNORE=4
}

# 检查至少一个日志目录存在
has_valid_dir=0
for dir in "${LOGS_DIRS[@]}"; do
    if [[ -d "$dir" ]]; then
        has_valid_dir=1
        break
    fi
done
[[ $has_valid_dir -eq 0 ]] && exit

CMD_PREFIX=''
if $(which ionice >& /dev/null); then
    CMD_PREFIX="ionice -c3 "
fi
if $(which nice >& /dev/null); then
    CMD_PREFIX="nice -n 19 $CMD_PREFIX"
fi
FIND_CMD="${CMD_PREFIX}find"
RM_CMD="${CMD_PREFIX}rm"

TRUNCATE_CMD=''
if $(which truncate >& /dev/null); then
    TRUNCATE_CMD="${CMD_PREFIX}truncate"
fi

LSOF_CMD=''
if $(which lsof >& /dev/null); then
    LSOF_CMD="lsof"
fi

LSOF_FILE=/tmp/zclean_lsof.out
if [[ -d /dev/shm ]]; then
    shm_mode=$(stat -c "%A"  /dev/shm)
    if [[ $shm_mode == drwxrwxrwt ]]; then
        LSOF_FILE=/dev/shm/zclean_lsof.out
    fi
fi

prepare_lsof() {
    # workaround for Alios7 kernel bug
    if [[ $HOSTNAME =~ paycorecloud-30- ]]; then
        for dir in "${LOGS_DIRS[@]}"; do
            [[ -d "$dir" ]] && $FIND_CMD "$dir" -name '*.log' >> "$LSOF_FILE"
        done
        return
    fi
    if [[ $HOSTNAME =~ paycorecloud-31- ]]; then
        for dir in "${LOGS_DIRS[@]}"; do
            [[ -d "$dir" ]] && $FIND_CMD "$dir" -name '*.log' >> "$LSOF_FILE"
        done
        return
    fi
    if [[ -n $LSOF_CMD ]]; then
        ulimit -n 1024
        > "$LSOF_FILE"  # 清空文件
        for dir in "${LOGS_DIRS[@]}"; do
            [[ -d "$dir" ]] && $LSOF_CMD +D "$dir" 2>/dev/null >> "$LSOF_FILE"
        done
    fi
}

delete_lsof() {
    $RM_CMD -rf "$LSOF_FILE"
}

file_in_lsof() {
    local fpath=$1
    if [[ -n $LSOF_CMD && -f $LSOF_FILE ]]; then
        grep -qF "$fpath" "$LSOF_FILE"  # -F 避免正则问题
        return $?
    else
        return 1
    fi
}

log_error() {
    echo "$(date +"%F %T") [ERROR] $@" >> "$ZCLEAN_DIGEST"
}

log_info() {
    echo "$(date +"%F %T") [INFO] $@" >> "$ZCLEAN_DIGEST"
}

log_warn() {
    echo "$(date +"%F %T") [WARN] $@" >> "$ZCLEAN_DIGEST"
}

log_debug() {
    [[ $DEBUG != '-debug' ]] && return
    echo "$(date +"%F %T") [DEBUG] $@" >> "$ZCLEAN_DIGEST"
}

delete_files() {
    [[ $DELETE_FLAG != '-delete' ]] && return
    $RM_CMD -rf "$@" >& /dev/null
}

crush_files() {
    [[ $DELETE_FLAG != '-delete' ]] && return
    for f in "$@"; do
        > "$f"
    done
}

clean_file() {
    local fpath=$1
    local fsize=$2
    local chunksize=${CHUNK_SIZE:-20}

    if [[ $DELETE_FLAG != '-delete' || ! -f $fpath ]]; then
        return $ZCLEAN_ERROR
    fi

    local is_open=0
    if file_in_lsof "$fpath" >& /dev/null; then
        is_open=1
    fi

    if [[ $is_open -eq 1 && $fsize -eq 0 ]]; then
        log_debug "ignore $fpath(+) size $fsize"
        return $ZCLEAN_IGNORE
    fi

    if [[ $chunksize -eq 0 || -z $TRUNCATE_CMD ]]; then
        if [[ $is_open -eq 1 ]]; then
            crush_files "$fpath"
            log_debug "removed $fpath(+) size $fsize directly"
        else
            delete_files "$fpath"
            log_debug "removed $fpath size $fsize directly"
        fi
    else
        local tstart=$SECONDS
        local tstake=$((1+tstart))
        local loop=$((fsize/(1048576*chunksize)+1))
        local tdiff
        if [[ $fsize -eq 0 ]]; then
            loop=0
        fi
        for ((i=0; i<loop; ++i)); do
            $TRUNCATE_CMD -s "-${chunksize}M" "$fpath"
            tdiff=$((tstake-SECONDS))
            if [[ $tdiff -gt 0 ]]; then
                sleep $tdiff
            fi
            tstake=$((tstake+1))
        done
        if [[ $is_open -eq 1 ]]; then
            log_debug "removed $fpath(+) size $fsize in $((SECONDS-tstart)) seconds"
        else
            log_debug "removed $fpath size $fsize in $((SECONDS-tstart)) seconds"
        fi
    fi

    if [[ -n $LSOF_CMD && $is_open -eq 0 ]]; then
        delete_files "$fpath"
        return $ZCLEAN_OK
    else
        return $ZCLEAN_CRUSH
    fi
}

get_home_usage() {
    local usage
    usage=$(df /home/admin/logs | awk 'END {print $5}' | tr -d '%')
    if [[ -z $usage ]]; then
        log_error "can't get home partition usage"
        exit 1
    fi
    echo $usage
}

sleep_dif() {
    local secs idc index
    if [[ $HOSTNAME =~ ^[a-z0-9]+-[0-9]+-[0-9]+$ ]]; then
        idc=$(echo $HOSTNAME|awk -F- '{print $2}')
        index=$(echo $HOSTNAME|awk -F- '{print $3}')
        secs=$(( (index*19 +idc*7)%233 ))
    else
        secs=$((RANDOM%133))
    fi
    sleep $secs
    log_info slept $secs seconds
}

clean_expired() {
    local keep_days=$((RESERVE-1))
    if [[ $HOSTNAME =~ paycorecloud-30- ]]; then
        keep_days=1
    fi

    for LOGS_DIR in "${LOGS_DIRS[@]}"; do
        [[ ! -d "$LOGS_DIR" ]] && continue

        $FIND_CMD "$LOGS_DIR" \
            -type f \
            -name '*log*' \
            ! -name '*\.[0-9]dt\.log*' \
            ! -name '*\.[0-9][0-9]dt\.log*' \
            ! -name '*\.[0-9][0-9][0-9]dt\.log*' \
            -mtime +$keep_days \
            -printf '%p %s\n' | \
        while read -r fpath fsize; do
            clean_file "$fpath" "$fsize"
            ret_code=$?
            if [[ $ret_code -eq $ZCLEAN_OK || $ret_code -eq $ZCLEAN_CRUSH ]]; then
                log_info "deleted expired file $fpath size $fsize"
            fi
        done

        $FIND_CMD "$LOGS_DIR" \
            -type f \
            \( -name '*\.[0-9]dt\.log*' -o \
               -name '*\.[0-9][0-9]dt\.log*' -o \
               -name '*\.[0-9][0-9][0-9]dt\.log*' \) \
            -printf '%p %s %TY-%Tm-%Td\n' | \
        while read -r fpath fsize fmtime; do
            how_long=$(echo "$fpath" | grep -o '[0-9]\+dt' | tr -d '[a-z]')
            if [[ -z "$how_long" ]]; then
                continue
            fi
            expired=$(date -d"$how_long days ago" +"%F")
            if [[ $fmtime > $expired ]]; then
                continue
            else
                clean_file "$fpath" "$fsize"
                ret_code=$?
                if [[ $ret_code -eq $ZCLEAN_OK || $ret_code -eq $ZCLEAN_CRUSH ]]; then
                    log_info "deleted expired file $fpath size $fsize"
                fi
            fi
        done
    done
}

clean_huge() {
    local blocks big_size fpath fsize 
    blocks=$(df /home -k | awk 'END {print $2}')
    if [[ ! $? ]]; then
        log_error "can't get home partition total size"
        exit 1
    fi
    if [[ $blocks -ge 125829120 ]]; then
        big_size=50G
    else
        big_size=30G
    fi

    for LOGS_DIR in "${LOGS_DIRS[@]}"; do
        [[ ! -d "$LOGS_DIR" ]] && continue

        $FIND_CMD "$LOGS_DIR" \
            -type f \
            -name '*log*' \
            -size +$big_size \
            -printf '%p %s\n' | \
        while read -r fpath fsize; do
            crush_files "$fpath"
            log_warn "deleted huge file $fpath size $fsize"
        done
    done
}

clean_by_day() {
    local how_long=$1
    for LOGS_DIR in "${LOGS_DIRS[@]}"; do
        [[ ! -d "$LOGS_DIR" ]] && continue

        $FIND_CMD "$LOGS_DIR" \
            -type f \
            -name '*log*' \
            -mtime "+${how_long}" \
            -printf '%p %s\n' | \
        while read -r fpath fsize; do
            clean_file "$fpath" "$fsize"
            ret_code=$?
            if [[ $ret_code -eq $ZCLEAN_OK || $ret_code -eq $ZCLEAN_CRUSH ]]; then
                log_info "deleted $((how_long+1)) days ago file $fpath size $fsize"
            fi
        done
    done
}

clean_by_hour() {
    local how_long=$1
    for LOGS_DIR in "${LOGS_DIRS[@]}"; do
        [[ ! -d "$LOGS_DIR" ]] && continue

        $FIND_CMD "$LOGS_DIR" \
            -type f \
            -name '*log*' \
            -mmin "+$((how_long*60))" \
            -printf '%p %s\n' | \
        while read -r fpath fsize; do
            clean_file "$fpath" "$fsize"
            ret_code=$?
            if [[ $ret_code -eq $ZCLEAN_OK || $ret_code -eq $ZCLEAN_CRUSH ]]; then
                log_info "deleted $how_long hours ago file $fpath size $fsize"
            fi
        done
    done
}

clean_largest() {
    local fsize fpath fblock
    local ret_code=$ZCLEAN_OK

    # 合并所有目录的文件，找最大的一个
    {
        for LOGS_DIR in "${LOGS_DIRS[@]}"; do
            [[ -d "$LOGS_DIR" ]] && $FIND_CMD "$LOGS_DIR" -type f -printf '%b %s %p\n'
        done
    } | sort -nr | head -1 | \
    while read -r fblock fsize fpath ; do
        if [[ $fsize -gt 10737418240 ]]; then
            crush_files "$fpath"
        else
            clean_file "$fpath" "$fsize"
        fi
        ret_code=$?
        if [[ $ret_code -eq $ZCLEAN_OK || $ret_code -eq $ZCLEAN_CRUSH ]]; then
            log_info "deleted largest file $fpath size $fsize"
        fi
    done
}

in_low_traffic() {
    local now=$(date '+%R')
    if [[ "$now" > "04:00" && "$now" < "04:30" ]]; then
        return 0
    else
        return 1
    fi
}

clean_until() {
    local from_rate to_rate cur_usage old_usage how_long count force
    how_long=$((RESERVE-1))
    from_rate=$1
    to_rate=$2
    force=$3
    count=0

    cur_usage=$(get_home_usage)

    if [[ $cur_usage -ge 97 ]]; then
        clean_huge
        old_usage=$cur_usage
        cur_usage=$(get_home_usage)
        if [[ $cur_usage -ne $old_usage ]]; then
            log_info "usage from $old_usage to $cur_usage"
        fi
    fi

    if ! in_low_traffic; then
        [[ $cur_usage -lt $from_rate ]] && return
    fi

    prepare_lsof

    clean_expired
    old_usage=$cur_usage
    cur_usage=$(get_home_usage)
    if [[ $cur_usage -ne $old_usage ]]; then
        log_info "usage from $old_usage to $cur_usage"
    fi

    while [[ $cur_usage -gt $to_rate ]]; do
        if [[ $how_long -lt 1 ]]; then
            break
        else
            how_long=$((how_long-1))
        fi
        clean_by_day $how_long
        old_usage=$cur_usage
        cur_usage=$(get_home_usage)
        if [[ $cur_usage -ne $old_usage ]]; then
            log_info "usage from $old_usage to $cur_usage"
        fi
    done

    how_long=24
    while [[ $cur_usage -gt $to_rate ]]; do
        if [[ $how_long -lt 2 ]]; then
            break
        else
            how_long=$((how_long-1))
        fi
        clean_by_hour $how_long
        old_usage=$cur_usage
        cur_usage=$(get_home_usage)
        if [[ $cur_usage -ne $old_usage ]]; then
            log_info "usage from $old_usage to $cur_usage"
        fi
    done

    [[ $force -ne 1 ]] && return

    if [[ $CHUNK_SIZE -ne 0 ]]; then
        CHUNK_SIZE=100
    fi
    while [[ $cur_usage -gt $to_rate ]]; do
        if [[ $count -gt 5 ]]; then
            log_error "give up deleting largest files"
            break
        fi
        count=$((count+1))
        clean_largest
        old_usage=$cur_usage
        cur_usage=$(get_home_usage)
        if [[ $cur_usage -ne $old_usage ]]; then
            log_info "usage from $old_usage to $cur_usage"
        fi
    done

    delete_lsof
}

ensure_unique() {
    local pgid=$(ps -p $$ -o pgid=)
    local pids=$(ps -e -o pid,pgid,cmd | \
                    grep "[z]clean" | \
                    awk "\$2 != $pgid {print \$1}")
    if [[ -n $pids ]]; then
        if [[ $INTERACTIVE -eq 1 ]]; then
            kill $pids
        else
            log_info "$0 is running, wait for another round of dispatch"
            exit 0
        fi
    fi
}

_main() { 
    local to_rate=90
    local from_rate=$to_rate
    local do_sleep=0
    local force=0

    if [[ -f $CONF_FILE && ! "$*" =~ --noconf ]]; then
        while IFS= read -r line; do
            [[ -z "$line" || "$line" =~ ^# ]] && continue
            key=$(echo "$line" | cut -d= -f1)
            value=$(echo "$line" | cut -d= -f2)
            case $key in
                to)
                    to_rate=$value;;
                block)
                    CHUNK_SIZE=$value;;
                fast)
                    CHUNK_SIZE=0;;
                from)
                    from_rate=$value;;
                sleep)
                    do_sleep=1;;
                debug)
                    DEBUG='-debug';;
                force)
                    force=1;;
                *)
                    ;;
            esac
        done < "$CONF_FILE"
    fi

    while getopts ":r:b:t:nsdfi" opt; do
        case $opt in
        r)
            if [[ ! $OPTARG =~ ^[0-9]+$ ]]; then
                echo "$0: rate $OPTARG is an invalid number" >&2
                exit 1;
            fi
            if [[ $OPTARG -le 1 || $OPTARG -ge 99 ]]; then
                echo "$0: rate $OPTARG out of range (1, 99)" >&2
                exit 1;
            fi
            to_rate=$OPTARG ;;
        b)
            if [[ ! $OPTARG =~ ^[0-9]+[mMgG]?$ ]]; then
                echo "$0: block size $OPTARG is invalid" >&2
                exit 1;
            fi
            if [[ $OPTARG =~ [gG]$ ]]; then
                CHUNK_SIZE=$(echo "$OPTARG" | tr -d 'gG')
                CHUNK_SIZE=$((CHUNK_SIZE*1024))
            else
                CHUNK_SIZE=$(echo "$OPTARG" | tr -d 'mM')
            fi ;;
        t)
            if [[ ! $OPTARG =~ ^[0-9]+$ ]]; then
                echo "$0: rate $OPTARG is an invalid number" >&2
                exit 1;
            fi
            if [[ $OPTARG -le 1 || $OPTARG -ge 99 ]]; then
                echo "$0: rate $OPTARG out of range (1, 99)" >&2
                exit 1;
            fi
            from_rate=$OPTARG ;;
        n) 
            CHUNK_SIZE=0 ;;
        s)
            do_sleep=1 ;;
        d)
            DEBUG='-debug' ;;
        f)
            force=1 ;;
        i)
            INTERACTIVE=1 ;;
        \?)
            echo "$0: invalid option: -$OPTARG" >&2
            exit 1;;
        :)
            echo "$0: option -$OPTARG requires an argument" >&2
            exit 1 ;;
        esac
    done

    if [[ $to_rate -ge $from_rate ]]; then
        to_rate=$from_rate
    fi

    ensure_unique
    [[ $do_sleep -eq 1 ]] && sleep_dif
    clean_until $from_rate $to_rate $force
}

_main "$@"
