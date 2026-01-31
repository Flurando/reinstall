#!/bin/ash
# shellcheck shell=dash
# alpine/debian initrd 共用此脚本

# accept_ra 接收 RA + 自动配置网关
# autoconf  自动配置地址，依赖 accept_ra

mac_addr=$1
ipv4_addr=$2
ipv4_gateway=$3

DHCP_TIMEOUT=15
DNS_FILE_TIMEOUT=5
TEST_TIMEOUT=10

# 检测是否有网络是通过检测这些 IP 的端口是否开放
# 因为 debian initrd 没有 nslookup
# 改成 generate_204？但检测网络时可能 resolv.conf 为空
# HTTP 80
# HTTPS/DOH 443
# DOT 853
if $is_in_china; then
    ipv4_dns1='223.5.5.5'
    ipv4_dns2='119.29.29.29' # 不开放 853
else
    ipv4_dns1='1.1.1.1'
    ipv4_dns2='8.8.8.8' # 不开放 80
fi

# 找到主网卡
# debian 11 initrd 没有 xargs awk
# debian 12 initrd 没有 xargs
get_ethx() {
    # 过滤 azure vf (带 master ethx)
    # 2: eth0: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc mq state UP qlen 1000\    link/ether 60:45:bd:21:8a:51 brd ff:ff:ff:ff:ff:ff
    # 3: eth1: <BROADCAST,MULTICAST,UP,LOWER_UP800> mtu 1500 qdisc mq master eth0 state UP qlen 1000\    link/ether 60:45:bd:21:8a:51 brd ff:ff:ff
    if false; then
        ip -o link | grep -i "$mac_addr" | grep -v master | awk '{print $2}' | cut -d: -f1 | grep .
    else
        ip -o link | grep -i "$mac_addr" | grep -v master | cut -d' ' -f2 | cut -d: -f1 | grep .
    fi
}

get_ipv4_gateway() {
    # debian 11 initrd 没有 xargs awk
    # debian 12 initrd 没有 xargs
    ip -4 route show default dev "$ethx" | head -1 | cut -d ' ' -f3
}

get_first_ipv4_addr() {
    # debian 11 initrd 没有 xargs awk
    # debian 12 initrd 没有 xargs
    if false; then
        ip -4 -o addr show scope global dev "$ethx" | head -1 | awk '{print $4}'
    else
        ip -4 -o addr show scope global dev "$ethx" | head -1 | grep -o '[0-9\.]*/[0-9]*'
    fi
}

get_first_ipv4_gateway() {
    # debian 11 initrd 没有 xargs awk
    # debian 12 initrd 没有 xargs
    if false; then
        ip -4 route show default dev "$ethx" | head -1 | awk '{print $3}'
    else
        ip -4 route show default dev "$ethx" | head -1 | cut -d' ' -f3
    fi
}

remove_netmask() {
    cut -d/ -f1
}

is_have_ipv4_addr() {
    ip -4 addr show scope global dev "$ethx" | grep -q inet
}

is_have_ipv4_gateway() {
    ip -4 route show default dev "$ethx" | grep -q .
}

is_have_ipv4() {
    is_have_ipv4_addr && is_have_ipv4_gateway
}

is_have_ipv4_dns() {
    [ -f /etc/resolv.conf ] && grep -q '^nameserver .*\.' /etc/resolv.conf
}

add_missing_ipv4_config() {
    if [ -n "$ipv4_addr" ] && [ -n "$ipv4_gateway" ]; then
        if ! is_have_ipv4_addr; then
            ip -4 addr add "$ipv4_addr" dev "$ethx"
        fi

        if ! is_have_ipv4_gateway; then
            # 如果 dhcp 无法设置onlink网关，那么在这里设置
            # debian 9 ipv6 不能识别 onlink，但 ipv4 能识别 onlink
            if true; then
                ip -4 route add "$ipv4_gateway" dev "$ethx"
                ip -4 route add default via "$ipv4_gateway" dev "$ethx"
            else
                ip -4 route add default via "$ipv4_gateway" dev "$ethx" onlink
            fi
        fi
    fi
}

is_need_test_ipv4() {
    is_have_ipv4 && ! $ipv4_has_internet
}

# 测试方法：
# ping   有的机器禁止
# nc     测试 dot doh 端口是否开启
# wget   测试下载

# initrd 里面的软件版本，是否支持指定源IP/网卡
# 软件     nc  wget  nslookup
# debian9  ×    √   没有此软件
# alpine   √    ×      ×

test_by_wget() {
    src=$1
    dst=$2

    # ipv6 需要添加 []
    if echo "$dst" | grep -q ':'; then
        url="https://[$dst]"
    else
        url="https://$dst"
    fi

    # tcp 443 通了就算成功，不管 http 是不是 404
    # grep -m1 快速返回
    wget -T "$TEST_TIMEOUT" \
        --bind-address="$src" \
        --no-check-certificate \
        --max-redirect 0 \
        --tries 1 \
        -O /dev/null \
        "$url" 2>&1 | grep -iq -m1 connected
}

