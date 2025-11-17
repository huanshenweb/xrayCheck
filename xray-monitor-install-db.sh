#!/bin/bash

# X-Ray 流量监控工具 - 数据库版
# 支持自动采集、历史查询、流量排名
set -e

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${GREEN}"
cat << "BANNER"
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
   X-Ray 流量监控工具 - 数据库版 v2.4
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
BANNER
echo -e "${NC}"

# 检测系统
if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS=$ID
    echo -e "${YELLOW}检测到系统: $PRETTY_NAME${NC}"
else
    echo -e "${RED}无法检测系统类型${NC}"
    exit 1
fi

# ==================== 智能端口检测 ====================
echo -e "${YELLOW}正在检测 X-Ray 端口...${NC}"

declare -A PORT_LISTEN_MAP
while IFS= read -r line; do
    listen_addr=$(echo "$line" | awk '{print $4}')
    port=$(echo "$listen_addr" | grep -oP ':\K[0-9]+$')
    [ -n "$port" ] && PORT_LISTEN_MAP[$port]=$listen_addr
done < <(ss -tlnp | grep xray 2>/dev/null)

PUBLIC_PORTS=()
LOCAL_PORTS=()

for port in "${!PORT_LISTEN_MAP[@]}"; do
    listen_addr="${PORT_LISTEN_MAP[$port]}"
    if [[ "$listen_addr" =~ ^0\.0\.0\.0: ]] || \
       [[ "$listen_addr" =~ ^\*: ]] || \
       [[ "$listen_addr" =~ ^\[?::(\]|0)?: ]]; then
        PUBLIC_PORTS+=($port)
    elif [[ "$listen_addr" =~ ^127\. ]] || [[ "$listen_addr" =~ ^\[?::1 ]]; then
        LOCAL_PORTS+=($port)
    else
        PUBLIC_PORTS+=($port)
    fi
done

if [ ${#PUBLIC_PORTS[@]} -eq 0 ] && [ ${#LOCAL_PORTS[@]} -eq 0 ]; then
    echo -e "${YELLOW}未自动检测到 X-Ray 端口，请手动输入:${NC}"
    read -p "请输入 X-Ray 监听端口 (默认 32252): " INPUT_PORT
    XRAY_PORT=${INPUT_PORT:-32252}
elif [ ${#PUBLIC_PORTS[@]} -eq 1 ]; then
    XRAY_PORT=${PUBLIC_PORTS[0]}
    echo -e "${GREEN}✓ 自动检测到公网端口: $XRAY_PORT (${PORT_LISTEN_MAP[$XRAY_PORT]})${NC}"
    [ ${#LOCAL_PORTS[@]} -gt 0 ] && echo -e "${YELLOW}  已忽略 ${#LOCAL_PORTS[@]} 个本地端口${NC}"
elif [ ${#PUBLIC_PORTS[@]} -gt 1 ]; then
    echo -e "${YELLOW}检测到 ${#PUBLIC_PORTS[@]} 个公网端口:${NC}"
    IFS=$'\n' SORTED_PUBLIC=($(sort -n <<<"${PUBLIC_PORTS[*]}"))
    unset IFS
    for i in "${!SORTED_PUBLIC[@]}"; do
        port=${SORTED_PUBLIC[$i]}
        echo -e "  ${GREEN}[$((i+1))]${NC} 端口 ${YELLOW}$port${NC} (监听: ${PORT_LISTEN_MAP[$port]})"
    done
    [ ${#LOCAL_PORTS[@]} -gt 0 ] && echo -e "${YELLOW}  已忽略 ${#LOCAL_PORTS[@]} 个本地端口${NC}"
    echo ""
    while true; do
        read -p "请选择要监控的端口序号 [1-${#SORTED_PUBLIC[@]}]: " choice
        if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le ${#SORTED_PUBLIC[@]} ]; then
            XRAY_PORT=${SORTED_PUBLIC[$((choice-1))]}
            echo -e "${GREEN}✓ 已选择端口: $XRAY_PORT${NC}"
            break
        else
            echo -e "${RED}无效选择，请输入 1-${#SORTED_PUBLIC[@]} 之间的数字${NC}"
        fi
    done
else
    echo -e "${YELLOW}⚠ 只检测到本地端口 (127.0.0.1)${NC}"
    IFS=$'\n' SORTED_LOCAL=($(sort -n <<<"${LOCAL_PORTS[*]}"))
    unset IFS
    for i in "${!SORTED_LOCAL[@]}"; do
        port=${SORTED_LOCAL[$i]}
        echo -e "  ${YELLOW}[$((i+1))]${NC} 端口 $port (${PORT_LISTEN_MAP[$port]})"
    done
    echo ""
    while true; do
        read -p "请选择端口序号 [1-${#SORTED_LOCAL[@]}], 或输入0手动指定: " choice
        if [[ "$choice" == "0" ]]; then
            read -p "请输入 X-Ray 监听端口: " INPUT_PORT
            if [[ "$INPUT_PORT" =~ ^[0-9]+$ ]] && [ "$INPUT_PORT" -ge 1 ] && [ "$INPUT_PORT" -le 65535 ]; then
                XRAY_PORT=$INPUT_PORT
                break
            fi
        elif [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le ${#SORTED_LOCAL[@]} ]; then
            XRAY_PORT=${SORTED_LOCAL[$((choice-1))]}
            echo -e "${GREEN}✓ 已选择端口: $XRAY_PORT${NC}"
            break
        else
            echo -e "${RED}无效选择${NC}"
        fi
    done
fi
# ==================== 端口检测结束 ====================

echo -e "${GREEN}✓ 将监控端口: $XRAY_PORT${NC}"

# 安装依赖
echo -e "${YELLOW}正在安装必要的依赖包...${NC}"
if [ "$OS" = "ubuntu" ] || [ "$OS" = "debian" ]; then
    apt update -qq
    apt install -y iptables iproute2 gawk sqlite3 bc >/dev/null 2>&1
elif [ "$OS" = "centos" ] || [ "$OS" = "rhel" ]; then
    yum install -y iptables iproute gawk sqlite bc >/dev/null 2>&1
fi
echo -e "${GREEN}✓ 依赖安装完成${NC}"

# 创建监控脚本
echo -e "${YELLOW}正在创建监控脚本...${NC}"
cat > /usr/local/bin/xray-monitor << 'SCRIPT_EOF'
#!/bin/bash
# X-Ray 流量监控脚本 - 数据库版
PORT=PORT_PLACEHOLDER
DB_PATH="/var/lib/xray-monitor/traffic.db"
INTERVAL=60  # 1分钟采集间隔

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# 初始化数据库
init_db() {
    mkdir -p /var/lib/xray-monitor
    sqlite3 "$DB_PATH" <<SQL
CREATE TABLE IF NOT EXISTS traffic_records (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    ip_address TEXT NOT NULL,
    bytes_in INTEGER DEFAULT 0,
    bytes_out INTEGER DEFAULT 0,
    bytes_total INTEGER DEFAULT 0,
    timestamp INTEGER NOT NULL,
    created_at DATETIME DEFAULT CURRENT_TIMESTAMP
);
CREATE INDEX IF NOT EXISTS idx_timestamp ON traffic_records(timestamp);
CREATE INDEX IF NOT EXISTS idx_ip ON traffic_records(ip_address);
CREATE INDEX IF NOT EXISTS idx_ip_time ON traffic_records(ip_address, timestamp);
SQL
}

# 采集流量数据
collect_traffic() {
    local current_time=$(date +%s)

    # 获取活跃IP列表
    local ips=$(ss -tn state established "( dport = :$PORT or sport = :$PORT )" 2>/dev/null | \
                tail -n +2 | \
                awk '{print $4}' | \
                sed 's/\[::ffff://g;s/\]:[0-9]*$//g' | \
                grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | \
                sort -u)

    if [ -z "$ips" ]; then
        return 0
    fi

    # 创建临时iptables链
    iptables -N XRAY_COLLECT 2>/dev/null || iptables -F XRAY_COLLECT
    iptables -D INPUT -p tcp --dport $PORT -j XRAY_COLLECT 2>/dev/null
    iptables -D OUTPUT -p tcp --sport $PORT -j XRAY_COLLECT 2>/dev/null

    # 添加规则
    for ip in $ips; do
        iptables -A XRAY_COLLECT -s $ip -j ACCEPT
        iptables -A XRAY_COLLECT -d $ip -j ACCEPT
    done

    iptables -I INPUT -p tcp --dport $PORT -j XRAY_COLLECT
    iptables -I OUTPUT -p tcp --sport $PORT -j XRAY_COLLECT

    # 等待采集
    sleep $INTERVAL

    # 读取流量数据并写入数据库
    iptables -L XRAY_COLLECT -v -n -x | awk -v ts="$current_time" 'NR>2 {
        if ($8 ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/) {
            in_bytes[$8] += $2
        }
        if ($9 ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/) {
            out_bytes[$9] += $2
        }
    }
    END {
        for (ip in in_bytes) all_ips[ip] = 1
        for (ip in out_bytes) all_ips[ip] = 1

        for (ip in all_ips) {
            in_b = in_bytes[ip] + 0
            out_b = out_bytes[ip] + 0
            total_b = in_b + out_b
            if (total_b > 0) {
                printf "%s|%d|%d|%d\n", ip, in_b, out_b, total_b
            }
        }
    }' | while IFS='|' read ip bytes_in bytes_out bytes_total; do
        sqlite3 "$DB_PATH" "INSERT INTO traffic_records (ip_address, bytes_in, bytes_out, bytes_total, timestamp) VALUES ('$ip', $bytes_in, $bytes_out, $bytes_total, $current_time);"
    done

    # 清理iptables规则
    iptables -D INPUT -p tcp --dport $PORT -j XRAY_COLLECT 2>/dev/null
    iptables -D OUTPUT -p tcp --sport $PORT -j XRAY_COLLECT 2>/dev/null
    iptables -F XRAY_COLLECT
    iptables -X XRAY_COLLECT
}

# 启动后台监控
start_daemon() {
    if [ -f /var/run/xray-monitor.pid ]; then
        local pid=$(cat /var/run/xray-monitor.pid)
        if ps -p $pid > /dev/null 2>&1; then
            echo -e "${YELLOW}监控服务已在运行 (PID: $pid)${NC}"
            return 0
        fi
    fi

    init_db

    echo -e "${YELLOW}正在启动后台监控服务...${NC}"
    nohup bash -c "
        while true; do
            $0 _collect_internal
            sleep 1
        done
    " > /var/log/xray-monitor.log 2>&1 &

    echo $! > /var/run/xray-monitor.pid
    echo -e "${GREEN}✓ 监控服务已启动 (PID: $!)${NC}"
    echo -e "${CYAN}  采集间隔: 1分钟${NC}"
    echo -e "${CYAN}  数据库: $DB_PATH${NC}"
    echo -e "${CYAN}  日志: /var/log/xray-monitor.log${NC}"
}

# 停止监控
stop_daemon() {
    if [ ! -f /var/run/xray-monitor.pid ]; then
        echo -e "${YELLOW}监控服务未运行${NC}"
        return 0
    fi

    local pid=$(cat /var/run/xray-monitor.pid)
    if ps -p $pid > /dev/null 2>&1; then
        kill $pid
        rm -f /var/run/xray-monitor.pid
        echo -e "${GREEN}✓ 监控服务已停止${NC}"
    else
        rm -f /var/run/xray-monitor.pid
        echo -e "${YELLOW}监控服务未运行${NC}"
    fi
}

# 查看服务状态
show_daemon_status() {
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BLUE}  监控服务状态${NC}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

    if [ -f /var/run/xray-monitor.pid ]; then
        local pid=$(cat /var/run/xray-monitor.pid)
        if ps -p $pid > /dev/null 2>&1; then
            echo -e "状态: ${GREEN}运行中${NC}"
            echo -e "PID: ${GREEN}$pid${NC}"
            echo -e "端口: ${GREEN}$PORT${NC}"
            echo -e "采集间隔: ${GREEN}1分钟${NC}"

            # 显示数据库统计
            if [ -f "$DB_PATH" ]; then
                local record_count=$(sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM traffic_records;")
                local ip_count=$(sqlite3 "$DB_PATH" "SELECT COUNT(DISTINCT ip_address) FROM traffic_records;")
                local oldest=$(sqlite3 "$DB_PATH" "SELECT datetime(MIN(timestamp), 'unixepoch', 'localtime') FROM traffic_records;" 2>/dev/null)
                local newest=$(sqlite3 "$DB_PATH" "SELECT datetime(MAX(timestamp), 'unixepoch', 'localtime') FROM traffic_records;" 2>/dev/null)

                echo -e "数据记录: ${GREEN}$record_count 条${NC}"
                echo -e "唯一IP: ${GREEN}$ip_count 个${NC}"
                [ -n "$oldest" ] && echo -e "最早记录: ${CYAN}$oldest${NC}"
                [ -n "$newest" ] && echo -e "最新记录: ${CYAN}$newest${NC}"
            fi
        else
            echo -e "状态: ${RED}已停止${NC}"
            rm -f /var/run/xray-monitor.pid
        fi
    else
        echo -e "状态: ${RED}未运行${NC}"
    fi

    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

# 查询流量统计
query_traffic() {
    local minutes=${1:-60}
    local top_n=${2:-10}

    if [ ! -f "$DB_PATH" ]; then
        echo -e "${RED}✗ 数据库不存在，请先启动监控服务${NC}"
        return 1
    fi

    local start_time=$(($(date +%s) - minutes * 60))

    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BLUE}  流量统计 - 最近 ${minutes} 分钟 (Top ${top_n})${NC}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

    sqlite3 "$DB_PATH" <<SQL
.mode column
.headers off
SELECT
    ROW_NUMBER() OVER (ORDER BY total_mb DESC) as rank,
    ip_address,
    PRINTF('%.2f', in_mb) || ' MB' as 入站,
    PRINTF('%.2f', out_mb) || ' MB' as 出站,
    PRINTF('%.2f', total_mb) || ' MB' as 总计
FROM (
    SELECT
        ip_address,
        SUM(bytes_in) / 1048576.0 as in_mb,
        SUM(bytes_out) / 1048576.0 as out_mb,
        SUM(bytes_total) / 1048576.0 as total_mb
    FROM traffic_records
    WHERE timestamp >= $start_time
    GROUP BY ip_address
    ORDER BY total_mb DESC
    LIMIT $top_n
);
SQL

    # 显示汇总
    local summary=$(sqlite3 "$DB_PATH" "SELECT
        PRINTF('%.2f', SUM(bytes_in) / 1048576.0),
        PRINTF('%.2f', SUM(bytes_out) / 1048576.0),
        PRINTF('%.2f', SUM(bytes_total) / 1048576.0),
        PRINTF('%.2f', SUM(bytes_total) / 1073741824.0),
        COUNT(DISTINCT ip_address)
    FROM traffic_records WHERE timestamp >= $start_time;")

    IFS='|' read -r total_in total_out total_mb total_gb unique_ips <<< "$summary"

    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "总入站: ${GREEN}${total_in} MB${NC}  |  总出站: ${GREEN}${total_out} MB${NC}"
    echo -e "总流量: ${GREEN}${total_mb} MB${NC} (${GREEN}${total_gb} GB${NC})  |  唯一IP: ${GREEN}${unique_ips}${NC}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

# 清除数据库
clear_database() {
    echo -e "${YELLOW}⚠️  警告：此操作将删除所有历史流量数据！${NC}"
    read -p "确认清除数据库？(yes/no): " confirm

    if [ "$confirm" = "yes" ]; then
        if [ -f "$DB_PATH" ]; then
            sqlite3 "$DB_PATH" "DELETE FROM traffic_records;"
            sqlite3 "$DB_PATH" "VACUUM;"
            echo -e "${GREEN}✓ 数据库已清空${NC}"
        else
            echo -e "${YELLOW}数据库不存在${NC}"
        fi
    else
        echo -e "${YELLOW}操作已取消${NC}"
    fi
}

# 实时监控
show_realtime() {
    echo -e "${YELLOW}实时连接监控 (按 Ctrl+C 退出)${NC}"
    echo ""

    while true; do
        clear
        echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo -e "${BLUE}  实时连接状态 (端口: $PORT)${NC}"
        echo -e "${BLUE}  $(date '+%Y-%m-%d %H:%M:%S')${NC}"
        echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

        # 获取连接数据
        local connections=$(ss -tn state established "( dport = :$PORT or sport = :$PORT )" 2>/dev/null)
        local total=$(echo "$connections" | tail -n +2 | wc -l)

        # 提取并统计唯一IP
        local ip_list=$(echo "$connections" | \
                       tail -n +2 | \
                       awk '{print $4}' | \
                       sed 's/\[::ffff://g;s/\]:[0-9]*$//g' | \
                       grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | \
                       sort -u)

        local unique=$(echo "$ip_list" | grep -v '^$' | wc -l)

        echo -e "总连接数: ${GREEN}$total${NC}  |  唯一IP: ${GREEN}$unique${NC}"
        echo ""

        if [ $unique -gt 0 ]; then
            echo -e "${CYAN}连接数排名 (Top 10):${NC}"

            echo "$connections" | \
                tail -n +2 | \
                awk '{print $4}' | \
                sed 's/\[::ffff://g;s/\]:[0-9]*$//g' | \
                grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | \
                sort | uniq -c | sort -rn | head -10 | \
                awk '{printf "  %2d. %-18s %3d 个连接\n", NR, $2, $1}'

            # 显示活跃IP示例
            if [ $unique -le 5 ]; then
                echo ""
                echo -e "${YELLOW}活跃IP列表:${NC}"
                echo "$ip_list" | awk '{printf "  • %s\n", $1}'
            fi
        else
            echo -e "${YELLOW}当前没有活跃连接${NC}"
        fi

        echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

        sleep 3
    done
}

# 测试连接
test_connection() {
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BLUE}  连接测试 (端口: $PORT)${NC}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

    # 测试ss命令
    local connections=$(ss -tn state established "( dport = :$PORT or sport = :$PORT )" 2>/dev/null)
    local total=$(echo "$connections" | tail -n +2 | wc -l)

    echo -e "总连接数: ${GREEN}$total${NC}"
    echo ""

    if [ $total -gt 0 ]; then
        echo -e "${YELLOW}原始连接数据（前5行）:${NC}"
        echo "$connections" | head -6
        echo ""

        echo -e "${YELLOW}提取的IP地址（前10个）:${NC}"
        echo "$connections" | \
            tail -n +2 | \
            awk '{print $4}' | \
            sed 's/\[::ffff://g;s/\]:[0-9]*$//g' | \
            grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | \
            sort -u | \
            head -10 | \
            awk '{printf "  • %s\n", $1}'

        local unique=$(echo "$connections" | \
                      tail -n +2 | \
                      awk '{print $4}' | \
                      sed 's/\[::ffff://g;s/\]:[0-9]*$//g' | \
                      grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | \
                      sort -u | wc -l)

        echo ""
        echo -e "唯一IP数: ${GREEN}$unique${NC}"
    else
        echo -e "${YELLOW}当前没有活跃连接${NC}"
    fi

    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

# 帮助信息
show_help() {
    cat << HELP
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  X-Ray 流量监控工具 v2.4 - 数据库版
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

服务管理:
  start             启动后台监控服务
  stop              停止后台监控服务
  restart           重启监控服务
  status            查看服务状态

流量查询:
  query <分钟> [Top N]    查询指定时间段的流量统计
                          分钟: 查询时间范围（默认60分钟）
                          Top N: 显示前N名（默认10）

查询示例:
  xray-monitor query 10 5      # 查询最近10分钟，显示前5名
  xray-monitor query 30        # 查询最近30分钟，显示前10名
  xray-monitor query 60 20     # 查询最近1小时，显示前20名
  xray-monitor query 1440      # 查询最近24小时
  xray-monitor query 2880      # 查询最近48小时

实时监控:
  realtime          实时显示当前连接状态

数据库管理:
  cleardb           清空数据库（删除所有历史数据）

调试工具:
  test              测试连接检测和IP提取

其他:
  help              显示此帮助信息

配置信息:
  监控端口: $PORT
  数据库: $DB_PATH
  采集间隔: 1分钟

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
HELP
}

# 主程序
case "${1:-help}" in
    start)
        start_daemon
        ;;
    stop)
        stop_daemon
        ;;
    restart)
        stop_daemon
        sleep 2
        start_daemon
        ;;
    status)
        show_daemon_status
        ;;
    query)
        minutes=${2:-60}
        top_n=${3:-10}
        query_traffic $minutes $top_n
        ;;
    realtime)
        show_realtime
        ;;
    test)
        test_connection
        ;;
    cleardb)
        clear_database
        ;;
    _collect_internal)
        # 内部调用，用于后台采集
        init_db
        collect_traffic
        ;;
    help|--help|-h)
        show_help
        ;;
    *)
        show_help
        ;;
esac
SCRIPT_EOF

# 替换端口
sed -i "s/PORT_PLACEHOLDER/$XRAY_PORT/g" /usr/local/bin/xray-monitor
chmod +x /usr/local/bin/xray-monitor
echo -e "${GREEN}✓ 监控脚本创建完成${NC}"

# 创建卸载脚本
cat > /usr/local/bin/xray-monitor-uninstall << 'UNINSTALL_EOF'
#!/bin/bash

YELLOW='\033[1;33m'
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${YELLOW}正在卸载 X-Ray 监控工具...${NC}"
echo ""

# 停止并禁用 systemd 服务
if [ -f /etc/systemd/system/xray-monitor.service ]; then
    echo -e "${YELLOW}正在停止 systemd 服务...${NC}"
    systemctl stop xray-monitor 2>/dev/null
    systemctl disable xray-monitor 2>/dev/null
    rm -f /etc/systemd/system/xray-monitor.service
    systemctl daemon-reload
    echo -e "${GREEN}✓ 已移除 systemd 服务${NC}"
fi

# 停止后台进程（如果存在）
if [ -f /var/run/xray-monitor.pid ]; then
    pid=$(cat /var/run/xray-monitor.pid)
    if ps -p $pid > /dev/null 2>&1; then
        kill $pid
        echo -e "${GREEN}✓ 已停止后台进程${NC}"
    fi
    rm -f /var/run/xray-monitor.pid
fi

# 询问是否删除数据库
echo ""
read -p "是否删除数据库文件（包含所有历史数据）？(yes/no): " del_db
if [ "$del_db" = "yes" ]; then
    rm -rf /var/lib/xray-monitor
    echo -e "${GREEN}✓ 已删除数据库${NC}"
else
    echo -e "${YELLOW}✓ 已保留数据库文件${NC}"
    echo -e "${CYAN}  数据库位置: /var/lib/xray-monitor/traffic.db${NC}"
fi

# 删除脚本和日志
rm -f /usr/local/bin/xray-monitor
rm -f /usr/local/bin/xray-monitor-uninstall
rm -f /var/log/xray-monitor.log

echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}  ✓ 卸载完成！${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
UNINSTALL_EOF
chmod +x /usr/local/bin/xray-monitor-uninstall

# 创建 systemd 服务
echo -e "${YELLOW}正在配置开机自启...${NC}"
cat > /etc/systemd/system/xray-monitor.service << 'SERVICE_EOF'
[Unit]
Description=X-Ray Traffic Monitor Service
Documentation=https://github.com/huanshenweb/xrayCheck
After=network-online.target
Wants=network-online.target

[Service]
Type=forking
ExecStart=/usr/local/bin/xray-monitor start
ExecStop=/usr/local/bin/xray-monitor stop
ExecReload=/usr/local/bin/xray-monitor restart

# 自动重启配置
Restart=always
RestartSec=10

# 资源限制
LimitNOFILE=65535

# 日志
StandardOutput=journal
StandardError=journal

# 运行用户
User=root

[Install]
WantedBy=multi-user.target
SERVICE_EOF

# 重新加载 systemd
systemctl daemon-reload

# 启用开机自启
systemctl enable xray-monitor >/dev/null 2>&1

# 启动服务
systemctl start xray-monitor

echo -e "${GREEN}✓ 已配置开机自启${NC}"

# 等待服务启动
sleep 2

# 完成提示
echo -e "\n${GREEN}"
cat << "SUCCESS"
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  ✓ 安装成功！ (v2.4)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
SUCCESS
echo -e "${NC}"

echo -e "${BLUE}已配置监控端口: ${GREEN}$XRAY_PORT${NC}"
echo -e "${GREEN}✓ 服务已自动启动并配置开机自启${NC}"
echo ""
echo -e "${YELLOW}服务管理:${NC}"
echo -e "  ${GREEN}systemctl status xray-monitor${NC}   # 查看服务状态"
echo -e "  ${GREEN}systemctl restart xray-monitor${NC}  # 重启服务"
echo -e "  ${GREEN}systemctl stop xray-monitor${NC}     # 停止服务"
echo -e "  ${GREEN}xray-monitor status${NC}             # 查看监控状态"
echo ""
echo -e "${YELLOW}流量查询 (等待2-3分钟后可用):${NC}"
echo -e "  ${GREEN}xray-monitor query 5${NC}            # 最近5分钟"
echo -e "  ${GREEN}xray-monitor query 10 20${NC}        # 最近10分钟（前20名）"
echo -e "  ${GREEN}xray-monitor query 60${NC}           # 最近1小时"
echo -e "  ${GREEN}xray-monitor query 1440${NC}         # 最近24小时"
echo ""
echo -e "${YELLOW}实时监控:${NC}"
echo -e "  ${GREEN}xray-monitor realtime${NC}           # 实时显示连接状态"
echo -e "  ${GREEN}xray-monitor test${NC}               # 测试连接检测"
echo ""
echo -e "${YELLOW}数据管理:${NC}"
echo -e "  ${GREEN}xray-monitor cleardb${NC}            # 清空数据库"
echo ""
echo -e "${YELLOW}卸载命令:${NC}"
echo -e "  ${RED}xray-monitor-uninstall${NC}          # 完整卸载（含systemd服务）"
echo ""
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo -e "${CYAN}📊 服务信息:${NC}"
echo -e "  采集间隔: ${GREEN}1分钟${NC}"
echo -e "  数据库: ${CYAN}/var/lib/xray-monitor/traffic.db${NC}"
echo -e "  服务状态: ${GREEN}运行中${NC}"
echo -e "  开机自启: ${GREEN}已启用${NC}"
echo ""
echo -e "${YELLOW}💡 提示: 服务已自动启动，等待2-3分钟后即可查询流量数据${NC}"

