green_echo() { echo -e "\033[32m$1\033[0m"; }
red_echo() { echo -e "\033[31m$1\033[0m"; }
yellow_echo() { echo -e "\033[33m$1\033[0m"; }

red_echo "===== 系统版本校验 ====="
if [ -f /etc/os-release ]; then
    . /etc/os-release
    if [[ "$ID" != "ubuntu" && "$ID" != "debian" && "$ID_LIKE" != *"ubuntu"* && "$ID_LIKE" != *"debian"* ]]; then
        red_echo "❌ 错误：当前系统为 $PRETTY_NAME，仅支持Ubuntu/Debian系统！"
        exit 1
    fi
else
    red_echo "❌ 错误：无法检测系统版本，仅支持Ubuntu/Debian系统！"
    exit 1
fi
green_echo "✅ 系统校验通过：$PRETTY_NAME"

DEFAULT_SSH_PORT="12128"
TRUST_IPS="127.0.0.1/8"
BAN_TIME="86400"
MAX_RETRY="3"
SSH_SERVICE="ssh"
LOG_PATH="/var/log/auth.log"

green_echo "\n===== 【1/5】更新系统依赖包 ====="
apt update -y && apt upgrade -y > /dev/null 2>&1
if [ $? -eq 0 ]; then
    green_echo "✅ 系统依赖更新完成"
else
    yellow_echo "⚠️  部分依赖包升级失败，不影响核心功能"
fi

green_echo "\n===== 【2/5】配置SSH端口 ====="
read -p "请输入SSH端口（回车默认使用 $DEFAULT_SSH_PORT，范围1025-65535）：" INPUT_PORT

if [ -z "$INPUT_PORT" ]; then
    NEW_SSH_PORT="$DEFAULT_SSH_PORT"
    green_echo "✅ 未输入端口，使用默认：$NEW_SSH_PORT"
else
    if ! [[ "$INPUT_PORT" =~ ^[0-9]+$ ]] || [ "$INPUT_PORT" -lt 1025 ] || [ "$INPUT_PORT" -gt 65535 ]; then
        red_echo "❌ 端口无效！自动使用默认：$DEFAULT_SSH_PORT"
        NEW_SSH_PORT="$DEFAULT_SSH_PORT"
    else
        if ss -tuln | grep -q ":$INPUT_PORT "; then
            red_echo "❌ 端口$INPUT_PORT已被占用！自动使用默认：$DEFAULT_SSH_PORT"
            NEW_SSH_PORT="$DEFAULT_SSH_PORT"
        else
            NEW_SSH_PORT="$INPUT_PORT"
            green_echo "✅ 确认使用SSH端口：$NEW_SSH_PORT"
        fi
    fi
fi

green_echo "\n===== 【3/5】修改SSH端口配置 ====="
cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak
sed -i "/^Port/c\Port $NEW_SSH_PORT" /etc/ssh/sshd_config
grep -q "^Port" /etc/ssh/sshd_config || echo "Port $NEW_SSH_PORT" >> /etc/ssh/sshd_config

sshd -t > /dev/null 2>&1
if [ $? -ne 0 ]; then
    red_echo "❌ SSH配置错误，恢复备份并退出！"
    cp /etc/ssh/sshd_config.bak /etc/ssh/sshd_config
    exit 1
fi
green_echo "✅ SSH端口配置语法校验通过"

green_echo "\n===== 【4/5】安装并配置fail2ban ====="
apt install -y fail2ban > /dev/null 2>&1
cat > /etc/fail2ban/jail.local << EOF
[DEFAULT]
ignoreip = $TRUST_IPS
bantime = $BAN_TIME
findtime = 300
maxretry = $MAX_RETRY

[sshd]
enabled = true
port = $NEW_SSH_PORT
filter = sshd
logpath = $LOG_PATH
EOF
green_echo "✅ fail2ban配置完成"

green_echo "\n===== 【5/5】防火墙配置（TCP+UDP双协议） ====="
if dpkg -s ufw > /dev/null 2>&1; then
    UFW_INSTALLED="yes"
    green_echo "✅ 检测到UFW防火墙已安装"
