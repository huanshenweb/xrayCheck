#!/bin/bash

# X-Ray 流量监控工具 - 一键安装脚本
# 适用于 Ubuntu/Debian 系统
set -e

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${GREEN}"
cat << "BANNER"
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
   X-Ray 流量监控工具 - 一键安装
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

# 获取所有端口及其监听地址
declare -A PORT_LISTEN_MAP
while IFS= read -r line; do
    listen_addr=$(echo "$line" | awk '{print $4}')
    port=$(echo "$listen_addr" | grep -oP ':\K[0-9]+$')
    [ -n "$port" ] && PORT_LISTEN_MAP[$port]=$listen_addr
done < <(ss -tlnp | grep xray 2>/dev/null)

# 分类端口：公网端口和本地端口
PUBLIC_PORTS=()
LOCAL_PORTS=()

for port in "${!PORT_LISTEN_MAP[@]}"; do
    listen_addr="${PORT_LISTEN_MAP[$port]}"
    # 判断是否为公网端口（监听 0.0.0.0, ::, *, [::]）
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

# 智能选择端口
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
    apt install -y iptables iproute2 gawk >/dev/null 2>&1
elif [ "$OS" = "centos" ] || [ "$OS" = "rhel" ]; then
    yum install -y iptables iproute gawk >/dev/null 2>&1
fi
echo -e "${GREEN}✓ 依赖安装完成${NC}"

# 创建监控脚本
echo -e "${YELLOW}正在创建监控脚本...${NC}"
cat > /usr/local/bin/xray-monitor << 'SCRIPT_EOF'
#!/bin/bash
# X-Ray 流量监控脚本
PORT=PORT_PLACEHOLDER
DEFAULT_DURATION=300

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

show_help() {
    cat << HELP
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  X-Ray 流量监控工具 v1.0
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

用法:
  xray-monitor [命令] [参数]

命令:
  monitor <秒数>    监控指定时间的流量 (默认300秒)
  status            查看当前连接状态
  top [数量]        显示连接数最多的IP (默认10个)
  help              显示此帮助信息

快捷用法:
  xray-monitor 300     # 直接监控5分钟
  xray-monitor 3600    # 直接监控1小时

示例:
  xray-monitor monitor 300     # 监控5分钟
  xray-monitor monitor 3600    # 监控1小时
  xray-monitor status          # 查看当前状态
  xray-monitor top 20          # 显示前20个IP

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
HELP
}

show_status() {
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BLUE}  当前连接状态 (端口: $PORT)${NC}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    
    TOTAL=$(ss -tn | grep :$PORT | wc -l)
    UNIQUE_IPS=$(ss -tn | grep :$PORT | awk '{print $5}' | sed 's/\[::ffff://g;s/\]:[0-9]*$//g' | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | sort -u | wc -l)
    
    echo -e "总连接数: ${GREEN}$TOTAL${NC}"
    echo -e "唯一IP数: ${GREEN}$UNIQUE_IPS${NC}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

show_top_ips() {
    local top_count=${1:-10}
    
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BLUE}  连接数最多的 $top_count 个IP${NC}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    
    ss -tn | grep :$PORT | awk '{print $5}' | \
        sed 's/\[::ffff://g;s/\]:[0-9]*$//g' | \
        grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | \
        sort | uniq -c | sort -rn | head -n $top_count | \
        awk '{printf "%2d. %-18s %s 个连接\n", NR, $2, $1}'
    
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

