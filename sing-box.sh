#!/usr/bin/env bash
set -e

### ===== 基础配置 =====
WORK_DIR="/etc/sing-box"
BIN_NAME="sing-box"
CONFIG="$WORK_DIR/config.json"

RED="\033[1;31m"
GREEN="\033[1;32m"
YELLOW="\033[1;33m"
RESET="\033[0m"

[[ $EUID -ne 0 ]] && echo -e "${RED}请使用 root 运行${RESET}" && exit 1

### ===== 工具函数 =====
log() { echo -e "${GREEN}$1${RESET}"; }
warn() { echo -e "${YELLOW}$1${RESET}"; }
err() { echo -e "${RED}$1${RESET}"; }

rand_port() { shuf -i 20000-60000 -n 1; }

get_ip() {
  curl -s --max-time 2 ipv4.ip.sb || curl -s --max-time 2 ipv6.ip.sb
}

### ===== 安装依赖 =====
install_deps() {
  if command -v apt &>/dev/null; then
    apt update -y
    apt install -y curl tar openssl jq
  elif command -v apk &>/dev/null; then
    apk add --no-cache curl tar openssl jq
  elif command -v yum &>/dev/null; then
    yum install -y curl tar openssl jq
  else
    err "不支持的系统"
    exit 1
  fi
}

### ===== 安装 sing-box =====
install_singbox() {
  ARCH=$(uname -m)
  case "$ARCH" in
    x86_64) ARCH=amd64 ;;
    aarch64|arm64) ARCH=arm64 ;;
    *) err "不支持的架构 $ARCH"; exit 1 ;;
  esac

  VERSION="1.10.7"
  mkdir -p $WORK_DIR
  curl -L -o /tmp/sb.tar.gz \
    https://github.com/SagerNet/sing-box/releases/download/v$VERSION/sing-box-$VERSION-linux-$ARCH.tar.gz
  tar -xzf /tmp/sb.tar.gz -C /tmp
  mv /tmp/sing-box-$VERSION-linux-$ARCH/sing-box $WORK_DIR/
  chmod +x $WORK_DIR/sing-box
}

### ===== 生成配置 =====
generate_config() {
  UUID=$(cat /proc/sys/kernel/random/uuid)
  VLESS_PORT=$(rand_port)
  HY2_PORT=$(rand_port)
  TUIC_PORT=$(rand_port)

  REALITY=$($WORK_DIR/sing-box generate reality-keypair)
  PRIVATE_KEY=$(echo "$REALITY" | awk '/PrivateKey/ {print $2}')
  PUBLIC_KEY=$(echo "$REALITY" | awk '/PublicKey/ {print $2}')

  openssl ecparam -genkey -name prime256v1 -out $WORK_DIR/private.key
  openssl req -new -x509 -days 3650 \
    -key $WORK_DIR/private.key \
    -out $WORK_DIR/cert.pem \
    -subj "/CN=apple.com"

cat > $CONFIG <<EOF
{
  "log": { "level": "info" },
  "inbounds": [
    {
      "type": "vless",
      "listen": "::",
      "listen_port": $VLESS_PORT,
      "users": [{ "uuid": "$UUID", "flow": "xtls-rprx-vision" }],
      "tls": {
        "enabled": true,
        "server_name": "www.apple.com",
        "reality": {
          "enabled": true,
          "handshake": { "server": "www.apple.com", "server_port": 443 },
          "private_key": "$PRIVATE_KEY"
        }
      }
    },
    {
      "type": "hysteria2",
      "listen": "::",
      "listen_port": $HY2_PORT,
      "users": [{ "password": "$UUID" }],
      "tls": {
        "enabled": true,
        "alpn": ["h3"],
        "certificate_path": "cert.pem",
        "key_path": "private.key"
      }
    },
    {
      "type": "tuic",
      "listen": "::",
      "listen_port": $TUIC_PORT,
      "users": [{ "uuid": "$UUID" }],
      "congestion_control": "bbr",
      "tls": {
        "enabled": true,
        "alpn": ["h3"],
        "certificate_path": "cert.pem",
        "key_path": "private.key"
      }
    }
  ],
  "outbounds": [{ "type": "direct" }]
}
EOF
}

### ===== systemd =====
install_service() {
cat > /etc/systemd/system/sing-box.service <<EOF
[Unit]
Description=sing-box
After=network.target

[Service]
ExecStart=$WORK_DIR/sing-box run -c $CONFIG
Restart=on-failure
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable sing-box
systemctl restart sing-box
}

### ===== 输出节点 =====
show_nodes() {
  IP=$(get_ip)
  echo ""
  log "VLESS Reality："
  echo "vless://$UUID@$IP:$VLESS_PORT?encryption=none&security=reality&sni=www.apple.com&fp=chrome&pbk=$PUBLIC_KEY&type=tcp#vless-reality"
  echo ""
  log "Hysteria2："
  echo "hysteria2://$UUID@$IP:$HY2_PORT/?alpn=h3&insecure=1#hysteria2"
  echo ""
  log "TUIC："
  echo "tuic://$UUID@$IP:$TUIC_PORT?alpn=h3&allow_insecure=1#tuic"
}

### ===== 主流程 =====
install_deps
install_singbox
generate_config
install_service
show_nodes

log "安装完成 ✅"
