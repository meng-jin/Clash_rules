#!/bin/bash

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
PLAIN='\033[0m'

CONFIG_DIR="/etc/mihomo"
CONFIG_FILE="$CONFIG_DIR/config.yaml"
BIN_PATH="/usr/local/bin/mihomo"
SERVICE_FILE="/etc/systemd/system/mihomo.service"

if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}错误：必须以 root 身份运行${PLAIN}"
    exit 1
fi

install_dependencies() {
    apt update -y
    apt install -y curl wget tar gzip openssl jq uuid-runtime
}

install_mihomo() {
    if [[ -f "$BIN_PATH" ]]; then
        echo -e "${YELLOW}Mihomo 已安装。${PLAIN}"
        return
    fi

    ARCH=$(uname -m)
    case $ARCH in
        x86_64) download_arch="amd64" ;;
        aarch64) download_arch="arm64" ;;
        *) echo -e "${RED}不支持的架构: $ARCH${PLAIN}"; exit 1 ;;
    esac

    VERSION="v1.19.17"
    URL="https://github.com/MetaCubeX/mihomo/releases/download/${VERSION}/mihomo-linux-${download_arch}-${VERSION}.gz"

    echo -e "${GREEN}正在下载 ${VERSION}...${PLAIN}"
    wget -O mihomo.gz "$URL"
    
    if [[ $? -ne 0 ]]; then
        echo -e "${RED}下载失败。${PLAIN}"
        rm -f mihomo.gz
        exit 1
    fi

    gzip -d mihomo.gz
    mv mihomo "$BIN_PATH"
    chmod +x "$BIN_PATH"

    mkdir -p "$CONFIG_DIR"

    if [[ ! -f "$CONFIG_FILE" ]]; then
        echo "log-level: info" > "$CONFIG_FILE"
        echo "ipv6: true" >> "$CONFIG_FILE"
        echo "allow-lan: true" >> "$CONFIG_FILE"
        echo "mode: rule" >> "$CONFIG_FILE"
        echo "external-controller: 0.0.0.0:9090" >> "$CONFIG_FILE"
        echo "secret: \"mihomo-secret\"" >> "$CONFIG_FILE"
        echo "listeners:" >> "$CONFIG_FILE"
    fi

    echo "[Unit]" > "$SERVICE_FILE"
    echo "Description=Mihomo Daemon" >> "$SERVICE_FILE"
    echo "After=network.target" >> "$SERVICE_FILE"
    echo "[Service]" >> "$SERVICE_FILE"
    echo "Type=simple" >> "$SERVICE_FILE"
    echo "User=root" >> "$SERVICE_FILE"
    echo "ExecStart=$BIN_PATH -d $CONFIG_DIR" >> "$SERVICE_FILE"
    echo "Restart=on-failure" >> "$SERVICE_FILE"
    echo "LimitNOFILE=65535" >> "$SERVICE_FILE"
    echo "[Install]" >> "$SERVICE_FILE"
    echo "WantedBy=multi-user.target" >> "$SERVICE_FILE"

    systemctl daemon-reload
    systemctl enable mihomo
    echo -e "${GREEN}Mihomo 安装完成。${PLAIN}"
}

generate_cert() {
    if [[ ! -f "$CONFIG_DIR/server.crt" ]]; then
        openssl req -x509 -nodes -newkey rsa:2048 -keyout "$CONFIG_DIR/server.key" -out "$CONFIG_DIR/server.crt" -days 3650 -subj "/CN=mihomo.server"
        chmod 644 "$CONFIG_DIR/server.key"
    fi
}

get_public_ip() {
    curl -s -4 ip.sb
}

add_socks5() {
    read -p "请输入端口 (默认 1080): " port
    [[ -z "$port" ]] && port=1080
    read -p "请输入用户名 (留空则无): " user
    password=""
    if [[ -n "$user" ]]; then
        read -p "请输入密码: " password
    fi

    cat >> "$CONFIG_FILE" <<EOF
  - name: socks5-in-$port
    type: socks
    port: $port
    listen: 0.0.0.0
    users:
EOF
    if [[ -n "$user" ]]; then
        echo "      - username: $user" >> "$CONFIG_FILE"
        echo "        password: $password" >> "$CONFIG_FILE"
    else
         sed -i '$d' "$CONFIG_FILE"
    fi

    echo -e "${GREEN}Socks5 节点已添加。${PLAIN}"
    restart_service
    view_links
}

add_shadowsocks() {
    read -p "请输入端口 (默认 8388): " port
    [[ -z "$port" ]] && port=8388
    
    read -p "请输入密码 (留空随机): " password
    [[ -z "$password" ]] && password=$(uuidgen)
    
    echo -e "1) aes-256-gcm"
    echo -e "2) chacha20-ietf-poly1305"
    echo -e "3) aes-128-gcm"
    echo -e "4) xchacha20-ietf-poly1305"
    read -p "请选择加密方式 [1-4]: " cipher_opt

    case $cipher_opt in
        1) method="aes-256-gcm" ;;
        2) method="chacha20-ietf-poly1305" ;;
        3) method="aes-128-gcm" ;;
        4) method="xchacha20-ietf-poly1305" ;;
        *) method="aes-256-gcm" ;;
    esac

    cat >> "$CONFIG_FILE" <<EOF
  - name: ss-in-$port
    type: shadowsocks
    port: $port
    listen: 0.0.0.0
    password: "$password"
    cipher: $method