test_by_nc() {
    src=$1
    dst=$2

    # tcp 443 通了就算成功
    nc -z -v \
        -w "$TEST_TIMEOUT" \
        -s "$src" \
        "$dst" 443
}

is_debian_kali() {
    [ -f /etc/lsb-release ] && grep -Eiq 'Debian|Kali' /etc/lsb-release
}

test_connect() {
    if is_debian_kali; then
        test_by_wget "$1" "$2"
    else
        test_by_nc "$1" "$2"
    fi
}

test_internet() {
    echo "Testing Internet Connection. Test... "
    if is_need_test_ipv4 &&
            current_ipv4_addr="$(get_first_ipv4_addr | remove_netmask)" &&
	    echo $current_ipv4_addr
            { test_connect "$current_ipv4_addr" "$ipv4_dns1" ||
                  test_connect "$current_ipv4_addr" "$ipv4_dns2"; } >/dev/null 2>&1; then
        echo "IPv4 has internet."
        ipv4_has_internet=true
    fi
    if ! is_need_test_ipv4; then
        break
    fi
}

flush_ipv4_config() {
    ip -4 addr flush scope global dev "$ethx"
    ip -4 route flush dev "$ethx"
    # DHCP 获取的 IP 不是重装前的 IP 时，一并删除 DHCP 获取的 DNS，以防 DNS 无效
    sed -i "/\./d" /etc/resolv.conf
}

should_disable_dhcpv4=false
should_disable_accept_ra=false
should_disable_autoconf=false

for i in $(seq 20); do
    if ethx=$(get_ethx); then
        break
    fi
    sleep 1
done

if [ -z "$ethx" ]; then
    echo "Not found network card: $mac_addr"
    exit
fi

echo "Configuring $ethx ($mac_addr)..."

# 不开启 lo 则 frp 无法连接 127.0.0.1 22
ip link set dev lo up

# 开启 ethx
ip link set dev "$ethx" up
sleep 1

# 开启 dhcpv4/v6
# debian / kali
if [ -f /usr/share/debconf/confmodule ]; then
    # shellcheck source=/dev/null
    . /usr/share/debconf/confmodule

    db_progress STEP 1

    # dhcpv4
    # 无需等待写入 dns，在 dhcpv6 等待
    db_progress INFO netcfg/dhcp_progress
    udhcpc -i "$ethx" -f -q -n || true
    db_progress STEP 1

    # 静态 + 检测网络提示
    db_subst netcfg/link_detect_progress interface "$ethx"
    db_progress INFO netcfg/link_detect_progress
else
    # alpine
    # h3c 移动云电脑使用 udhcpc 会重复提示 sending select，无法获得 ipv6
    # dhcpcd 会配置租约时间，过期会移除 IP，但我们的没有在后台运行 dhcpcd ，因此用 udhcpc
    method=udhcpc

    case "$method" in
    udhcpc)
        udhcpc -i "$ethx" -f -q -n || true
        sleep $DNS_FILE_TIMEOUT # 好像不用等待写入 dns，但是以防万一
        ;;
    dhcpcd)
        # https://gitlab.alpinelinux.org/alpine/aports/-/blob/master/main/dhcpcd/dhcpcd.pre-install
        grep -q dhcpcd /etc/group || addgroup -S dhcpcd
        grep -q dhcpcd /etc/passwd || adduser -S -D -H \
            -h /var/lib/dhcpcd \
            -s /sbin/nologin \
            -G dhcpcd \
            -g dhcpcd \
            dhcpcd

        # --noipv4ll 禁止生成 169.254.x.x
        if false; then
            # 等待 DHCP 全过程
            timeout $DHCP_TIMEOUT \
                dhcpcd --persistent --noipv4ll --nobackground "$ethx"
        else
            # 等待 DNS
            dhcpcd --persistent --noipv4ll "$ethx" # 获取到 IP 后立即切换到后台
            sleep $DNS_FILE_TIMEOUT                # 需要等待写入 dns
            dhcpcd -x "$ethx"                      # 终止
        fi
    esac
fi

# 传参给 trans.start
netconf="/dev/netconf/$ethx"
mkdir -p "$netconf"
$dhcpv4 && echo 1 >"$netconf/dhcpv4" || echo 0 >"$netconf/dhcpv4"
$should_disable_dhcpv4 && echo 1 >"$netconf/should_disable_dhcpv4" || echo 0 >"$netconf/should_disable_dhcpv4"
echo "$ethx" >"$netconf/ethx"
echo "$mac_addr" >"$netconf/mac_addr"
echo "$ipv4_addr" >"$netconf/ipv4_addr"
echo "$ipv4_gateway" >"$netconf/ipv4_gateway"
$ipv4_has_internet && echo 1 >"$netconf/ipv4_has_internet" || echo 0 >"$netconf/ipv4_has_internet"
