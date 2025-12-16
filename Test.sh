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
    curl -s4m8 https://ip.sb || curl -s4m8 https://api.ipify.org
}

add_socks5() {
    read -p "请输入端口 (默认 1122): " port
    [[ -z "$port" ]] && port=1122
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
    IP=$(get_public_ip)
    echo -e "IP: $IP  端口: $port  用户: $user  密码: $password"
    restart_service
}

add_shadowsocks() {
    read -p "请输入端口 (默认 1232): " port
    [[ -z "$port" ]] && port=1232
    
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

    IP=$(get_public_ip)
    CRED=$(echo -n "$method:$password" | base64 -w 0)
    LINK="ss://${CRED}@${IP}:${port}#Mihomo-SS"

    echo -e "${GREEN}Shadowsocks 节点已添加。${PLAIN}"
    echo -e "${YELLOW}$LINK${PLAIN}"
    restart_service
}

add_hysteria2() {
    generate_cert
    read -p "请输入端口 (默认 1223): " port
    [[ -z "$port" ]] && port=1223
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

    IP=$(get_public_ip)
    LINK="hysteria2://${password}@${IP}:${port}?insecure=1&sni=mihomo.server#Mihomo-Hy2"

    echo -e "${GREEN}Hysteria2 节点已添加。${PLAIN}"
    echo -e "${YELLOW}$LINK${PLAIN}"
    restart_service
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
        0) exit 0 ;;
        *) echo "无效选项" ;;
    esac
}

while true; do
    show_menu
    read -p "按回车键继续..."
done