EOF

    echo -e "${GREEN}Shadowsocks 节点已添加。${PLAIN}"
    restart_service
    view_links
}

add_hysteria2() {
    generate_cert
    read -p "请输入端口 (默认 8443): " port
    [[ -z "$port" ]] && port=8443
    read -p "请输入密码 (留空随机): " password
    [[ -z "$password" ]] && password=$(uuidgen)

    cat >> "$CONFIG_FILE" <<EOF
  - name: hy2-in-$port
    type: hysteria2
    port: $port
    listen: 0.0.0.0
    password: "$password"
    certificate: $CONFIG_DIR/server.crt
    private-key: $CONFIG_DIR/server.key
EOF

    echo -e "${GREEN}Hysteria2 节点已添加。${PLAIN}"
    restart_service
    view_links
}

print_node() {
    local type=$1
    local port=$2
    local pass=$3
    local cipher=$4
    local user=$5
    local ip=$6
    
    echo -e "---------------------------------------------------"
    if [[ "$type" == "shadowsocks" ]]; then
        echo -e "${GREEN}Shadowsocks (端口: $port)${PLAIN}"
        echo -e "加密: $cipher"
        echo -e "密码: $pass"
        local cred=$(echo -n "${cipher}:${pass}" | base64 -w 0)
        local link="ss://${cred}@${ip}:${port}#Mihomo-SS-${port}"
        echo -e "链接: ${YELLOW}$link${PLAIN}"
    elif [[ "$type" == "hysteria2" ]]; then
        echo -e "${GREEN}Hysteria2 (端口: $port)${PLAIN}"
        echo -e "密码: $pass"
        local link="hysteria2://${pass}@${ip}:${port}?insecure=1&sni=mihomo.server#Mihomo-Hy2-${port}"
        echo -e "链接: ${YELLOW}$link${PLAIN}"
    elif [[ "$type" == "socks" ]]; then
        echo -e "${GREEN}Socks5 (端口: $port)${PLAIN}"
        echo -e "IP: $ip"
        echo -e "用户: ${user:-无}"
        echo -e "密码: ${pass:-无}"
    fi
}

view_links() {
    IP=$(get_public_ip)
    echo -e "${GREEN}正在获取节点信息...${PLAIN}"
    echo -e "当前公网 IP: ${YELLOW}$IP${PLAIN}"
    
    if [[ ! -f "$CONFIG_FILE" ]]; then
        echo -e "${RED}未找到配置文件。${PLAIN}"
        return
    fi
    
    local type=""
    local port=""
    local pass=""
    local cipher=""
    local user=""
    local in_item=0
    
    while IFS= read -r line; do
        clean_line=$(echo "$line" | sed 's/^[[:space:]]*//')
        
        if [[ "$clean_line" == "- name:"* ]]; then
            if [[ $in_item -eq 1 && -n "$type" ]]; then
                 print_node "$type" "$port" "$pass" "$cipher" "$user" "$IP"
            fi
            type=""
            port=""
            pass=""
            cipher=""
            user=""
            in_item=1
            continue
        fi
        
        if [[ $in_item -eq 1 ]]; then
            if [[ "$clean_line" == "type:"* ]]; then
                type=$(echo "$clean_line" | cut -d: -f2 | tr -d ' "')
            elif [[ "$clean_line" == "port:"* ]]; then
                port=$(echo "$clean_line" | cut -d: -f2 | tr -d ' "')
            elif [[ "$clean_line" == "cipher:"* ]]; then
                cipher=$(echo "$clean_line" | cut -d: -f2 | tr -d ' "')
            elif [[ "$clean_line" == "password:"* ]]; then
                pass=$(echo "$clean_line" | cut -d: -f2 | tr -d ' "')
            elif [[ "$clean_line" == "- username:"* ]]; then
                user=$(echo "$clean_line" | cut -d: -f2 | tr -d ' "')
            fi
        fi
    done < "$CONFIG_FILE"
    
    if [[ $in_item -eq 1 && -n "$type" ]]; then
         print_node "$type" "$port" "$pass" "$cipher" "$user" "$IP"
    fi
    echo -e "---------------------------------------------------"
}

restart_service() {
    systemctl restart mihomo
    if systemctl is-active --quiet mihomo; then
        echo -e "${GREEN}服务运行中。${PLAIN}"
    else
        echo -e "${RED}服务启动失败。${PLAIN}"
    fi
}

view_log() {
    journalctl -u mihomo -f -n 20
}

view_config() {
    cat "$CONFIG_FILE"
}

show_menu() {
    clear
    echo "1. 安装 / 重置配置"
    echo "2. 添加 Shadowsocks"
    echo "3. 添加 Hysteria 2"
    echo "4. 添加 Socks5"
    echo "5. 查看配置文件"
    echo "6. 查看日志"
    echo "7. 重启服务"
    echo "8. 查看节点链接"
    echo "0. 退出"
    read -p "请输入选项: " num

    case $num in
        1) install_dependencies; install_mihomo ;;
        2) add_shadowsocks ;;
        3) add_hysteria2 ;;
        4) add_socks5 ;;
        5) view_config ;;
        6) view_log ;;
        7) restart_service ;;
        8) view_links ;;
        0) exit 0 ;;
        *) echo "无效选项" ;;
    esac
}

while true; do
    show_menu
    read -p "按回车键继续..."
done