else
    UFW_INSTALLED="no"
    yellow_echo "⚠️  未检测到UFW防火墙"
    read -p "是否安装UFW防火墙？(y/n，默认n)：" INSTALL_UFW
    if [[ "$INSTALL_UFW" == "y" || "$INSTALL_UFW" == "Y" ]]; then
        apt install -y ufw > /dev/null 2>&1
        if [ $? -ne 0 ]; then
            red_echo "❌ UFW安装失败，跳过防火墙配置"
            UFW_INSTALLED="no"
        else
            UFW_INSTALLED="yes"
            green_echo "✅ UFW防火墙安装完成"
        fi
    else
        yellow_echo "❌ 跳过UFW安装，防火墙配置结束"
        goto restart_services
    fi
fi

if [ "$UFW_INSTALLED" == "yes" ]; then
    # 完整防火墙选择菜单（1.开放端口 2.关闭防火墙 3.查看开放端口）
    while true; do
        echo -e "\n请选择防火墙操作："
        echo "1. 开放防火墙端口（TCP+UDP双协议）"
        echo "2. 关闭防火墙"
        echo "3. 查看当前开放的端口"
        read -p "输入数字1/2/3（默认2）：" FIREWALL_CHOICE
        
        # 处理默认值
        if [ -z "$FIREWALL_CHOICE" ]; then
            FIREWALL_CHOICE="2"
        fi

        case $FIREWALL_CHOICE in
            1)
                read -p "请输入要开放的端口（多个端口用空格分隔，如：12128 80）：" INPUT_PORTS
                if [ -z "$INPUT_PORTS" ]; then
                    red_echo "❌ 未输入端口，跳过防火墙开放操作"
                else
                    for PORT in $INPUT_PORTS; do
                        if ! [[ "$PORT" =~ ^[0-9]+$ ]] || [ "$PORT" -lt 1 ] || [ "$PORT" -gt 65535 ]; then
                            red_echo "⚠️  端口$PORT无效，跳过该端口"
                        else
                            ufw allow $PORT/tcp -y > /dev/null 2>&1
                            ufw allow $PORT/udp -y > /dev/null 2>&1
                            green_echo "✅ 已开放端口 $PORT（TCP+UDP）"
                        fi
                    done
                    ufw enable -y > /dev/null 2>&1
                    ufw reload -y > /dev/null 2>&1
                    if [ $? -eq 0 ]; then
                        green_echo "✅ 防火墙规则已重载（TCP+UDP生效）"
                    else
                        red_echo "⚠️  防火墙重载失败，请手动执行ufw reload"
                    fi
                fi
                break
                ;;
            2)
                ufw disable -y > /dev/null 2>&1
                green_echo "✅ 防火墙已关闭"
                break
                ;;
            3)
                green_echo "\n===== 当前防火墙开放的端口 =====\n"
                ufw status numbered
                echo -e "\n=================================="
                read -p "按回车键继续..."  # 暂停让用户查看
                ;;
            *)
                red_echo "❌ 输入错误！请输入1、2或3"
                ;;
        esac
    done
fi

: restart_services
green_echo "\n===== 重启核心服务 ====="
systemctl restart $SSH_SERVICE > /dev/null 2>&1
systemctl enable $SSH_SERVICE > /dev/null 2>&1
systemctl daemon-reload > /dev/null 2>&1
systemctl restart fail2ban > /dev/null 2>&1
systemctl enable fail2ban > /dev/null 2>&1

green_echo "\n===== 配置验证结果 ====="
echo -n "SSH端口监听："
ss -tuln | grep $NEW_SSH_PORT > /dev/null && green_echo "✅ 正常" || red_echo "❌ 异常"
echo -n "SSH服务状态："
systemctl status $SSH_SERVICE --no-pager | grep "Active: active (running)" > /dev/null && green_echo "✅ 正常" || red_echo "❌ 异常"
echo -n "fail2ban状态："
systemctl status fail2ban --no-pager | grep "Active: active (running)" > /dev/null && green_echo "✅ 正常" || red_echo "❌ 异常"
if [ "$UFW_INSTALLED" == "yes" ]; then
    echo -n "防火墙状态："
    ufw status | grep "Status: active" > /dev/null && green_echo "✅ 已启用" || yellow_echo "⚠️  已关闭"
    echo -n "开放端口验证："
    ufw status | grep "$NEW_SSH_PORT" > /dev/null && green_echo "✅ TCP+UDP已开放" || red_echo "❌ 端口未开放"
fi

green_echo "\n===== 操作完成！测试登录命令：ssh 用户名@服务器IP -p $NEW_SSH_PORT ====="