monitor_traffic() {
    local duration=$1
    
    echo -e "${YELLOW}开始监控端口 $PORT 的流量...${NC}"
    
    IPS=$(ss -tn | grep :$PORT | awk '{print $5}' | \
          sed 's/\[::ffff://g;s/\]:[0-9]*$//g' | \
          sort -u | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$')
    
    if [ -z "$IPS" ]; then
        echo -e "${RED}✗ 当前没有活跃连接${NC}"
        exit 0
    fi
    
    local ip_count=$(echo "$IPS" | wc -l)
    echo -e "${GREEN}✓ 发现 $ip_count 个唯一IP${NC}"
    
    iptables -N XRAY_MON 2>/dev/null || iptables -F XRAY_MON
    iptables -D INPUT -p tcp --dport $PORT -j XRAY_MON 2>/dev/null
    iptables -D OUTPUT -p tcp --sport $PORT -j XRAY_MON 2>/dev/null
    
    for ip in $IPS; do
        iptables -A XRAY_MON -s $ip
        iptables -A XRAY_MON -d $ip
    done
    
    iptables -I INPUT -p tcp --dport $PORT -j XRAY_MON
    iptables -I OUTPUT -p tcp --sport $PORT -j XRAY_MON
    
    echo -e "${YELLOW}监控中，预计 $duration 秒...${NC}"
    
    local minutes=$((duration / 60))
    for ((i=duration; i>0; i--)); do
        if [ $i -eq $duration ] || [ $((i % 60)) -eq 0 ]; then
            echo -e "${YELLOW}⏱  剩余: $((i/60)) 分 $((i%60)) 秒${NC}"
        fi
        sleep 1
    done
    
    echo -e "\n${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}  IP流量统计 (监控时长: ${duration}秒 / $((duration/60))分钟)${NC}"
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    
    iptables -L XRAY_MON -v -n -x | awk 'NR>2 {
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
        
        printf "%-4s %-18s %15s %15s %15s\n", "序号", "IP地址", "入站(MB)", "出站(MB)", "总计(MB)"
        printf "%s\n", "--------------------------------------------------------------------"
        
        rank = 0
        total_all = 0
        for (ip in all_ips) {
            in_mb = in_bytes[ip] / 1048576
            out_mb = out_bytes[ip] / 1048576
            total = in_mb + out_mb
            if (total > 0) {
                rank++
                printf "%-4d %-18s %15.2f %15.2f %15.2f\n", rank, ip, in_mb, out_mb, total
                total_all += total
            }
        }
        printf "%s\n", "===================================================================="
        printf "%-23s %15s %15s %15.2f MB\n", "总计", "", "", total_all
        printf "%-23s %15s %15s %15.2f GB\n", "", "", "", total_all/1024
    }' | sort -k5 -rn | head -22
    
    iptables -D INPUT -p tcp --dport $PORT -j XRAY_MON 2>/dev/null
    iptables -D OUTPUT -p tcp --sport $PORT -j XRAY_MON 2>/dev/null
    iptables -F XRAY_MON
    iptables -X XRAY_MON
    
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}✓ 监控完成${NC}"
}

case "${1:-help}" in
    monitor)
        duration=${2:-$DEFAULT_DURATION}
        monitor_traffic $duration
        ;;
    status)
        show_status
        ;;
    top)
        count=${2:-10}
        show_top_ips $count
        ;;
    help|--help|-h)
        show_help
        ;;
    *)
        if [[ $1 =~ ^[0-9]+$ ]]; then
            monitor_traffic $1
        else
            show_help
        fi
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
echo "正在卸载 X-Ray 监控工具..."
rm -f /usr/local/bin/xray-monitor
rm -f /usr/local/bin/xray-monitor-uninstall
echo "✓ 卸载完成"
UNINSTALL_EOF
chmod +x /usr/local/bin/xray-monitor-uninstall

# 完成提示
echo -e "\n${GREEN}"
cat << "SUCCESS"
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  ✓ 安装成功！
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
SUCCESS
echo -e "${NC}"

echo -e "${YELLOW}快速开始:${NC}"
echo -e "  ${GREEN}xray-monitor status${NC}      # 查看当前状态"
echo -e "  ${GREEN}xray-monitor 300${NC}         # 监控5分钟"
echo -e "  ${GREEN}xray-monitor 3600${NC}        # 监控1小时"
echo -e "  ${GREEN}xray-monitor top 10${NC}      # 查看前10个IP"
echo -e "  ${GREEN}xray-monitor help${NC}        # 查看完整帮助"
echo ""
echo -e "${YELLOW}卸载命令:${NC}"
echo -e "  ${RED}xray-monitor-uninstall${NC}"
echo ""
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

