#!/usr/bin/env sh
# shellcheck shell=bash
# shellcheck disable=SC2086

# nixos 默认的配置不会生成 /bin/bash，因此需要用 /usr/bin/env
# alpine 默认没有 bash，因此 shebang 用 sh，再 exec 切换到 bash

set -eE
confhome=https://raw.githubusercontent.com/youhong558/reinstall/main
confhome_cn=https://cnb.cool/youhong558/reinstall/-/git/raw/main
# confhome_cn=https://www.ghproxy.cc/https://raw.githubusercontent.com/youhong558/reinstall/main

# 用于判断 reinstall.sh 和 trans.sh 是否兼容
SCRIPT_VERSION=4BACD833-A585-23BA-6CBB-9AA4E08E0004

# 记录要用到的 windows 程序，运行时输出删除 \r
WINDOWS_EXES='cmd powershell wmic reg diskpart netsh bcdedit mountvol'

BOOT_ENTEY_START_MARK='### BEGIN reinstall.sh ###'
BOOT_ENTEY_END_MARK='### END reinstall.sh ###'

# 临时目录
# 不用 /tmp，因为 /tmp 挂载在内存的话，可能不够空间
tmp=/reinstall-tmp

# 强制 linux 程序输出英文，防止 grep 不到想要的内容
# https://www.gnu.org/software/gettext/manual/html_node/The-LANGUAGE-variable.html
export LC_ALL=C

# 处理部分用户用 su 切换成 root 导致环境变量没 sbin 目录
# 也能处理 cygwin bash 没有添加 -l 运行 reinstall.sh
# 不要漏了最后的 $PATH，否则会找不到 windows 系统程序例如 diskpart
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH

# 如果不是 bash 的话，继续执行会有语法错误，因此在这里判断是否 bash
if [ -z "$BASH" ]; then
    if ! command -v bash >/dev/null; then
        if [ -f /etc/alpine-release ]; then
            if ! apk add bash; then
                echo "Error while install bash." >&2
                exit 1
            fi
        else
            echo "Please run this script with bash." >&2
            exit 1
        fi
    fi
    exec bash "$0" "$@"
fi

# 好像跟 trap SIGINT 有冲突
# 记录日志，过滤含有 password 的行
# exec > >(tee >(grep -iv password >>/reinstall.log)) 2>&1
THIS_SCRIPT=$(readlink -f "$0")
trap 'trap_err $LINENO $?' ERR

trap_err() {
    line_no=$1
    ret_no=$2

    error "Line $line_no return $ret_no"
    sed -n "$line_no"p "$THIS_SCRIPT"
}

is_in_windows() {
    [ "$(uname -o)" = Cygwin ] || [ "$(uname -o)" = Msys ]
}

if is_in_windows; then
    reinstall_____='.\reinstall.bat'
else
    reinstall_____='sh reinstall.sh'
fi

usage_and_exit() {
    cat <<EOF
Usage: $reinstall_____ anolis      7|8|23
                       opencloudos 8|9|23
                       rocky       8|9|10
                       oracle      8|9|10
                       almalinux   8|9|10
                       centos      9|10
                       fnos        1
                       nixos       25.11
                       fedora      42|43
                       debian      9|10|11|12|13
                       alpine      3.20|3.21|3.22|3.23
                       opensuse    15.6|16.0|tumbleweed
                       openeuler   20.03|22.03|24.03|25.09
                       ubuntu      16.04|18.04|20.04|22.04|24.04|25.10 [--minimal]
                       kali
                       arch
                       gentoo
                       aosc
                       redhat      --img="http://access.cdn.redhat.com/xxx.qcow2"
                       dd          --img="http://xxx.com/yyy.zzz" (raw image stores in raw/vhd/tar/gz/xz/zst)
                       windows     --image-name="windows xxx yyy" --lang=xx-yy
                       windows     --image-name="windows xxx yyy" --iso="http://xxx.com/xxx.iso"
                       netboot.xyz
                       reset

       Options:        For Linux/Windows:
                       [--password    PASSWORD]
                       [--ssh-key     KEY]
                       [--ssh-port    PORT]
                       [--web-port    PORT]
                       [--frpc-config PATH]

                       For Windows Only:
                       [--allow-ping]
                       [--rdp-port    PORT]
                       [--add-driver  INF_OR_DIR]

Manual: https://github.com/youhong558/reinstall

EOF
    exit 1
}

info() {
    local msg
    if [ "$1" = false ]; then
        shift
        msg=$*
    else
        msg="***** $(to_upper <<<"$*") *****"
    fi
    echo_color_text '\e[32m' "$msg" >&2
}

warn() {
    local msg
    if [ "$1" = false ]; then
        shift
        msg=$*
    else
        msg="Warning: $*"
    fi
    echo_color_text '\e[33m' "$msg" >&2
}

error() {
    echo_color_text '\e[31m' "***** ERROR *****" >&2
    echo_color_text '\e[31m' "$*" >&2
}

echo_color_text() {
    color="$1"
    shift
    plain="\e[0m"
    echo -e "$color$*$plain"
}

error_and_exit() {
    error "$@"
    exit 1
}

show_dd_password_tips() {
    warn false "
This password is only used for SSH access to view logs during the installation.
Password of the image will NOT modify.

密码仅用于安装过程中通过 SSH 查看日志。
镜像的密码不会被修改。
"
}

show_url_in_args() {
    while [ $# -gt 0 ]; do
        case "$1" in
        [Hh][Tt][Tt][Pp][Ss]://* | [Hh][Tt][Tt][Pp]://* | [Mm][Aa][Gg][Nn][Ee][Tt]:*) echo "$1" ;;
        esac
        shift
    done
}

curl() {
    is_have_cmd curl || install_pkg curl

    # 显示 url
    show_url_in_args "$@" >&2

    # 添加 -f, --fail，不然 404 退出码也为0
    # 32位 cygwin 已停止更新，证书可能有问题，先添加 --insecure
    # centos 7 curl 不支持 --retry-connrefused --retry-all-errors
    # 因此手动 retry
    for i in $(seq 5); do
        if command curl --insecure --connect-timeout 10 -f "$@"; then
            return
        else
            ret=$?
            # 403 404 错误，或者达到重试次数
            if [ $ret -eq 22 ] || [ $i -eq 5 ]; then
                return $ret
            fi
            sleep 1
        fi
    done
}

mask2cidr() {
    local x=${1##*255.}
    set -- 0^^^128^192^224^240^248^252^254^ $(((${#1} - ${#x}) * 2)) ${x%%.*}
    x=${1%%"$3"*}
    echo $(($2 + (${#x} / 4)))
}

is_in_china() {
    [ "$force_cn" = 1 ] && return 0

    if [ -z "$_loc" ]; then
        if ! _loc=$(curl -L http://www.qualcomm.cn/cdn-cgi/trace | grep '^loc=' | cut -d= -f2 | grep .); then
            error_and_exit "Can not get location."
        fi
        echo "Location: $_loc" >&2
    fi
    [ "$_loc" = CN ]
}

is_in_windows() {
    [ "$(uname -o)" = Cygwin ] || [ "$(uname -o)" = Msys ]
}

is_in_alpine() {
    [ -f /etc/alpine-release ]
}

is_use_cloud_image() {
    [ -n "$cloud_image" ] && [ "$cloud_image" = 1 ]
}

is_force_use_installer() {
    [ -n "$installer" ] && [ "$installer" = 1 ]
}

is_use_dd() {
    [ "$distro" = dd ]
}

is_boot_in_separate_partition() {
    mount | grep -q ' on /boot type '
}

is_os_in_btrfs() {
    mount | grep -q ' on / type btrfs '
}

is_os_in_subvol() {
    subvol=$(awk '($2=="/") { print $i }' /proc/mounts | grep -o 'subvol=[^ ]*' | cut -d= -f2)
    [ "$subvol" != / ]
}

get_os_part() {
    awk '($2=="/") { print $1 }' /proc/mounts
}

umount_all() {
    if mount_lists=$(mount | grep -w "on $1" | awk '{print $3}' | grep .); then
        if umount --help 2>&1 | grep -wq -- '-R'; then
            umount -R "$1"
        else
            echo "$mount_lists" | tac | xargs -n1 umount
        fi
    fi
}

cp_to_btrfs_root() {
    mount_dir=$tmp/reinstall-btrfs-root
    if ! grep -q $mount_dir /proc/mounts; then
        mkdir -p $mount_dir
        mount "$(get_os_part)" $mount_dir -t btrfs -o subvol=/
    fi
    cp -rf "$@" "$mount_dir"
}

is_host_has_ipv4_and_ipv6() {
    host=$1

    install_pkg dig
    res=$(dig +short $host A $host AAAA | grep -v '\.$')
    grep -q \. <<<$res && grep -q : <<<$res
}

is_netboot_xyz() {
    [ "$distro" = netboot.xyz ]
}

is_alpine_live() {
    [ "$distro" = alpine ] && [ "$hold" = 1 ]
}

is_have_initrd() {
    ! is_netboot_xyz
}

is_use_firmware() {
    # shellcheck disable=SC2154
    [ "$nextos_distro" = debian ] && ! is_virt
}

is_digit() {
    [[ "$1" =~ ^[0-9]+$ ]]
}

is_port_valid() {
    is_digit "$1" && [ "$1" -ge 1 ] && [ "$1" -le 65535 ]
}

get_host_by_url() {
    cut -d/ -f3 <<<$1
}

get_scheme_and_host_by_url() {
    cut -d/ -f1-3 <<<$1
}

get_function() {
    declare -f "$1"
}

get_function_content() {
    declare -f "$1" | sed '1d;2d;$d'
}

insert_into_file() {
    local file=$1
    local location=$2
    local regex_to_find=$3
    shift 3

    if ! [ -f "$file" ]; then
        error_and_exit "File not found: $file"
    fi

    if [ $# -eq 0 ]; then
        set -- -E
    fi

    line_num=$(grep "$@" -n "$regex_to_find" "$file" | cut -d: -f1)

    found_count=$(echo "$line_num" | wc -l)
    if [ ! "$found_count" -eq 1 ]; then
        return 1
    fi

    case "$location" in
    before) line_num=$((line_num - 1)) ;;
    after) ;;
    *) return 1 ;;
    esac

    sed -i "${line_num}r /dev/stdin" "$file"
}

test_url() {
    test_url_real false "$@"
}

test_url_grace() {
    test_url_real true "$@"
}

test_url_real() {
    grace=$1
    url=$2
    expect_types=$3
    var_to_eval=$4
    info test url

    failed() {
        $grace && return 1
        error_and_exit "$@"
    }

    tmp_file=$tmp/img-test

    echo $url
    for i in $(seq 5 -1 0); do
        if command curl --insecure --connect-timeout 10 -Lfr 0-1048575 "$url" \
            1> >(exec head -c 1048576 >$tmp_file) \
            2> >(exec grep -v 'curl: (23)' >&2); then
            break
        else
            ret=$?
            msg="$url not accessible"
            case $ret in
            22)
                failed "$msg"
                return "$ret"
                ;;
            23)
                break
                ;;
            *)
                if [ $i -eq 0 ]; then
                    failed "$msg"
                    return "$ret"
                fi
                ;;
            esac
            sleep 1
        fi
    done

    if [ -n "$expect_types" ]; then
        install_pkg file
        real_type=$(file_enhanced $tmp_file)
        echo "File type: $real_type"

        for type in $expect_types $([ "$expect_types" = iso ] && echo raw); do
            if [[ ."$real_type" = *."$type" ]]; then
                if [ -n "$var_to_eval" ]; then
                    IFS=. read -r "${var_to_eval?}" "${var_to_eval}_warp" <<<"$real_type"
                fi
                return
            fi
        done

        failed "$url
Expected type: $expect_types
Actually type: $real_type"
    fi
}

fix_file_type() {
    sed -E \
        -e 's/[,;#]//g' \
        -e 's/^[[:space:]]*//' \
        -e 's/(POSIX|Unicode|UTF-8|ASCII)//gi' \
        -e 's/^DOS\/MBR boot sector/raw/i' \
        -e 's/^x86 boot sector/raw/i' \
        -e 's/^Zstandard/zstd/i' \
        -e 's/^UDF/iso/i' \
        -e 's/^Windows imaging \(WIM\) image/wim/i' |
        awk '{print $1}' | to_lower
}

file_enhanced() {
    file=$1

    full_type=
    while true; do
        type="$(file -b $file | fix_file_type)"
        full_type="$type.$full_type"
        case "$type" in
        xz | gzip | zstd)
            install_pkg "$type"
            $type -dc <"$file" | head -c 1048576 >"$file.inside"
            mv -f "$file.inside" "$file"
            ;;
        tar)
            install_pkg "$type"
            tar xf "$file" -O 2>/dev/null | head -c 1048576 >"$file.inside"
            mv -f "$file.inside" "$file"
            ;;
        *)
            break
            ;;
        esac
    done
    # shellcheck disable=SC2001
    echo "$full_type" | sed 's/\.$//'
}

add_community_repo_for_alpine() {
    local alpine_ver

    if grep -q '^http.*/edge/main$' /etc/apk/repositories; then
        alpine_ver=edge
    else
        alpine_ver=v$(cut -d. -f1,2 </etc/alpine-release)
    fi

    if ! grep -q "^http.*/$alpine_ver/community$" /etc/apk/repositories; then
        mirror=$(grep '^http.*/main$' /etc/apk/repositories | sed 's,/[^/]*/main$,,' | head -1)
        echo $mirror/$alpine_ver/community >>/etc/apk/repositories
    fi
}

is_in_container() {
    { is_have_cmd systemd-detect-virt && systemd-detect-virt -qc; } ||
        [ -d /proc/vz ] ||
        { [ -f /proc/1/environ ] && grep -q container=lxc /proc/1/environ; }
}

run_with_del_cr() {
    if false; then
        res=$("$@") && ret=0 || ret=$?
        echo "$res" | del_cr
        return $ret
    else
        "$@" | del_cr
        return ${PIPESTATUS[0]}
    fi
}

run_with_del_cr_template() {
    if get_function _$exe >/dev/null; then
        run_with_del_cr _$exe "$@"
    else
        run_with_del_cr command $exe "$@"
    fi
}

wmic() {
    if is_have_cmd wmic; then
        has_get=false
        for i in "$@"; do
            if [ "$(to_upper <<<"$i")" = GET ]; then
                has_get=true
                break
            fi
        done

        if $has_get; then
            command wmic "$@" /format:list
        else
            command wmic "$@" get /format:list
        fi
        return
    fi

    local namespace='root\cimv2'
    local class=
    local filter=
    local props=

    if [[ "$(to_upper <<<"$1")" = /NAMESPACE* ]]; then
        namespace=$(cut -d: -f2 <<<"$1" | sed -e "s/[\"']//g" -e 's/\\\\//g')
        shift
    fi

    if [[ "$(to_upper <<<"$1")" = PATH ]]; then
        class=$2
        shift 2
    else
        case "$(to_lower <<<"$1")" in
        nicconfig) class=Win32_NetworkAdapterConfiguration ;;
        memorychip) class=Win32_PhysicalMemory ;;
        *) class=Win32_$1 ;;
        esac
        shift
    fi

    if [[ "$(to_upper <<<"$1")" = WHERE ]]; then
        filter=$2
        shift 2
    fi

    if [[ "$(to_upper <<<"$1")" = GET ]]; then
        props=$2
        shift 2
    fi

    if ! [ -f "$tmp/wmic.ps1" ]; then
        curl -Lo "$tmp/wmic.ps1" "$confhome/wmic.ps1"
    fi

    # shellcheck disable=SC2046
    powershell -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass \
        -File "$(cygpath -w "$tmp/wmic.ps1")" \
        -Namespace "$namespace" \
        -Class "$class" \
        $([ -n "$filter" ] && echo -Filter "$filter") \
        $([ -n "$props" ] && echo -Properties "$props")
}

is_virt() {
    if [ -z "$_is_virt" ]; then
        if is_in_windows; then
            vmstr='VMware|Virtual|Virtualization|VirtualBox|VMW|Hyper-V|Bochs|QEMU|KVM|OpenStack|KubeVirt|innotek|Xen|Parallels|BHYVE'
            for name in ComputerSystem BIOS BaseBoard; do
                if wmic $name | grep -Eiw $vmstr; then
                    _is_virt=true
                    break
                fi
            done
        else
            if is_have_cmd systemd-detect-virt && systemd-detect-virt -v; then
                _is_virt=true
            fi

            if [ -z "$_is_virt" ]; then
                install_pkg dmidecode virt-what
                if [ -n "$(virt-what)" ]; then
                    _is_virt=true
                fi
            fi
        fi

        if [ -z "$_is_virt" ]; then
            _is_virt=false
        fi
        echo "VM: $_is_virt"
    fi
    $_is_virt
}

is_absolute_path() {
    [[ "$1" = /* ]]
}

is_cpu_supports_x86_64_v3() {
    need_flags="avx avx2 bmi1 bmi2 f16c fma movbe xsave"
    had_flags=$(grep -m 1 ^flags /proc/cpuinfo | awk -F': ' '{print $2}')

    for flag in $need_flags; do
        if ! grep -qw $flag <<<"$had_flags"; then
            return 1
        fi
    done
}

assert_cpu_supports_x86_64_v3() {
    if ! is_cpu_supports_x86_64_v3; then
        error_and_exit "Could not install $distro $releasever because the CPU does not support x86-64-v3."
    fi
}

en_us() {
    echo "$lang" | awk -F- '{print $1"-"$2}'
    if [ "$lang" = zh-hk ]; then
        echo zh-tw
    fi
}

us() {
    if [ "$lang" = pt-pt ]; then
        echo pp
        return
    fi
    if [ "$lang" = pt-br ]; then
        echo pt
        return
    fi

    echo "$lang" | awk -F- '{print $2}'

    if [ "$lang" = zh-hk ]; then
        echo tw
    fi
}

en_en() {
    echo "$lang" | awk -F- '{print $1"-"$1}'

    if [ "$lang" = en-gb ]; then
        echo en-us
    fi
}

en() {
    if [ "$lang" = pt-br ] || [ "$lang" = pt-pt ]; then
        echo "pp"
        return
    fi

    echo "$lang" | awk -F- '{print $1}'
}

english() {
    case "$lang" in
    ar-sa) echo Arabic ;;
    bg-bg) echo Bulgarian ;;
    cs-cz) echo Czech ;;
    da-dk) echo Danish ;;
    de-de) echo German ;;
    el-gr) echo Greek ;;
    en-gb) echo Eng_Intl ;;
    en-us) echo English ;;
    es-es) echo Spanish ;;
    es-mx) echo Spanish_Latam ;;
    et-ee) echo Estonian ;;
    fi-fi) echo Finnish ;;
    fr-ca) echo FrenchCanadian ;;
    fr-fr) echo French ;;
    he-il) echo Hebrew ;;
    hr-hr) echo Croatian ;;
    hu-hu) echo Hungarian ;;
    it-it) echo Italian ;;
    ja-jp) echo Japanese ;;
    ko-kr) echo Korean ;;
    lt-lt) echo Lithuanian ;;
    lv-lv) echo Latvian ;;
    nb-no) echo Norwegian ;;
    nl-nl) echo Dutch ;;
    pl-pl) echo Polish ;;
    pt-pt) echo Portuguese ;;
    pt-br) echo Brazilian ;;
    ro-ro) echo Romanian ;;
    ru-ru) echo Russian ;;
    sk-sk) echo Slovak ;;
    sl-si) echo Slovenian ;;
    sr-latn | sr-latn-rs) echo Serbian_Latin ;;
    sv-se) echo Swedish ;;
    th-th) echo Thai ;;
    tr-tr) echo Turkish ;;
    uk-ua) echo Ukrainian ;;
    zh-cn) echo ChnSimp ;;
    zh-hk | zh-tw) echo ChnTrad ;;
    esac
}

parse_windows_image_name() {
    set -- $image_name

    if ! [ "$1" = windows ]; then
        return 1
    fi
    shift

    if [ "$1" = server ]; then
        server=server
        shift
    fi

    version=$1
    shift

    if [ "$1" = r2 ]; then
        version+=" r2"
        shift
    fi

    edition=
    while [ $# -gt 0 ]; do
        case "$1" in
        k | n | kn) ;;
        *)
            if [ -n "$edition" ]; then
                edition+=" "
            fi
            edition+="$1"
            ;;
        esac
        shift
    done
}

is_have_arm_version() {
    case "$version" in
    10)
        case "$edition" in
        home | 'home single language' | pro | education | enterprise | 'pro education' | 'pro for workstations') return ;;
        'iot enterprise') return ;;
        'enterprise ltsc 2021' | 'iot enterprise ltsc 2021') return ;;
        esac
        ;;
    11) return ;;
    esac
    return 1
}

find_windows_iso() {
    parse_windows_image_name || error_and_exit "--image-name wrong: $image_name"
    if ! { [ "$version" = 8 ] || [ "$version" = 8.1 ]; } && [ -z "$edition" ]; then
        error_and_exit "Edition is not set."
    fi

    if [ -z "$lang" ]; then
        lang=zh-cn
    fi
    langs="$lang $(en_us) $(us) $(en_en) $(en)"
    langs=$(echo "$langs" | xargs -n 1 | awk '!seen[$0]++')
    full_lang=$(english)

    case "$basearch" in
    x86_64)
        arch_win=x64
        arch_win_vlsc=64bit
        ;;
    aarch64)
        arch_win=arm64
        arch_win_vlsc=arm64
        ;;
    esac

    get_windows_iso_link
}

get_windows_iso_link() {
    get_label_msdn() {
        if [ -n "$server" ]; then
            case "$version" in
            2008 | '2008 r2')
                case "$edition" in
                serverweb | serverwebcore) echo _ ;;
                serverstandard | serverstandardcore) echo _ ;;
                serverenterprise | serverenterprisecore) echo _ ;;
                serverdatacenter | serverdatacentercore) echo _ ;;
                esac
                ;;
            '2012 r2' | \
                2016 | 2019 | 2022 | 2025)
                case "$edition" in
                serverstandard | serverstandardcore) echo _ ;;
                serverdatacenter | serverdatacentercore) echo _ ;;
                esac
                ;;
            esac
        else
            case "$version" in
            vista)
                case "$edition" in
                starter)
                    case "$arch_win" in
                    x86) echo _ ;;
                    esac
                    ;;
                homebasic | homepremium | ultimate) echo _ ;;
                business | enterprise) echo "$edition" ;;
                esac
                ;;
            7)
                case "$edition" in
                starter)
                    case "$arch_win" in
                    x86) echo starter ;;
                    esac
                    ;;
                homebasic)
                    case "$arch_win" in
                    x86) echo "home basic" ;;
                    esac
                    ;;
                homepremium) echo "home premium" ;;
                professional | enterprise | ultimate) echo "$edition" ;;
                esac
                ;;
            8 | 8.1)
                case "$edition" in
                '') echo _ ;;
                pro | enterprise) echo "$edition" ;;
                esac
                ;;
            10)
                case "$edition" in
                home | 'home single language') echo consumer ;;
                pro | enterprise) echo business ;;
                education | 'pro education' | 'pro for workstations')
                    case "$arch_win" in
                    arm64) echo consumer ;;
                    x64) echo business ;;
                    esac
                    ;;
                'iot enterprise') echo 'iot enterprise' ;;
                'iot enterprise ltsc 2019' | 'iot enterprise ltsc 2021') echo "$edition" ;;
                'enterprise 2015 ltsb' | 'enterprise 2016 ltsb' | 'enterprise ltsc 2019') echo "$edition" ;;
                'enterprise ltsc 2021')
                    case "$arch_win" in
                    arm64) echo 'iot enterprise ltsc 2021' ;;
                    x86 | x64) echo 'enterprise ltsc 2021' ;;
                    esac
                    ;;
                esac
                ;;
            11)
                case "$edition" in
                home | 'home single language') echo consumer ;;
                pro | enterprise) echo business ;;
                education | 'pro education' | 'pro for workstations')
                    case "$arch_win" in
                    arm64) echo consumer ;;
                    x64) echo business ;;
                    esac
                    ;;
                'iot enterprise' | 'iot enterprise subscription') echo 'iot enterprise' ;;
                'iot enterprise ltsc 2024' | 'iot enterprise subscription ltsc 2024') echo 'iot enterprise ltsc 2024' ;;
                'enterprise ltsc 2024')
                    case "$arch_win" in
                    arm64) echo 'iot enterprise ltsc 2024' ;;
                    x64) echo 'enterprise ltsc 2024' ;;
                    esac
                    ;;
                esac
                ;;
            esac
        fi
    }

    get_label_vlsc() {
        case "$version" in
        10 | 11)
            case "$edition" in
            pro | education | enterprise | 'pro education' | 'pro for workstations') echo pro ;;
            esac
            ;;
        2025)
            echo SrvSTDCORE
            ;;
        esac
    }

    get_label_msdl() {
        case "$version" in
        8.1)
            case "$edition" in
            '' | pro) echo _ ;;
            esac
            ;;
        esac
    }

    get_page() {
        if [ "$arch_win" = arm64 ]; then
            echo arm
        elif is_ltsc; then
            echo ltsc
        elif [ "$server" = 'server' ]; then
            echo server
        else
            case "$version" in
            vista | 7 | 8 | 8.1 | 10 | 11)
                echo "$version"
                ;;
            esac
        fi
    }

    is_ltsc() {
        grep -Ewq 'ltsb|ltsc' <<<"$edition"
    }

    label_msdn=$(get_label_msdn)
    label_msdl=$(get_label_msdl)
    label_vlsc=$(get_label_vlsc)
    page=$(get_page)

    if [ "$page" = vista ]; then
        page_url=https://massgrave.dev/windows_vista__links
    elif [ "$page" = server ]; then
        page_url=https://massgrave.dev/windows-server-links
    else
        page_url=https://massgrave.dev/windows_${page}_links
    fi

    info "Find windows iso"
    echo "Version:    $version"
    echo "Edition:    $edition"
    echo "Label msdn: $label_msdn"
    echo "Label msdl: $label_msdl"
    echo "Label vlsc: $label_vlsc"
    echo "List:       $page_url"
    echo

    if [ -z "$page" ] || { [ -z "$label_msdn" ] && [ -z "$label_msdl" ] && [ -z "$label_vlsc" ]; }; then
        error_and_exit "Not support find this iso. Check if --image-name is wrong. Or set --iso manually."
    fi

    if [ "$basearch" = aarch64 ] && ! is_have_arm_version; then
        error_and_exit "No ARM iso for this Windows Version or Edition."
    fi

    if [ -n "$label_msdl" ]; then
        iso=$(curl -L "$page_url" | grep -ioP 'https://[^ ]+?#[0-9]+' | head -1 | grep .)
    else
        http_to_host=$(get_scheme_and_host_by_url "$page_url")
        http_to_current_dir=$(dirname "$page_url")
        curl -L "$page_url" |
            tr -d '\n' | sed -e 's,<a ,\n<a ,g' -e 's,</a>,</a>\n,g' |
            grep -Ei '\.(iso|img)</a>$' |
            sed -E -e 's,<a href="?([^" ]+)"?.+>(.+)</a>,\2 \1,' \
                -e "s, (/), $http_to_host\1," |
            awk '{if ($2 !~ /^https?:\/\//) $2 = "'$http_to_current_dir/'" $2; print}' >$tmp/win.list

        if is_ltsc; then
            sed -Ei '/ltsc|ltsb/!d' $tmp/win.list
        else
            sed -Ei '/ltsc|ltsb/d' $tmp/win.list
        fi

        get_windows_iso_link_inner
    fi
}

get_shortest_line() {
    awk '(NR == 1 || length($0) < length(shortest)) { shortest = $0 } END { print shortest }'
}

get_shortest_line_by_field() {
    local field=$1
    awk "(NR == 1 || length(\$$field) < length(field)) { line = \$0; field = \$$field } END { print line }"
}

get_windows_iso_link_inner() {
    regexs=()

    if [ -n "$label_msdn" ]; then
        if [ "$label_msdn" = _ ]; then
            label_msdn=
        fi
        for lang in $langs; do
            regex=
            for i in ${lang} windows ${server} ${version} ${label_msdn}; do
                if [ -n "$i" ]; then
                    regex+="${i}_"
                fi
            done
            regex+=".*${arch_win}.*.(iso|img)"
            regexs+=("$regex")
        done
    fi

    if [ -n "$label_vlsc" ] && [ -n "$full_lang" ]; then
        regex="sw_?dvd[59]_win_?${label_vlsc}_?${version}.*${arch_win_vlsc}_${full_lang}.*.(iso|img)"
        regexs+=("$regex")
    fi

    for regex in "${regexs[@]}"; do
        regex=${regex// /_}

        echo "looking for: $regex" >&2
        if line=$(grep -Ei "^$regex " "$tmp/win.list" | get_shortest_line_by_field 1 | grep .) &&
            iso=$(awk '{print $2}' <<<"$line" | grep .); then
            echo "Selected: $line" >&2
            return
        fi
    done

    error_and_exit "Could not find iso for this windows edition or language."
}

setos() {
    local step=$1
    local distro=$2
    local releasever=$3
    info set $step $distro $releasever

    setos_netboot.xyz() {
        if is_efi; then
            if [ "$basearch" = aarch64 ]; then
                eval ${step}_efi=https://boot.netboot.xyz/ipxe/netboot.xyz-arm64.efi
            else
                eval ${step}_efi=https://boot.netboot.xyz/ipxe/netboot.xyz.efi
            fi
        else
            eval ${step}_vmlinuz=https://boot.netboot.xyz/ipxe/netboot.xyz.lkrn
        fi
    }

    setos_alpine() {
        is_virt && flavour=virt || flavour=lts

        if is_in_china; then
            mirror=http://mirror.nju.edu.cn/alpine/v$releasever
        else
            mirror=http://dl-cdn.alpinelinux.org/alpine/v$releasever
        fi
        eval ${step}_vmlinuz=$mirror/releases/$basearch/netboot/vmlinuz-$flavour
        eval ${step}_initrd=$mirror/releases/$basearch/netboot/initramfs-$flavour
        eval ${step}_modloop=$mirror/releases/$basearch/netboot/modloop-$flavour
        eval ${step}_repo=$mirror/main
    }

    setos_debian() {
        is_debian_elts() {
            [ "$releasever" -le 10 ]
        }

        if [ "$releasever" -le 9 ] && [ "$basearch" = aarch64 ]; then
            error_and_exit "Debian $releasever ELTS does not support aarch64."
        fi

        # shellcheck disable=SC2034
        is_debian_elts && elts=1 || elts=0

        case "$releasever" in
        9) codename=stretch ;;
        10) codename=buster ;;
        11) codename=bullseye ;;
        12) codename=bookworm ;;
        13) codename=trixie ;;
        14) codename=forky ;;
        15) codename=duke ;;
        esac

        if ! is_use_cloud_image && is_debian_elts && is_in_china; then
            warn "
Due to the lack of Debian Freexian ELTS instaler mirrors in China, the installation time may be longer.
Continue?

由于没有 Debian Freexian ELTS 国内安装源，安装时间可能会比较长。
继续安装?
"
            read -r -p '[y/N]: '
            if ! [[ "$REPLY" = [Yy] ]]; then
                exit
            fi
        fi

        if is_debian_elts; then
            if is_in_china; then
                udeb_mirror=deb.freexian.com/extended-lts
                deb_mirror=mirror.nju.edu.cn/debian-elts
                initrd_mirror=mirror.nju.edu.cn/debian-archive/debian
            else
                udeb_mirror=deb.freexian.com/extended-lts
                deb_mirror=deb.freexian.com/extended-lts
                initrd_mirror=archive.debian.org/debian
            fi
        else
            if is_in_china; then
                mirror=mirror.nju.edu.cn/debian
            else
                mirror=deb.debian.org/debian
            fi
            udeb_mirror=$mirror
            deb_mirror=$mirror
            initrd_mirror=$mirror
        fi

        if is_in_china; then
            cdimage_mirror=https://mirror.nju.edu.cn/debian-cdimage
        else
            cdimage_mirror=https://cdimage.debian.org/images
        fi

        is_virt && flavour=-cloud || flavour=
        [ "$releasever" -le 10 ] && flavour=
        [ "$basearch_alt" = arm64 ] && flavour=

        if is_use_cloud_image; then
            ci_type=nocloud
            eval ${step}_img=$cdimage_mirror/cloud/$codename/latest/debian-$releasever-$ci_type-$basearch_alt.qcow2
        else
            initrd_dir=dists/$codename/main/installer-$basearch_alt/current/images/netboot/debian-installer/$basearch_alt

            eval ${step}_udeb_mirror=$udeb_mirror
            eval ${step}_vmlinuz=https://$initrd_mirror/$initrd_dir/linux
            eval ${step}_initrd=https://$initrd_mirror/$initrd_dir/initrd.gz
            eval ${step}_ks=$confhome/debian.cfg
            eval ${step}_firmware=$cdimage_mirror/unofficial/non-free/firmware/$codename/current/firmware.cpio.gz
            eval ${step}_codename=$codename
        fi

        eval ${step}_deb_mirror=$deb_mirror
        eval ${step}_kernel=linux-image$flavour-$basearch_alt
    }

    setos_kali() {
        if is_use_cloud_image; then
            :
        else
            if is_in_china; then
                hostname=mirror.nju.edu.cn
            else
                hostname=kali.download
            fi
            codename=kali-rolling
            mirror=http://$hostname/kali/dists/$codename/main/installer-$basearch_alt/current/images/netboot/debian-installer/$basearch_alt

            is_virt && flavour=-cloud || flavour=

            eval ${step}_vmlinuz=$mirror/linux
            eval ${step}_initrd=$mirror/initrd.gz
            eval ${step}_ks=$confhome/debian.cfg
            eval ${step}_deb_mirror=$hostname/kali
            eval ${step}_udeb_mirror=$hostname/kali
            eval ${step}_codename=$codename
            eval ${step}_kernel=linux-image$flavour-$basearch_alt
        fi
    }

    setos_ubuntu() {
        case "$releasever" in
        16.04) codename=xenial ;;
        18.04) codename=bionic ;;
        20.04) codename=focal ;;
        22.04) codename=jammy ;;
        24.04) codename=noble ;;
        25.10) codename=questing ;;
        esac

        if is_use_cloud_image; then
            if is_in_china; then
                ci_mirror=https://mirror.nju.edu.cn/ubuntu-cloud-images
            else
                ci_mirror=https://cloud-images.ubuntu.com
            fi

            is_have_minimal_image() {
                [ "$basearch_alt" = amd64 ] || [ "${releasever%.*}" -ge 24 ]
            }

            get_suffix() {
                if [ "$releasever" = 16.04 ]; then
                    if is_efi; then
                        echo -uefi1
                    else
                        echo -disk1
                    fi
                fi
            }

            if [ "$minimal" = 1 ]; then
                if ! is_have_minimal_image; then
                    error_and_exit "Minimal cloud image is not available for $releasever $basearch_alt."
                fi
                eval ${step}_img="$ci_mirror/minimal/releases/$codename/release/ubuntu-$releasever-minimal-cloudimg-$basearch_alt$(get_suffix).img"
            else
                eval ${step}_img="$ci_mirror/releases/$codename/release/ubuntu-$releasever-server-cloudimg-$basearch_alt$(get_suffix).img"
            fi
        else
            if is_in_china; then
                case "$basearch" in
                "x86_64") mirror=https://mirror.nju.edu.cn/ubuntu-releases/$releasever ;;
                "aarch64") mirror=https://mirror.nju.edu.cn/ubuntu-cdimage/releases/$releasever/release ;;
                esac
            else
                case "$basearch" in
                "x86_64") mirror=https://releases.ubuntu.com/$releasever ;;
                "aarch64") mirror=https://cdimage.ubuntu.com/releases/$releasever/release ;;
                esac
            fi

            filename=$(curl -L $mirror/ | grep -oP "ubuntu-$releasever.*?-live-server-$basearch_alt.iso" |
                sort -uV | tail -1 | grep .)
            iso=$mirror/$filename
            test_url "$iso" iso
            eval ${step}_iso=$iso

            eval ${step}_ks=$confhome/ubuntu.yaml
            eval ${step}_minimal=$minimal
        fi
    }

    setos_arch() {
        if [ "$basearch" = "x86_64" ]; then
            if is_in_china; then
                mirror=https://mirror.nju.edu.cn/archlinux
            else
                mirror=https://geo.mirror.pkgbuild.com
            fi
        else
            if is_in_china; then
                mirror=https://mirror.nju.edu.cn/archlinuxarm
            else
                mirror=http://mirror.archlinuxarm.org
            fi
        fi

        if is_use_cloud_image; then
            eval ${step}_img=$mirror/images/latest/Arch-Linux-x86_64-cloudimg.qcow2
        else
            case "$basearch" in
            x86_64) dir="core/os/$basearch" ;;
            aarch64) dir="$basearch/core" ;;
            esac
            test_url $mirror/$dir/core.db gzip
            eval ${step}_mirror=$mirror
        fi
    }

    setos_nixos() {
        if is_in_china; then
            mirror=https://mirror.nju.edu.cn/nix-channels
        else
            mirror=https://nixos.org/channels
        fi

        if is_use_cloud_image; then
            :
        else
            test_url $mirror/nixos-$releasever/store-paths.xz 'xz text'
            eval ${step}_mirror=$mirror
        fi
    }

    setos_gentoo() {
        if is_in_china; then
            mirror=https://mirror.nju.edu.cn/gentoo
        else
            mirror=https://distfiles.gentoo.org
        fi

        dir=releases/$basearch_alt/autobuilds

        if is_use_cloud_image; then
            prefix=di-$basearch_alt-console
            filename=$(curl -L $mirror/$dir/latest-$prefix.txt | grep '.qcow2' | awk '{print $1}' | grep .)
            file=$mirror/$dir/$filename
            test_url "$file" 'qemu'
            eval ${step}_img=$file
        else
            prefix=stage3-$basearch_alt-systemd
            filename=$(curl -L $mirror/$dir/latest-$prefix.txt | grep '.tar.xz' | awk '{print $1}' | grep .)
            file=$mirror/$dir/$filename
            test_url "$file" 'tar.xz'
            eval ${step}_img=$file
        fi
    }

    setos_opensuse() {
        if is_in_china; then
            mirror=https://mirror.nju.edu.cn/opensuse
        else
            mirror=https://downloadcontentcdn.opensuse.org
        fi

        if [ "$releasever" = tumbleweed ]; then
            if [ "$basearch" = aarch64 ]; then
                dir=ports/aarch64/tumbleweed/appliances
            else
                dir=tumbleweed/appliances
            fi
            file=openSUSE-Tumbleweed-Minimal-VM.$basearch-Cloud.qcow2
        else
            dir=distribution/leap/$releasever/appliances
            case "$releasever" in
            15.6) file=openSUSE-Leap-$releasever-Minimal-VM.$basearch-Cloud.qcow2 ;;
            16.0) file=Leap-$releasever-Minimal-VM.$basearch-Cloud.qcow2 ;;
            esac
        fi
        eval ${step}_img=$mirror/$dir/$file
    }

    setos_windows() {
        auto_find_iso=false
        if [ -z "$iso" ]; then
            auto_find_iso=true
            image_name=${image_name/windows longhorn serverdatacenter/windows server 2008 server}
            echo "iso url is not set. Attempting to find it automatically."
            find_windows_iso
        fi

        image_name=${image_name/windows server 2008 server/windows longhorn server}

        if [[ "$iso" = magnet:* ]]; then
            :
        else
            iso_is_tested=false
            if $auto_find_iso; then
                if test_url_grace "$iso" iso 2>/dev/null; then
                    iso_is_tested=true
                else
                    info "Set Direct link"
                    echo "请在浏览器中打开 $iso 获取直链并粘贴到这里。"
                    echo "Please open $iso in browser to get the direct link and paste it here."
                    IFS= read -r -p "Direct Link: " iso
                    if [ -z "$iso" ]; then
                        error_and_exit "ISO Link is empty."
                    fi
                fi
            fi

            if ! $iso_is_tested; then
                test_url "$iso" iso
            fi

            if file -b "$tmp/img-test" | grep -Eq '_(A64|ARM64)'; then
                iso_arch=arm64
            else
                iso_arch=x86_or_x64
            fi

            if ! {
                { [ "$basearch" = x86_64 ] && [ "$iso_arch" = x86_or_x64 ]; } ||
                    { [ "$basearch" = aarch64 ] && [ "$iso_arch" = arm64 ]; }
            }; then
                warn "
The current machine is $basearch, but it seems the ISO is for $iso_arch. Continue?
当前机器是 $basearch，但 ISO 似乎是 $iso_arch。继续安装?"
                read -r -p '[y/N]: '
                if ! [[ "$REPLY" = [Yy] ]]; then
                    exit
                fi
            fi
        fi

        [ -n "$boot_wim" ] && test_url "$boot_wim" 'wim'

        eval "${step}_iso='$iso'"
        eval "${step}_boot_wim='$boot_wim'"
        eval "${step}_image_name='$image_name'"
    }

    # shellcheck disable=SC2154
    setos_dd() {
        test_url $img 'raw raw.gzip raw.xz raw.zstd raw.tar.gzip raw.tar.xz raw.tar.zstd' img_type

        if is_efi; then
            install_pkg hexdump
            hexdump -n $((34 * 4096)) -e '128/1 "%02x" "\n"' -v "$tmp/img-test" >$tmp/img-test-hex
            if grep -q '^28732ac11ff8d211ba4b00a0c93ec93b' $tmp/img-test-hex; then
                echo 'DD: Image is EFI.'
            else
                echo 'DD: Image is not EFI.'
                warn '
The current machine uses EFI boot, but the DD image seems not an EFI image.
Continue with DD?
当前机器使用 EFI 引导，但 DD 镜像可能不是 EFI 镜像。
继续 DD?'
                read -r -p '[y/N]: '
                if [[ "$REPLY" = [Yy] ]]; then
                    eval ${step}_confirmed_no_efi=1
                else
                    exit
                fi
            fi
        fi
        eval "${step}_img='$img'"
        eval "${step}_img_type='$img_type'"
        eval "${step}_img_type_warp='$img_type_warp'"
    }

    setos_fnos() {
        min=8
        default=8
        echo "请输入系统分区大小，最小 $min GB，但可能无法更新系统。"
        echo "Please input System Partition Size. Minimal is $min GB but may not be able to do system updates."
        while true; do
            IFS= read -r -p "Size in GB [$default]: " input
            input=${input:-$default}
            if ! { is_digit "$input" && [ "$input" -ge "$min" ]; }; then
                error "Invalid Size. Please Try again."
            else
                eval "${step}_fnos_part_size=${input}G"
                break
            fi
        done

        if [ -z "$iso" ]; then
            iso=$(curl -L "https://fnnas.com/download$([ "$basearch" = aarch64 ] && echo -arm)" |
                grep -o 'https://[^"]*\.iso' | head -1 | grep .)

            iso=$(curl -L \
                -d '{"url":"'$iso'"}' \
                -H 'Content-Type: application/json' \
                https://www.fnnas.com/api/download-sign |
                grep -o 'https://[^"]*')
        fi

        test_url "$iso" iso
        eval "${step}_iso='$iso'"
    }

    setos_aosc() {
        if is_in_china; then
            mirror=https://mirror.nju.edu.cn/anthon/aosc-os
        else
            mirror=https://releases.aosc.io
        fi

        dir=os-$basearch_alt/base
        file=$(curl -L $mirror/$dir/ | grep -oP 'aosc-os_base_.*?\.tar.xz' |
            sort -uV | tail -1 | grep .)
        img=$mirror/$dir/$file
        test_url $img 'tar.xz'
        eval ${step}_img=$img
    }

    setos_centos_almalinux_rocky_fedora() {
        if [ "$basearch" = x86_64 ] &&
            { [ "$distro" = centos ] || [ "$distro" = rocky ]; } &&
            [ "$releasever" -ge 10 ]; then
            assert_cpu_supports_x86_64_v3
        fi

        elarch=$basearch
        if [ "$basearch" = x86_64 ] &&
            [ "$distro" = almalinux ] && [ "$releasever" -ge 10 ] &&
            ! is_cpu_supports_x86_64_v3; then
            elarch=x86_64_v2
        fi

        if is_use_cloud_image; then
            if is_in_china; then
                case $distro in
                centos) ci_mirror="https://mirror.nju.edu.cn/centos-cloud/centos" ;;
                almalinux) ci_mirror="https://mirror.nju.edu.cn/almalinux/$releasever/cloud/$elarch/images" ;;
                rocky) ci_mirror="https://mirror.nju.edu.cn/rocky/$releasever/images/$elarch" ;;
                fedora) ci_mirror="https://mirror.nju.edu.cn/fedora/releases/$releasever/Cloud/$elarch/images" ;;
                esac
            else
                case $distro in
                centos) ci_mirror="https://cloud.centos.org/centos" ;;
                almalinux) ci_mirror="https://repo.almalinux.org/almalinux/$releasever/cloud/$elarch/images" ;;
                rocky) ci_mirror="https://download.rockylinux.org/pub/rocky/$releasever/images/$elarch" ;;
                fedora) ci_mirror="https://d2lzkl7pfhq30w.cloudfront.net/pub/fedora/linux/releases/$releasever/Cloud/$elarch/images" ;;
                esac
            fi
            case $distro in
            centos)
                case $releasever in
                7)
                    ver=-2211
                    ci_image=$ci_mirror/$releasever/images/CentOS-$releasever-$elarch-GenericCloud$ver.qcow2c
                    ;;
                *)
                    [ "$elarch" = x86_64 ] &&
                        ci_image=$ci_mirror/$releasever-stream/$elarch/images/CentOS-Stream-GenericCloud-x86_64-$releasever-latest.$elarch.qcow2 ||
                        ci_image=$ci_mirror/$releasever-stream/$elarch/images/CentOS-Stream-GenericCloud-$releasever-latest.$elarch.qcow2
                    ;;
                esac
                ;;
            almalinux) ci_image=$ci_mirror/AlmaLinux-$releasever-GenericCloud-latest.$elarch.qcow2 ;;
            rocky) ci_image=$ci_mirror/Rocky-$releasever-GenericCloud-Base.latest.$elarch.qcow2 ;;
            fedora)
                filename=$(curl -L $ci_mirror/ | grep -oP "Fedora-Cloud-Base-Generic.*?.qcow2" |
                    sort -uV | tail -1 | grep .)
                ci_image=$ci_mirror/$filename
                ;;
            esac

            eval ${step}_img=${ci_image}
        else
            case $distro in
            centos) mirrorlist="https://mirrors.centos.org/mirrorlist?repo=centos-baseos-$releasever-stream&arch=$elarch" ;;
            almalinux) mirrorlist="https://mirrors.almalinux.org/mirrorlist/$releasever/baseos" ;;
            rocky) mirrorlist="https://mirrors.rockylinux.org/mirrorlist?arch=$elarch&repo=BaseOS-$releasever" ;;
            fedora) mirrorlist="https://mirrors.fedoraproject.org/mirrorlist?arch=$elarch&repo=fedora-$releasever" ;;
            esac

            for cur_mirror in $(curl -L $mirrorlist | sed "/^#/d" | sed "s,\$basearch,$elarch,"); do
                host=$(get_host_by_url $cur_mirror)
                if is_host_has_ipv4_and_ipv6 $host &&
                    test_url_grace ${cur_mirror}images/pxeboot/vmlinuz; then
                    mirror=$cur_mirror
                    break
                fi
            done

            if [ -z "$mirror" ]; then
                error_and_exit "All mirror failed."
            fi

            eval "${step}_mirrorlist='${mirrorlist}'"

            eval ${step}_ks=$confhome/redhat.cfg
            eval ${step}_vmlinuz=${mirror}images/pxeboot/vmlinuz
            eval ${step}_initrd=${mirror}images/pxeboot/initrd.img
            eval ${step}_squashfs=${mirror}images/install.img
            test_url ${mirror}images/install.img 'squashfs'
        fi
    }

    setos_oracle() {
        if [ "$basearch" = x86_64 ] && [ "$releasever" -ge 10 ]; then
            assert_cpu_supports_x86_64_v3
        fi

        if is_use_cloud_image; then
            install_pkg jq
            mirror=https://yum.oracle.com

            [ "$basearch" = aarch64 ] &&
                template_prefix=ol${releasever}_${basearch}-cloud ||
                template_prefix=ol${releasever}
            curl -Lo $tmp/oracle.json $mirror/templates/OracleLinux/$template_prefix-template.json
            dir=$(jq -r .base_url $tmp/oracle.json)
            file=$(jq -r .kvm.image $tmp/oracle.json)
            ci_image=$mirror$dir/$file

            eval ${step}_img=${ci_image}
        else
            :
        fi
    }

    setos_redhat() {
        if is_use_cloud_image; then
            if [ "$basearch" = x86_64 ] && [[ "$img" = *rhel-10* ]]; then
                assert_cpu_supports_x86_64_v3
            fi
            eval "${step}_img='$img'"
        else
            :
        fi
    }

    setos_opencloudos() {
        if [ "$releasever" -ge 23 ]; then
            mirror=https://mirrors.opencloudos.tech/opencloudos-stream/releases
        else
            mirror=https://mirrors.cloud.tencent.com/opencloudos
        fi

        if is_use_cloud_image; then
            if [ "$releasever" -eq 9 ]; then
                dir=$releasever/images/qcow2/$basearch
            else
                dir=$releasever/images/$basearch
            fi

            file=$(curl -L $mirror/$dir/ | grep -oP 'OpenCloudOS.*?\.qcow2' |
                sort -uV | tail -1 | grep .)
            eval ${step}_img=$mirror/$dir/$file
        else
            :
        fi
    }

    setos_anolis() {
        mirror=https://mirrors.openanolis.cn/anolis
        if is_use_cloud_image; then
            dir=$releasever/isos/GA/$basearch
            [ "$releasever" -ge 23 ] &&
                filename='AnolisOS.*?\.qcow2' ||
                filename='AnolisOS.*?-ANCK\.qcow2'
            file=$(curl -L $mirror/$dir/ | grep -oP "$filename" |
                sort -uV | tail -1 | grep .)
            eval ${step}_img=$mirror/$dir/$file
        else
            :
        fi
    }

    setos_openeuler() {
        if is_in_china; then
            mirror=https://repo.openeuler.openatom.cn
        else
            mirror=https://repo.openeuler.org
        fi
        if is_use_cloud_image; then
            name=$(curl -L "$mirror/" | grep -oE "openEuler-$releasever(-LTS)?(-SP[0-9])?" |
                sort -uV | tail -1 | grep .)
            eval ${step}_img=$mirror/$name/virtual_machine_img/$basearch/$name-$basearch.qcow2.xz
        else
            :
        fi
    }

    eval ${step}_distro=$distro
    eval ${step}_releasever=$releasever

    case "$distro" in
    centos | almalinux | rocky | fedora) setos_centos_almalinux_rocky_fedora ;;
    *) setos_$distro ;;
    esac

    if is_distro_like_debian && ! is_in_windows && [ "$ram_size" -le 256 ]; then
        exit_if_cant_use_cloud_kernel
    fi

    if is_use_cloud_image && [ "$step" = finalos ]; then
        # shellcheck disable=SC2154
        test_url $finalos_img 'qemu qemu.gzip qemu.xz qemu.zstd raw.xz' finalos_img_type
    fi
}

is_distro_like_redhat() {
    if [ -n "$1" ]; then
        _distro=$1
    else
        _distro=$distro
    fi
    [ "$_distro" = redhat ] || [ "$_distro" = centos ] || [ "$_distro" = almalinux ] || [ "$_distro" = rocky ] || [ "$_distro" = fedora ] || [ "$_distro" = oracle ]
}

is_distro_like_debian() {
    if [ -n "$1" ]; then
        _distro=$1
    else
        _distro=$distro
    fi
    [ "$_distro" = debian ] || [ "$_distro" = kali ]
}

get_latest_distro_releasever() {
    get_function_content verify_os_name |
        grep -wo "$1 [^'\"]*" | awk -F'|' '{print $NF}'
}

verify_os_name() {
    if [ -z "$*" ]; then
        usage_and_exit
    fi

    for os in \
        'centos      7|9|10' \
        'anolis      7|8|23' \
        'opencloudos 8|9|23' \
        'almalinux   8|9|10' \
        'rocky       8|9|10' \
        'oracle      8|9|10' \
        'fnos        1' \
        'fedora      42|43' \
        'nixos       25.11' \
        'debian      9|10|11|12|13' \
        'opensuse    15.6|16.0|tumbleweed' \
        'alpine      3.20|3.21|3.22|3.23' \
        'openeuler   20.03|22.03|24.03|25.09' \
        'ubuntu      16.04|18.04|20.04|22.04|24.04|25.10' \
        'redhat' \
        'kali' \
        'arch' \
        'gentoo' \
        'aosc' \
        'windows' \
        'dd' \
        'netboot.xyz' \
        'reset'; do
        read -r ds vers <<<"$os"
        vers_=${vers//\./\\\.}
        finalos=$(echo "$@" | to_lower | sed -n -E "s,^($ds)[ :-]?(|$vers_)$,\1 \2,p")
        if [ -n "$finalos" ]; then
            read -r distro releasever <<<"$finalos"
            if [ -z "$releasever" ] && [ -n "$vers" ]; then
                releasever=$(awk -F '|' '{print $NF}' <<<"|$vers")
            fi
            return
        fi
    done

    error "Please specify a proper os"
    usage_and_exit
}

verify_os_args() {
    case "$distro" in
    dd) [ -n "$img" ] || error_and_exit "dd need --img" ;;
    redhat) [ -n "$img" ] || error_and_exit "redhat need --img" ;;
    windows) [ -n "$image_name" ] || error_and_exit "Install Windows need --image-name." ;;
    esac

    case "$distro" in
    netboot.xyz | windows) [ -z "$ssh_keys" ] || error_and_exit "not support ssh key for $distro" ;;
    esac
}

get_cmd_path() {
    type -f -p $1
}

is_have_cmd() {
    get_cmd_path $1 >/dev/null 2>&1
}

install_pkg() {
    is_in_windows && return

    find_pkg_mgr() {
        [ -n "$pkg_mgr" ] && return

        if [ -f /etc/os-release ]; then
            # shellcheck source=/dev/null
            for id in $({ . /etc/os-release && echo $ID $ID_LIKE; }); do
                case "$id" in
                fedora | centos | rhel) is_have_cmd dnf && pkg_mgr=dnf || pkg_mgr=yum ;;
                debian | ubuntu) pkg_mgr=apt-get ;;
                opensuse | suse) pkg_mgr=zypper ;;
                alpine) pkg_mgr=apk ;;
                arch) pkg_mgr=pacman ;;
                gentoo) pkg_mgr=emerge ;;
                nixos) pkg_mgr=nix-env ;;
                esac
                [ -n "$pkg_mgr" ] && return
            done
        fi

        for mgr in dnf yum apt-get pacman zypper emerge apk nix-env; do
            is_have_cmd $mgr && pkg_mgr=$mgr && return
        done

        return 1
    }

    cmd_to_pkg() {
        unset USE
        case $cmd in
        ar)
            case "$pkg_mgr" in
            *) pkg="binutils" ;;
            esac
            ;;
        xz)
            case "$pkg_mgr" in
            apt-get) pkg="xz-utils" ;;
            *) pkg="xz" ;;
            esac
            ;;
        lsblk | findmnt)
            case "$pkg_mgr" in
            apk) pkg="$cmd" ;;
            *) pkg="util-linux" ;;
            esac
            ;;
        lsmem)
            case "$pkg_mgr" in
            apk) pkg="util-linux-misc" ;;
            *) pkg="util-linux" ;;
            esac
            ;;
        fdisk)
            case "$pkg_mgr" in
            apt-get) pkg="fdisk" ;;
            apk) pkg="util-linux-misc" ;;
            *) pkg="util-linux" ;;
            esac
            ;;
        hexdump)
            case "$pkg_mgr" in
            apt-get) pkg="bsdmainutils" ;;
            *) pkg="util-linux" ;;
            esac
            ;;
        unsquashfs)
            case "$pkg_mgr" in
            zypper) pkg="squashfs" ;;
            emerge) pkg="squashfs-tools" && export USE="lzma" ;;
            *) pkg="squashfs-tools" ;;
            esac
            ;;
        nslookup | dig)
            case "$pkg_mgr" in
            apt-get) pkg="dnsutils" ;;
            pacman) pkg="bind" ;;
            apk | emerge) pkg="bind-tools" ;;
            yum | dnf | zypper) pkg="bind-utils" ;;
            esac
            ;;
        iconv)
            case "$pkg_mgr" in
            apk) pkg="musl-utils" ;;
            *) error_and_exit "Which GNU/Linux do not have iconv built-in?" ;;
            esac
            ;;
        *) pkg=$cmd ;;
        esac
    }

    check_is_need_epel() {
        is_need_epel() {
            case "$pkg" in
            dpkg) true ;;
            jq) is_have_cmd yum && ! is_have_cmd dnf ;;
            *) false ;;
            esac
        }

        get_epel_repo_name() {
            $pkg_mgr repolist all | awk '{print $1}' | awk -F/ '{print $1}' | grep -Ei 'ep(el|ol|ao)$'
        }

        get_epel_pkg_name() {
            $pkg_mgr list available | grep -E '(.*-)?ep(el|ol|ao)-(.*-)?release' |
                awk '{print $1}' | cut -d. -f1 | grep -v next | head -1
        }

        if is_need_epel; then
            if ! epel=$(get_epel_repo_name); then
                $pkg_mgr install -y "$(get_epel_pkg_name)"
                epel=$(get_epel_repo_name)
            fi
            enable_epel="--enablerepo=$epel"
        else
            enable_epel=
        fi
    }

    install_pkg_real() {
        text="$pkg"
        if [ "$pkg" != "$cmd" ]; then
            text+=" ($cmd)"
        fi
        echo "Installing package '$text'..."

        case $pkg_mgr in
        dnf)
            check_is_need_epel
            dnf install $enable_epel -y --setopt=install_weak_deps=False $pkg
            ;;
        yum)
            check_is_need_epel
            yum install $enable_epel -y $pkg
            ;;
        emerge) emerge --oneshot $pkg ;;
        pacman) pacman -Syu --noconfirm --needed $pkg ;;
        zypper) zypper install -y $pkg ;;
        apk)
            add_community_repo_for_alpine
            apk add $pkg
            ;;
        apt-get)
            [ -z "$apt_updated" ] && apt-get update && apt_updated=1
            DEBIAN_FRONTEND=noninteractive apt-get install -y $pkg
            ;;
        nix-env)
            [ -z "$nix_updated" ] && nix-channel --update && nix_updated=1
            nix-env -iA nixos.$pkg
            ;;
        esac
    }

    is_need_reinstall() {
        cmd=$1

        if [ "$cmd" = unsquashfs ] && is_have_cmd emerge && ! $cmd |& grep -wq xz; then
            echo "unsquashfs not supported xz. rebuilding."
            return 0
        fi

        if [ "$cmd" = fdisk ] && is_have_cmd apk && $cmd |& grep -wq BusyBox; then
            return 0
        fi

        if [ "$cmd" = grep ] && is_have_cmd apk && $cmd |& grep -wq BusyBox; then
            return 0
        fi

        return 1
    }

    for cmd in "$@"; do
        if ! is_have_cmd $cmd || is_need_reinstall $cmd; then
            if ! find_pkg_mgr; then
                error_and_exit "Can't find compatible package manager. Please manually install $cmd."
            fi
            cmd_to_pkg
            install_pkg_real
        fi
    done >&2
}

is_valid_ram_size() {
    is_digit "$1" && [ "$1" -gt 0 ]
}

check_ram() {
    ram_standard=$(
        case "$distro" in
        netboot.xyz) echo 0 ;;
        alpine | debian | kali | dd) echo 256 ;;
        arch | gentoo | aosc | nixos | windows) echo 512 ;;
        redhat | centos | almalinux | rocky | fedora | oracle | ubuntu | anolis | opencloudos | openeuler) echo 1024 ;;
        opensuse | fnos) echo -1 ;;
        esac
    )

    if [ "$ram_standard" -eq 0 ]; then
        return
    fi

    ram_cloud_image=256

    has_cloud_image=$(
        case "$distro" in
        redhat | centos | almalinux | rocky | oracle | fedora | debian | ubuntu | opensuse | anolis | openeuler) echo true ;;
        netboot.xyz | alpine | dd | arch | gentoo | nixos | kali | windows) echo false ;;
        esac
    )

    if is_in_windows; then
        ram_size=$(wmic memorychip get capacity | awk -F= '{sum+=$2} END {if(sum>0) print sum/1024/1024}')
    else
        install_pkg lsmem
        ram_size=$(lsmem -b 2>/dev/null | grep 'Total online memory:' | awk '{ print $NF/1024/1024 }')

        if ! is_valid_ram_size "$ram_size"; then
            install_pkg dmidecode
            ram_size=$(dmidecode -t 17 | grep "Size.*[GM]B" | awk '{if ($3=="GB") s+=$2*1024; else s+=$2} END {if(s>0) print s}')
        fi

        if ! is_valid_ram_size "$ram_size"; then
            install_pkg lshw
            ram_str=$(lshw -c memory -short | grep -i 'System Memory' | awk '{print $3}')
            ram_size=$(grep <<<$ram_str -o '[0-9]*')
            grep <<<$ram_str GiB && ram_size=$((ram_size * 1024))
        fi
    fi

    if ! is_valid_ram_size "$ram_size"; then
        ram_size_k=$(grep '^MemTotal:' /proc/meminfo | awk '{print $2}')
        ram_size=$((ram_size_k / 1024 + 64 + 4))
    fi

    if ! is_valid_ram_size "$ram_size"; then
        error_and_exit "Could not detect RAM size."
    fi

    if ! is_use_cloud_image && [ $ram_size -lt $ram_standard ]; then
        if $has_cloud_image; then
            info "RAM < $ram_standard MB. Fallback to cloud image mode"
            cloud_image=1
        else
            error_and_exit "Could not install $distro: RAM < $ram_standard MB."
        fi
    fi

    if is_use_cloud_image && [ $ram_size -lt $ram_cloud_image ]; then
        error_and_exit "Could not install $distro using cloud image: RAM < $ram_cloud_image MB."
    fi
}

is_efi() {
    if is_in_windows; then
        mountvol | grep -q --text 'EFI'
    else
        [ -d /sys/firmware/efi ]
    fi
}

is_grub_dir_linked() {
    [ "$(readlink -f /boot/grub/grub.cfg)" = /boot/grub2/grub.cfg ] ||
        [ "$(readlink -f /boot/grub2/grub.cfg)" = /boot/grub/grub.cfg ] ||
        { [ -f /boot/grub2/grub.cfg ] && [ "$(cat /boot/grub2/grub.cfg)" = 'chainloader (hd0)+1' ]; }
}

is_secure_boot_enabled() {
    if is_efi; then
        if is_in_windows; then
            reg query 'HKLM\SYSTEM\CurrentControlSet\Control\SecureBoot\State' /v UEFISecureBootEnabled 2>/dev/null | grep 0x1
        else
            if dmesg | grep -i 'Secure boot enabled'; then
                return 0
            fi
            install_pkg mokutil
            mokutil --sb-state 2>&1 | grep -i 'SecureBoot enabled'
        fi
    else
        return 1
    fi
}

is_need_boot_vmlinuz() {
    ! { is_netboot_xyz && is_efi; }
}

is_use_local_grub_extlinux() {
    is_need_boot_vmlinuz && ! is_in_windows && ! is_efi
}

is_use_local_grub() {
    is_use_local_grub_extlinux && is_mbr_using_grub
}

is_use_local_extlinux() {
    is_use_local_grub_extlinux && ! is_mbr_using_grub
}

is_mbr_using_grub() {
    find_main_disk
    head -c 440 /dev/$xda | grep --text -iq 'GRUB'
}

to_upper() {
    tr '[:lower:]' '[:upper:]'
}

to_lower() {
    tr '[:upper:]' '[:lower:]'
}

del_cr() {
    sed -E 's/\r+$//'
}

del_empty_lines() {
    sed '/^[[:space:]]*$/d'
}

del_comment_lines() {
    sed '/^[[:space:]]*#/d'
}

trim() {
    sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'
}

prompt_password() {
    info "prompt password"
    warn false "Leave blank to use a random password."
    warn false "不填写则使用随机密码"
    while true; do
        IFS= read -r -p "Password: " password
        if [ -n "$password" ]; then
            IFS= read -r -p "Retype password: " password_confirm
            if [ "$password" = "$password_confirm" ]; then
                break
            else
                error "Passwords don't match. Try again."
            fi
        else
            chars=\''A-Za-z0-9~!@#$%^&*_=+`|(){}[]:;"<>,.?/-'
            password=$(tr -dc "$chars" </dev/urandom | head -c16)
            break
        fi
    done
}

save_password() {
    dir=$1

    if false; then
        printf '%s' "$password" >>"$dir/password-plaintext"
    fi

    if is_have_cmd busybox && busybox mkpasswd --help 2>&1 | grep -wq sha512; then
        crypted=$(printf '%s' "$password" | busybox mkpasswd -m sha512)
    elif install_pkg openssl && openssl passwd --help 2>&1 | grep -wq '\-6'; then
        crypted=$(printf '%s' "$password" | openssl passwd -6 -stdin)
    elif is_have_cmd apt-get && install_pkg whois && mkpasswd -m help | grep -wq sha-512; then
        crypted=$(printf '%s' "$password" | mkpasswd -m sha-512 --stdin)
    elif is_have_cmd yum && is_have_cmd python2; then
        crypted=$(python2 -c "import crypt, sys; print(crypt.crypt(sys.argv[1], crypt.mksalt(crypt.METHOD_SHA512)))" "$password")
    else
        error_and_exit "Could not generate sha512 password."
    fi
    echo "$crypted" >"$dir/password-linux-sha512"

    if [ "$distro" = windows ] || [ "$distro" = dd ]; then
        install_pkg iconv

        base64=$(printf '%s' "${password}Password" | iconv -f UTF-8 -t UTF-16LE | base64 -w 0 | grep .)
        echo "$base64" >"$dir/password-windows-user-base64"

        base64=$(printf '%s' "${password}AdministratorPassword" | iconv -f UTF-8 -t UTF-16LE | base64 -w 0 | grep .)
        echo "$base64" >"$dir/password-windows-administrator-base64"
    fi
}

find_main_disk() {
    if [ -n "$main_disk" ]; then
        return
    fi

    if is_in_windows; then
        main_disk=$(printf "%s\n%s" "select volume $c" "uniqueid disk" | diskpart |
            tail -1 | awk '{print $NF}' | sed 's,[{}],,g')
    else
        if [ -z "$xda" ]; then
            install_pkg lsblk
            mapper=$(mount | awk '$3=="/" {print $1}' | grep .)
            xdas=$(lsblk -rn --inverse $mapper | grep -w disk | awk '{print $1}' | sort -u | grep .)

            if [ "$(wc -l <<<"$xdas")" -eq 1 ]; then
                xda=$xdas
            else
                info false "Multiple disks found for root partition:"
                echo '-----'
                printf "%s\n" "$xdas"
                echo '-----'
                read -r -p "Select a disk to install: " xda
                if ! grep -Fqx "$xda" <<<"$xdas"; then
                    error_and_exit "Invalid Input."
                fi
            fi
        fi

        info "Main disk: $xda"

        install_pkg fdisk
        main_disk=$(fdisk -l /dev/$xda | grep 'Disk identifier' | awk '{print $NF}' | sed 's/0x//')
    fi

    if ! grep -Eix '[0-9a-f]{8}' <<<"$main_disk" &&
        ! grep -Eix '[0-9a-f-]{36}' <<<"$main_disk"; then
        error_and_exit "Disk ID is invalid: $main_disk"
    fi
}

is_found_ipv4_netconf() {
    [ -n "$ipv4_mac" ] && [ -n "$ipv4_addr" ] && [ -n "$ipv4_gateway" ]
}

is_found_ipv6_netconf() {
    [ -n "$ipv6_mac" ] && [ -n "$ipv6_addr" ] && [ -n "$ipv6_gateway" ]
}

collect_netconf() {
    if is_in_windows; then
        convert_net_str_to_array() {
            config=$1
            key=$2
            var=$3
            IFS=',' read -r -a "${var?}" <<<"$(grep "$key=" <<<"$config" | cut -d= -f2 | sed 's/[{}\"]//g')"
        }

        for v in 4 6; do
            if [ "$v" = 4 ]; then
                routes=$(netsh int ipv4 show route | awk '$4 == "0.0.0.0/0"')
            else
                routes=$(netsh int ipv6 show route | awk '$4 == "::/0"')
            fi

            if [ -z "$routes" ]; then
                continue
            fi

            while read -r route; do
                if false; then
                    read -r _ _ _ _ id gateway <<<"$route"
                else
                    id=$(awk '{print $5}' <<<"$route")
                    gateway=$(awk '{print $6}' <<<"$route")
                fi

                config=$(wmic nicconfig where InterfaceIndex=$id get MACAddress,IPAddress,IPSubnet,DefaultIPGateway)
                if grep -q '=$' <<<"$config"; then
                    continue
                fi

                mac_addr=$(grep "MACAddress=" <<<"$config" | cut -d= -f2 | to_lower)
                convert_net_str_to_array "$config" IPAddress ips
                convert_net_str_to_array "$config" IPSubnet subnets
                convert_net_str_to_array "$config" DefaultIPGateway gateways

                # shellcheck disable=SC2154
                if [ "$v" = 4 ]; then
                    for ((i = 0; i < ${#ips[@]}; i++)); do
                        ip=${ips[i]}
                        subnet=${subnets[i]}
                        if [[ "$ip" = *.* ]]; then
                            cidr=$(mask2cidr "$subnet")
                            ipv4_addr="$ip/$cidr"
                            ipv4_gateway="$gateway"
                            ipv4_mac="$mac_addr"
                            break
                        fi
                    done
                fi

                if [ "$v" = 6 ]; then
                    ipv6_type_list=$(netsh interface ipv6 show address $id normal)
                    for ((i = 0; i < ${#ips[@]}; i++)); do
                        ip=${ips[i]}
                        cidr=${subnets[i]}
                        if [[ "$ip" = *:* ]]; then
                            ipv6_type=$(grep "$ip" <<<"$ipv6_type_list" | awk '{print $1}')
                            if [ "$ipv6_type" = Public ] ||
                                [ "$ipv6_type" = Dhcp ] ||
                                [ "$ipv6_type" = Manual ]; then
                                ipv6_addr="$ip/$cidr"
                                ipv6_gateway="$gateway"
                                ipv6_mac="$mac_addr"
                                break
                            fi
                        fi
                    done
                fi

                # shellcheck disable=SC2154
                if false; then
                    for gateway in "${gateways[@]}"; do
                        if [ -n "$ipv4_addr" ] && [[ "$gateway" = *.* ]]; then
                            ipv4_gateway="$gateway"
                        elif [ -n "$ipv6_addr" ] && [[ "$gateway" = *:* ]]; then
                            ipv6_gateway="$gateway"
                        fi
                    done
                fi

                if is_found_ipv${v}_netconf; then
                    break
                fi
            done < <(echo "$routes")
        done
    else
        for v in 4 6; do
            if via_gateway_dev_ethx=$(ip -$v route show default | grep -Ewo 'via [^ ]+ dev [^ ]+' | head -1 | grep .); then
                read -r _ gateway _ ethx <<<"$via_gateway_dev_ethx"
                eval ipv${v}_ethx="$ethx"
                eval ipv${v}_mac="$(ip link show dev $ethx | grep link/ether | head -1 | awk '{print $2}')"
                eval ipv${v}_gateway="$gateway"

                all_addrs=$(ip -$v -o addr show scope global dev $ethx | grep -v temporary | awk '{print $4}')
                primary_addr=$(echo "$all_addrs" | head -1)

                if [ "$v" = 6 ] && [ -n "$primary_addr" ]; then
                    route_src=$(ip -6 route get 2001:4860:4860::8888 dev "$ethx" 2>/dev/null | grep -oP 'src \K[^ ]+')
                    if [ -n "$route_src" ]; then
                        for addr in $all_addrs; do
                            if [ "${addr%/*}" = "$route_src" ]; then
                                primary_addr=$addr
                                break
                            fi
                        done
                    fi
                fi

                eval ipv${v}_addr="$primary_addr"
                eval ipv${v}_extra_addrs="$(echo "$all_addrs" | grep -Fxve "$primary_addr" | tr '\n' ',' | sed 's/,$//')"
            fi
        done
    fi

    if ! is_found_ipv4_netconf && ! is_found_ipv6_netconf; then
        error_and_exit "Can not get IP info."
    fi

    info "Network Info"
    echo "IPv4 MAC: $ipv4_mac"
    echo "IPv4 Address: $ipv4_addr"
    echo "IPv4 Gateway: $ipv4_gateway"
    echo "---"
    echo "IPv6 MAC: $ipv6_mac"
    echo "IPv6 Address: $ipv6_addr"
    echo "IPv6 Gateway: $ipv6_gateway"
    echo
}

get_efi_dir_in_windows() {
    if result=$(find /cygdrive/?/EFI/Microsoft/Boot/bootmgfw.efi 2>/dev/null); then
        x=$(echo $result | cut -d/ -f3)
    else
        for x in {a..z}; do
            [ ! -e /cygdrive/$x ] && break
        done
        if ! mountvol $x: /s >&2; then
            error_and_exit "Can't mount efi partition in windows."
        fi
    fi
    echo "/cygdrive/$x"
}

add_efi_entry_in_windows() {
    info "Add efi entry in windows"

    local source=$1

    dist_dir="$(get_efi_dir_in_windows)/EFI/reinstall"
    efi_drive=$(echo "$dist_dir" | cut -d/ -f3)
    basename=$(basename $source)
    download_or_copy_file "$source" "$dist_dir/$basename"

    bcdedit /set '{fwbootmgr}' displayorder '{bootmgr}' /addfirst

    id=$(bcdedit /copy '{bootmgr}' /d "$(get_entry_name)" | grep -o '{.*}')
    bcdedit /set $id device partition=$efi_drive:
    bcdedit /set $id path \\EFI\\reinstall\\$basename
    bcdedit /set '{fwbootmgr}' bootsequence $id
}

get_maybe_efi_dirs_in_linux() {
    install_pkg findmnt >&2

    root_dirs=$(findmnt -t fat,vfat -n -o TARGET | grep -Ex '/efi|/boot/efi|/boot' | sort -u)

    efi_dirs=$(
        for dir in $root_dirs; do
            if [ -d "$dir" ]; then
                find "$dir" -type f -iname "*.efi" -exec printf '%s\n' "$dir" \; -quit
            fi
        done
    )

    if [ -z "$efi_dirs" ]; then
        error_and_exit "Can't find efi partition."
    fi

    echo "$efi_dirs"
}

get_disk_by_part() {
    dev_part=$1
    install_pkg lsblk >&2
    lsblk -rn --inverse "$dev_part" | grep -w disk | awk '{print $1}'
}

get_part_num_by_part() {
    dev_part=$1
    grep -oE '[0-9]*$' <<<"$dev_part"
}

grep_efi_entry() {
    grep -E '^Boot[0-9a-fA-F]{4}'
}

grep_efi_index() {
    awk '{print $1}' | sed -e 's/Boot//' -e 's/\*//'
}

download_or_copy_file() {
    local source=$1
    local dist=$2

    mkdir -p "$(dirname $dist)"

    if [[ "$source" = http* ]]; then
        curl -Lo "$dist" "$source"
    else
        cp -f "$source" "$dist"
    fi
}

add_efi_entry_in_linux() {
    local source=$1

    info "Add efi entry in linux"

    install_pkg efibootmgr

    efi_part=$(get_maybe_efi_dirs_in_linux | head -1 | grep .)
    dist_dir=$efi_part/EFI/reinstall
    basename=$(basename $source)
    download_or_copy_file "$source" "$dist_dir/$basename"

    if false; then
        grub_probe="$(command -v grub-probe grub2-probe | head -1)"
        dev_part="$("$grub_probe" -t device "$dist_dir")"
    else
        install_pkg findmnt
        dev_part=$(findmnt -T "$dist_dir" -no SOURCE | grep '^/dev/')
    fi

    if ! {
        res=$(efibootmgr --create-only \
            --disk "/dev/$(get_disk_by_part $dev_part)" \
            --part "$(get_part_num_by_part $dev_part)" \
            --label "$(get_entry_name)" \
            --loader "\\EFI\\reinstall\\$basename") &&
            id=$(echo "$res" | grep_efi_entry | tail -1 | grep_efi_index | grep .) &&
            efibootmgr --bootnext "$id"
    }; then
        echo "$res"
        error_and_exit "Could not add efi entry."
    fi
}

get_grub_efi_filename() {
    case "$basearch" in
    x86_64) echo grubx64.efi ;;
    aarch64) echo grubaa64.efi ;;
    esac
}

install_grub_linux_efi() {
    info 'download grub efi'

    efi_distro=opensuse

    grub_efi=$(get_grub_efi_filename)

    if [ "$efi_distro" = fedora ]; then
        fedora_ver=$(get_latest_distro_releasever fedora)

        if is_in_china; then
            mirror=https://mirror.nju.edu.cn/fedora
        else
            mirror=https://d2lzkl7pfhq30w.cloudfront.net/pub/fedora/linux
        fi

        curl -Lo $tmp/$grub_efi $mirror/releases/$fedora_ver/Everything/$basearch/os/EFI/BOOT/$grub_efi
    else
        if is_in_china; then
            mirror=https://mirror.nju.edu.cn/opensuse
        else
            mirror=https://downloadcontentcdn.opensuse.org
        fi

        [ "$basearch" = x86_64 ] && ports='' || ports=/ports/$basearch

        curl -Lo $tmp/$grub_efi $mirror$ports/tumbleweed/repo/oss/EFI/BOOT/grub.efi
    fi

    add_efi_entry_in_linux $tmp/$grub_efi
}

download_and_extract_apk() {
    local alpine_ver=$1
    local package=$2
    local extract_dir=$3

    install_pkg tar xz
    is_in_china && mirror=http://mirror.nju.edu.cn/alpine || mirror=https://dl-cdn.alpinelinux.org/alpine
    package_apk=$(curl -L $mirror/v$alpine_ver/main/$basearch/ | grep -oP "$package-[^-]*-[^-]*\.apk" | sort -u)
    if ! [ "$(wc -l <<<"$package_apk")" -eq 1 ]; then
        error_and_exit "find no/multi apks."
    fi
    mkdir -p "$extract_dir"

    tar 2>&1 | grep -q BusyBox && tar_args= || tar_args=--warning=no-unknown-keyword
    curl -L "$mirror/v$alpine_ver/main/$basearch/$package_apk" | tar xz $tar_args -C "$extract_dir"
}

install_grub_win() {
    info download grub

    grub_ver=2.06

    is_in_china && grub_url=https://mirror.nju.edu.cn/gnu/grub/grub-$grub_ver-for-windows.zip ||
        grub_url=https://mirrors.kernel.org/gnu/grub/grub-$grub_ver-for-windows.zip
    curl -Lo $tmp/grub.zip $grub_url
    7z x $tmp/grub.zip -o$tmp -r -y -xr!i386-efi -xr!locale -xr!themes -bso0
    grub_dir=$tmp/grub-$grub_ver-for-windows
    grub=$grub_dir/grub

    grub_modules+=" normal minicmd serial ls echo test cat reboot halt linux chain search all_video configfile"
    grub_modules+=" scsi part_msdos part_gpt fat ntfs ntfscomp lzopio xzio gzio zstd"
    if ! is_efi; then
        grub_modules+=" biosdisk linux16"
    fi

    prefix=$($grub-probe -t drive $c: | sed 's|.*PhysicalDrive|(hd|' | del_cr)/
    echo $prefix

    if is_efi; then
        info install grub for efi

        case "$basearch" in
        x86_64) grub_arch=x86_64 ;;
        aarch64) grub_arch=arm64 ;;
        esac

        if ! [ -d $grub_dir/grub/$grub_arch-efi ]; then
            alpine_ver=3.19
            download_and_extract_apk $alpine_ver grub-efi $tmp/grub-efi
            cp -r $tmp/grub-efi/usr/lib/grub/$grub_arch-efi/ $grub_dir
        fi

        grub_efi=$(get_grub_efi_filename)
        $grub-mkimage -p $prefix -O $grub_arch-efi -o "$(cygpath -w "$grub_dir/$grub_efi")" $grub_modules
        add_efi_entry_in_windows "$grub_dir/$grub_efi"
    else
        info install grub for bios

        if false; then
            is_in_china && host=mirror.nju.edu.cn || host=deb.debian.org
            curl -LO http://$host/debian/tools/win32-loader/oldstable/win32-loader.exe
            7z x win32-loader.exe 'g2ldr.mbr' -o$tmp/win32-loader -r -y -bso0
            find $tmp/win32-loader -name 'g2ldr.mbr' -exec cp {} /cygdrive/$c/ \;

            $grub-mkimage -p "$prefix" -O i386-pc -o "$(cygpath -w $grub_dir/core.img)" $grub_modules
            cat $grub_dir/i386-pc/lnxboot.img $grub_dir/core.img >/cygdrive/$c/g2ldr
        else
            $grub-install $c \
                --target=i386-pc \
                --boot-directory=$c: \
                --install-modules="$grub_modules" \
                --themes= \
                --fonts= \
                --no-bootsector

            cat $grub_dir/i386-pc/lnxboot.img /cygdrive/$c/grub/i386-pc/core.img >/cygdrive/$c/g2ldr
        fi

        id='{1c41f649-1637-52f1-aea8-f96bfebeecc8}'
        bcdedit /enum all | grep --text $id && bcdedit /delete $id
        bcdedit /create $id /d "$(get_entry_name)" /application bootsector
        bcdedit /set $id device partition=$c:
        bcdedit /set $id path \\g2ldr
        bcdedit /displayorder $id /addlast
        bcdedit /bootsequence $id /addfirst
    fi
}

find_grub_extlinux_cfg() {
    dir=$1
    filename=$2
    keyword=$3

    cfgs=$(
        find $dir \
            -type f -name $filename \
            -exec grep -E -l "$keyword" {} \;
    )

    count="$(wc -l <<<"$cfgs")"
    if [ "$count" -eq 1 ]; then
        echo "$cfgs"
    else
        error_and_exit "Find $count $filename."
    fi
}

is_need_quote() {
    [[ "$1" = *' '* ]] || [[ "$1" = *'&'* ]] || [[ "$1" = http* ]]
}

build_finalos_cmdline() {
    if vars=$(compgen -v finalos_); then
        for key in $vars; do
            value=${!key}
            key=${key#finalos_}
            if [ -n "$value" ] && [ $key != "mirrorlist" ]; then
                is_need_quote "$value" &&
                    finalos_cmdline+=" finalos_$key='$value'" ||
                    finalos_cmdline+=" finalos_$key=$value"
            fi
        done
    fi
}

build_extra_cmdline() {
    for key in confhome hold force_boot_mode force_cn force_old_windows_setup cloud_image main_disk \
        elts deb_mirror \
        ssh_port rdp_port web_port allow_ping; do
        value=${!key}
        if [ -n "$value" ]; then
            is_need_quote "$value" &&
                extra_cmdline+=" extra_$key='$value'" ||
                extra_cmdline+=" extra_$key=$value"
        fi
    done

    if [ -n "$finalos_mirrorlist" ]; then
        extra_cmdline+=" extra_mirrorlist='$finalos_mirrorlist'"
    elif [ -n "$nextos_mirrorlist" ]; then
        extra_cmdline+=" extra_mirrorlist='$nextos_mirrorlist'"
    fi

    if is_grub_dir_linked; then
        finalos_cmdline+=" extra_link_grub_dir=1"
    fi
}

echo_tmp_ttys() {
    if false; then
        curl -L $confhome/ttys.sh | sh -s "console="
    else
        case "$basearch" in
        x86_64) echo "console=ttyS0,115200n8 console=tty0" ;;
        aarch64) echo "console=ttyS0,115200n8 console=ttyAMA0,115200n8 console=tty0" ;;
        esac
    fi
}

get_entry_name() {
    printf 'reinstall ('
    printf '%s' "$distro"
    [ -n "$releasever" ] && printf ' %s' "$releasever"
    [ "$distro" = alpine ] && [ "$hold" = 1 ] && printf ' Live OS'
    printf ')'
}

# shellcheck disable=SC2154
build_nextos_cmdline() {
    if [ $nextos_distro = alpine ]; then
        nextos_cmdline="alpine_repo=$nextos_repo modloop=$nextos_modloop"
    elif is_distro_like_debian $nextos_distro; then
        nextos_cmdline="lowmem/low=1 auto=true priority=critical"
        nextos_cmdline+=" url=$nextos_ks"
        nextos_cmdline+=" mirror/http/hostname=${nextos_udeb_mirror%/*}"
        nextos_cmdline+=" mirror/http/directory=/${nextos_udeb_mirror##*/}"
        nextos_cmdline+=" base-installer/kernel/image=$nextos_kernel"
        if [ "$nextos_distro" = debian ] && is_debian_elts; then
            nextos_cmdline+=" apt-setup/services-select="
        fi
        if [ "$nextos_distro" = kali ]; then
            nextos_cmdline+=" net.ifnames=0"
            nextos_cmdline+=" simple-cdd/profiles=kali"
        fi
    elif is_distro_like_redhat $nextos_distro; then
        nextos_cmdline="root=live:$nextos_squashfs inst.ks=$nextos_ks"
    fi

    if is_distro_like_debian $nextos_distro; then
        if [ "$basearch" = "x86_64" ]; then
            :
        else
            nextos_cmdline+=" $(echo_tmp_ttys)"
        fi
    else
        nextos_cmdline+=" $(echo_tmp_ttys)"
    fi
}

build_cmdline() {
    build_nextos_cmdline

    if [ "$distro" = alpine ]; then
        finalos_distro=alpine
    fi
    if [ -n "$finalos_distro" ]; then
        build_finalos_cmdline
    fi

    build_extra_cmdline

    cmdline="$nextos_cmdline $finalos_cmdline $extra_cmdline"
}

mkdir_clear() {
    dir=$1

    if [ -z "$dir" ] || [ "$dir" = / ]; then
        return
    fi

    rm -rf "$dir"
    mkdir -p "$dir"
}

mod_initrd_debian_kali() {
    sed -Ei 's,&&( onlink=),||\1,' etc/udhcpc/default.script

    {
        echo 'if false && : \' | insert_into_file lib/debian-installer.d/S70menu before 'if [ -x "$bterm" ]' -F
        echo 'if true  || : \' | insert_into_file lib/debian-installer.d/S70menu before 'if [ -x "$screen_bin" -a' -F
    }

    netcfg() {
        #!/bin/sh
        # shellcheck source=/dev/null
        . /usr/share/debconf/confmodule
        db_progress START 0 5 debian-installer/netcfg/title

        : get_ip_conf_cmd

        db_progress INFO base-installer/progress/netcfg
        sh /trans.sh || exit
        db_progress STEP 1
        db_progress STOP
    }

    postinst=var/lib/dpkg/info/netcfg.postinst
    get_function_content netcfg >$postinst
    get_ip_conf_cmd | insert_into_file $postinst after ": get_ip_conf_cmd"

    change_priority() {
        while IFS= read -r line; do
            if [[ "$line" = Package:* ]]; then
                package=$(echo "$line" | cut -d' ' -f2-)

            elif [[ "$line" = Priority:* ]]; then
                # shellcheck disable=SC2154
                if [ "$line" = "Priority: standard" ]; then
                    for p in $disabled_list; do
                        if [ "$package" = "$p" ]; then
                            line="Priority: optional"
                            break
                        fi
                    done
                elif [[ "$package" = ata-modules* ]]; then
                    line="Priority: standard"
                fi
            fi
            echo "$line"
        done
    }

    # shellcheck disable=SC2012
    kver=$(ls -d lib/modules/* | awk -F/ '{print $NF}')

    net_retriever=usr/lib/debian-installer/retriever/net-retriever
    # shellcheck disable=SC2016
    sed -i 's,>> "$1",| change_priority >> "$1",' $net_retriever
    insert_into_file $net_retriever after '#!/bin/sh' <<EOF
disabled_list="
depthcharge-tools-installer
kickseed-common
nobootloader
partman-btrfs
partman-cros
partman-iscsi
partman-jfs
partman-md
partman-xfs
rescue-check
wpasupplicant-udeb
lilo-installer
systemd-boot-installer
nic-modules-$kver-di
nic-pcmcia-modules-$kver-di
nic-usb-modules-$kver-di
nic-wireless-modules-$kver-di
nic-shared-modules-$kver-di
pcmcia-modules-$kver-di
pcmcia-storage-modules-$kver-di
cdrom-core-modules-$kver-di
firewire-core-modules-$kver-di
usb-storage-modules-$kver-di
isofs-modules-$kver-di
jfs-modules-$kver-di
xfs-modules-$kver-di
loop-modules-$kver-di
pata-modules-$kver-di
sata-modules-$kver-di
scsi-modules-$kver-di
"

$(get_function change_priority)
EOF

    download_and_extract_deb() {
        local type=$1
        local package=$2
        local extract_dir=$3

        # shellcheck disable=SC2154
        case "$type" in
        deb)
            local mirror=$nextos_deb_mirror
            local url=http://$mirror/dists/$nextos_codename/main/binary-$basearch_alt/Packages.gz
            ;;
        udeb)
            local mirror=$nextos_udeb_mirror
            local url=http://$mirror/dists/$nextos_codename/main/debian-installer/binary-$basearch_alt/Packages.gz
            ;;
        esac

        deb_list=$tmp/${type}_list
        if ! [ -f $deb_list ]; then
            curl -L "$url" | zcat | grep 'Filename:' | awk '{print $2}' >$deb_list
        fi

        deb_path=$(grep -F "/${package}_" "$deb_list")
        curl -Lo $tmp/tmp.deb http://$mirror/"$deb_path"

        if false; then
            install_pkg dpkg
            dpkg -x $tmp/tmp.deb $extract_dir
        else
            install_pkg ar tar xz
            (cd $tmp && ar x $tmp/tmp.deb)
            tar xf $tmp/data.tar.xz -C $extract_dir
        fi
    }

    create_can_use_cloud_kernel_sh can_use_cloud_kernel.sh

    curl -LO "$confhome/fix-eth-name.sh"
    curl -LO "$confhome/fix-eth-name.service"

    curl -LO "$confhome/get-xda.sh"
    curl -LO "$confhome/ttys.sh"
    if [ -n "$frpc_config" ]; then
        curl -LO "$confhome/get-frpc-url.sh"
        curl -LO "$confhome/frpc.service"
    fi

    echo 'export DEBCONF_DROP_TRANSLATIONS=1' |
        insert_into_file lib/debian-installer/menu before 'exec debconf'

    if [ "$distro" = kali ]; then
        mkdir -p cdrom/simple-cdd
        curl -Lo cdrom/simple-cdd/kali.postinst https://gitlab.com/kalilinux/build-scripts/kali-live/-/raw/main/kali-config/common/includes.installer/kali-finish-install?ref_type=heads
        chmod a+x cdrom/simple-cdd/kali.postinst
    fi

    if [ "$distro" = debian ] && is_debian_elts; then
        curl -Lo usr/share/keyrings/debian-archive-keyring.gpg https://deb.freexian.com/extended-lts/archive-key.gpg
    fi

    mkdir_clear $tmp/sshd
    download_and_extract_deb udeb openssh-server-udeb $tmp/sshd
    cp -r $tmp/sshd/* .

    mkdir_clear $tmp/fdisk
    download_and_extract_deb udeb fdisk-udeb $tmp/fdisk
    cp -f $tmp/fdisk/usr/sbin/fdisk usr/sbin/

    if [ "$distro" = kali ] ||
        { [ "$distro" = debian ] && [ "$releasever" -ge 11 ]; }; then
        mkdir_clear $tmp/websocketd
        download_and_extract_deb deb websocketd $tmp/websocketd
        cp -f $tmp/websocketd/usr/bin/websocketd usr/bin/
    fi

    if [ $ram_size -gt 256 ] || is_in_windows; then
        sed -i '/^pata-modules/d' $net_retriever
        sed -i '/^sata-modules/d' $net_retriever
        sed -i '/^scsi-modules/d' $net_retriever
    else
        find_main_disk
        extra_drivers=
        for driver in $(get_disk_drivers $xda); do
            echo "using driver: $driver"
            case $driver in
            nvme) extra_drivers+=" nvme nvme-core" ;;
            xen_blkfront) extra_drivers+=" xen-blkfront" ;;
            xen_scsifront) extra_drivers+=" xen-scsifront" ;;
            virtio_blk | virtio_scsi | hv_storvsc | vmw_pvscsi) extra_drivers+=" $driver" ;;
            pata_legacy) sed -i '/^pata-modules/d' $net_retriever ;;
            ata_piix) sed -i '/^sata-modules/d' $net_retriever ;;
            ata_generic) ;;
            esac
        done

        if [ -n "$extra_drivers" ]; then
            mkdir_clear $tmp/scsi
            download_and_extract_deb udeb scsi-modules-$kver-di $tmp/scsi
            relative_drivers_dir=lib/modules/$kver/kernel/drivers

            udeb_drivers_dir=$tmp/scsi/$relative_drivers_dir
            dist_drivers_dir=$initrd_dir/$relative_drivers_dir
            (
                cd $udeb_drivers_dir
                for driver in $extra_drivers; do
                    if ! find $dist_drivers_dir -name "$driver.ko*" | grep -q .; then
                        echo "adding driver: $driver"
                        file=$(find . -name "$driver.ko*" | grep .)
                        cp -fv --parents "$file" "$dist_drivers_dir"
                    fi
                done
            )
        fi
    fi

    sed -i 's/use_level=[29]/use_level=1/' lib/debian-installer-startup.d/S15lowmem

    # shellcheck disable=SC2154
    insert_into_file $initrd_dir/trans.sh after '^: main' <<EOF
        distro=$nextos_distro
        releasever=$nextos_releasever
        create_ifupdown_config /etc/network/interfaces
        exit
EOF
    replace='\n: #'
    sed -Ei \
        -e "s/> >/$replace/" \
        -e "s/< </$replace/" \
        -e "s/\. <\(/$replace/" \
        -e "s/^[[:space:]]*apk[[:space:]]/$replace/" \
        -e "s/^[[:space:]]*trap[[:space:]]/$replace/" \
        -e "s/\\$\{.*\/\/.*\/.*\}/$replace/" \
        -e "/^[[:space:]]*set[[:space:]]/s/E//" \
        $initrd_dir/trans.sh
}

get_disk_drivers() {
    get_drivers "/sys/block/$1"
}

get_net_drivers() {
    get_drivers "/sys/class/net/$1"
}

get_drivers() {
    (
        cd "$(readlink -f $1)"
        while ! [ "$(pwd)" = / ]; do
            if [ -d driver ]; then
                if [ -d driver/module ]; then
                    basename "$(readlink -f driver/module)"
                else
                    basename "$(readlink -f driver)"
                fi
            fi
            cd ..
        done
    )
}

exit_if_cant_use_cloud_kernel() {
    find_main_disk
    collect_netconf

    # shellcheck disable=SC2154
    if ! can_use_cloud_kernel "$xda" $ipv4_ethx $ipv6_ethx; then
        error_and_exit "Can't use cloud kernel. And not enough RAM to run normal kernel."
    fi
}

can_use_cloud_kernel() {
    cloud_eth_modules='ena|gve|mana|virtio_net|xen_netfront|hv_netvsc|vmxnet3|mlx4_en|mlx4_core|mlx5_core|ixgbevf'
    cloud_blk_modules='ata_generic|ata_piix|pata_legacy|nvme|virtio_blk|virtio_scsi|xen_blkfront|xen_scsifront|hv_storvsc|vmw_pvscsi'

    drivers="$(get_disk_drivers $1)"
    shift
    for driver in $drivers; do
        echo "using disk driver: $driver"
    done
    echo "$drivers" | grep -Ewq "$cloud_blk_modules" || return 1

    if [ "$1" = "$2" ]; then
        shift
    fi
    while [ $# -gt 0 ]; do
        drivers="$(get_net_drivers $1)"
        shift
        for driver in $drivers; do
            echo "using net driver: $driver"
        done
        echo "$drivers" | grep -Ewq "$cloud_eth_modules" || return 1
    done
}

create_can_use_cloud_kernel_sh() {
    cat <<EOF >$1
        $(get_function get_drivers)
        $(get_function get_net_drivers)
        $(get_function get_disk_drivers)
        $(get_function can_use_cloud_kernel)

        can_use_cloud_kernel "\$@"
EOF
}

get_ip_conf_cmd() {
    collect_netconf >&2
    is_in_china && is_in_china=true || is_in_china=false

    sh=/initrd-network.sh
    if is_found_ipv4_netconf && is_found_ipv6_netconf && [ "$ipv4_mac" = "$ipv6_mac" ]; then
        echo "'$sh' '$ipv4_mac' '$ipv4_addr' '$ipv4_gateway' '$ipv6_addr' '$ipv6_gateway' '$is_in_china' '$ipv6_extra_addrs'"
    else
        if is_found_ipv4_netconf; then
            echo "'$sh' '$ipv4_mac' '$ipv4_addr' '$ipv4_gateway' '' '' '$is_in_china' ''"
        fi
        if is_found_ipv6_netconf; then
            echo "'$sh' '$ipv6_mac' '' '' '$ipv6_addr' '$ipv6_gateway' '$is_in_china' '$ipv6_extra_addrs'"
        fi
    fi
}

mod_initrd_alpine() {
    if virt_dir=$(ls -d $initrd_dir/lib/modules/*-virt 2>/dev/null); then
        ipv6_dir=$virt_dir/kernel/net/ipv6
        if ! [ -f $ipv6_dir/ipv6.ko ] && ! grep -q ipv6 $initrd_dir/lib/modules/*/modules.builtin; then
            mkdir -p $ipv6_dir
            modloop_file=$tmp/modloop_file
            modloop_dir=$tmp/modloop_dir
            curl -Lo $modloop_file $nextos_modloop
            if is_in_windows; then
                7z e $modloop_file ipv6.ko -r -y -o$ipv6_dir
            else
                install_pkg unsquashfs
                mkdir_clear $modloop_dir
                unsquashfs -f -d $modloop_dir $modloop_file 'modules/*/kernel/net/ipv6/ipv6.ko'
                find $modloop_dir -name ipv6.ko -exec cp {} $ipv6_dir/ \;
            fi
        fi
    fi

    # shellcheck disable=SC2154
    download_and_extract_apk "$nextos_releasever" dhcpcd "$initrd_dir"
    sed -i -e '/^slaac private/s/^/#/' -e '/^#slaac hwaddr/s/^#//' $initrd_dir/etc/dhcpcd.conf

    # shellcheck disable=SC2329
    udhcpc() {
        if [ "$1" = deconfig ]; then
            return
        fi
        if [ "$1" = bound ] && [ -n "$ipv6" ]; then
            # shellcheck disable=SC2154
            ip -6 addr add "$ipv6" dev "$interface"
            ip link set dev "$interface" up
            return
        fi
    }

    get_function_content udhcpc |
        insert_into_file usr/share/udhcpc/default.script after 'deconfig\|renew\|bound'

    sed -Ei 's,(0\.0\.0\.0\/0),"\1 onlink",' usr/share/udhcpc/default.script

    insert_into_file init after 'configure_ip\(\)' <<EOF
        depmod
        [ -d /sys/module/ipv6 ] || modprobe ipv6
        $(get_ip_conf_cmd)
        MAC_ADDRESS=1
        return
EOF

    insert_into_file init before '^exec switch_root' <<EOF
        # trans
        cp /trans.sh \$sysroot/etc/local.d/trans.start
        chmod a+x \$sysroot/etc/local.d/trans.start
        ln -s /etc/init.d/local \$sysroot/etc/runlevels/default/

        for dir in /configs /custom_drivers; do
            if [ -d \$dir ]; then
                cp -r \$dir \$sysroot/
                rm -rf \$dir
            fi
        done
EOF

    if is_distro_like_debian; then
        create_can_use_cloud_kernel_sh can_use_cloud_kernel.sh
        insert_into_file init before '^exec (/bin/busybox )?switch_root' <<EOF
        cp /can_use_cloud_kernel.sh \$sysroot/
        chmod a+x \$sysroot/can_use_cloud_kernel.sh
EOF
    fi
}

mod_initrd() {
    info "mod $nextos_distro initrd"
    install_pkg gzip cpio

    initrd_dir=$tmp/initrd
    mkdir_clear $initrd_dir
    cd $initrd_dir

    # shellcheck disable=SC2046
    zcat /reinstall-initrd | cpio -idm \
        $(is_in_windows && echo --nonmatching 'dev/console' --nonmatching 'dev/null')

    curl -Lo $initrd_dir/trans.sh $confhome/trans.sh
    if ! grep -iq "$SCRIPT_VERSION" $initrd_dir/trans.sh; then
        error_and_exit "
This script is outdated, please download reinstall.sh again.
脚本有更新，请重新下载 reinstall.sh"
    fi

    curl -Lo $initrd_dir/initrd-network.sh $confhome/initrd-network.sh
    chmod a+x $initrd_dir/trans.sh $initrd_dir/initrd-network.sh

    mkdir -p $initrd_dir/configs
    if [ -n "$ssh_keys" ]; then
        cat <<<"$ssh_keys" >$initrd_dir/configs/ssh_keys
    else
        save_password $initrd_dir/configs
    fi
    if [ -n "$frpc_config" ]; then
        cat "$frpc_config" >$initrd_dir/configs/frpc.conf
    fi

    if [ -n "$cloud_data" ]; then
        mkdir -p $initrd_dir/configs/cloud-data
        if [ -d "$cloud_data" ]; then
            cp "$cloud_data"/* $initrd_dir/configs/cloud-data/
        else
            for f in user-data meta-data network-config; do
                curl -fsSL "$cloud_data/$f" -o "$initrd_dir/configs/cloud-data/$f" 2>/dev/null || true
            done
        fi
        [ -f $initrd_dir/configs/cloud-data/user-data ] || error_and_exit "--cloud-data must contain user-data"
        cloud_data_files=$(ls $initrd_dir/configs/cloud-data/ | tr '\n' ' ')
    fi

    if is_distro_like_debian $nextos_distro; then
        mod_initrd_debian_kali
    else
        mod_initrd_$nextos_distro
    fi

    if [ "$distro" = windows ] && [ -n "$custom_infs" ]; then
        # shellcheck disable=SC1090
        . <(curl -L $confhome/windows-driver-utils.sh)
        echo "$custom_infs" | while read -r inf; do
            parse_inf_and_cp_driever "$inf" "$initrd_dir/custom_drivers" "$basearch_alt" true
        done
    fi

    if is_virt && ! is_alpine_live; then
        remove_useless_initrd_files
    fi

    if [ "$hold" = 0 ]; then
        info 'hold 0'
        read -r -p 'Press Enter to continue...'
    fi

    find . | cpio --quiet -o -H newc | gzip -1 >/reinstall-initrd
    cd - >/dev/null
}

remove_useless_initrd_files() {
    info "slim initrd"

    du -sh .

    rm -rf bin/brltty
    rm -rf etc/brltty
    rm -rf sbin/wpa_supplicant
    rm -rf usr/lib/libasound.so.*
    rm -rf usr/share/alsa
    (
        cd lib/modules/*/kernel/drivers/net/ethernet/
        for item in *; do
            case "$item" in
            amazon | google | mellanox | realtek | pensando) ;;
            intel)
                (
                    cd "$item"
                    for sub_item in *; do
                        case "$sub_item" in
                        e100* | lib* | *vf | idpf) ;;
                        *) rm -rf $sub_item ;;
                        esac
                    done
                )
                ;;
            *) rm -rf $item ;;
            esac
        done
    )
    (
        cd lib/modules/*/kernel
        for item in \
            net/mac80211 \
            net/wireless \
            net/bluetooth \
            drivers/hid \
            drivers/mmc \
            drivers/mtd \
            drivers/usb \
            drivers/ssb \
            drivers/mfd \
            drivers/bcma \
            drivers/pcmcia \
            drivers/parport \
            drivers/platform \
            drivers/staging \
            drivers/net/usb \
            drivers/net/bonding \
            drivers/net/wireless \
            drivers/input/rmi4 \
            drivers/input/keyboard \
            drivers/input/touchscreen \
            drivers/bus/mhi \
            drivers/char/pcmcia \
            drivers/misc/cardreader; do
            rm -rf $item
        done
    )

    du -sh .
}

get_unix_path() {
    if is_in_windows; then
        cygpath -u "$1"
    else
        printf '%s' "$1"
    fi
}

init_basearch() {
    if is_in_windows; then
        if false; then
            basearch=$(wmic ComputerSystem get SystemType | grep '=' | cut -d= -f2 | cut -d- -f1)
        elif true; then
            basearch=$(reg query "HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Environment" /v PROCESSOR_ARCHITECTURE |
                grep . | tail -1 | awk '{print $NF}')
        else
            basearch=$(cmd /c "if defined PROCESSOR_ARCHITEW6432 (echo %PROCESSOR_ARCHITEW6432%) else (echo %PROCESSOR_ARCHITECTURE%)")
        fi
    else
        basearch=$(uname -m)
    fi

    case "$(echo $basearch | to_lower)" in
    i?86 | x64 | x86* | amd64)
        basearch=x86_64
        basearch_alt=amd64
        ;;
    arm* | aarch64)
        basearch=aarch64
        basearch_alt=arm64
        ;;
    *) error_and_exit "Unsupported arch: $basearch" ;;
    esac
}

init_confhome() {
    if false && [[ "$confhome" = http*://raw.githubusercontent.com/* ]]; then
        repo=$(echo $confhome | cut -d/ -f4,5)
        branch=$(echo $confhome | cut -d/ -f6)
        if [ -z "$commit" ]; then
            commit=$(curl -L https://api.github.com/repos/$repo/git/refs/heads/$branch |
                grep '"sha"' | grep -Eo '[0-9a-f]{40}')
        fi
        # shellcheck disable=SC2001
        confhome=$(echo "$confhome" | sed "s/main$/$commit/")
    fi

    if is_in_china; then
        if [ -n "$confhome_cn" ]; then
            confhome=$confhome_cn
        elif [ -n "$github_proxy" ] && [[ "$confhome" = http*://raw.githubusercontent.com/* ]]; then
            confhome=${confhome/http:\/\//https:\/\/}
            confhome=${confhome/https:\/\/raw.githubusercontent.com/$github_proxy}
        fi
    fi
}

remove_exist_reinstall_efi_dir() {
    info "remove exist reinstall efi dir"

    local dir='' dirs=''
    if is_in_windows; then
        dirs=$(get_efi_dir_in_windows)
    else
        dirs=$(get_maybe_efi_dirs_in_linux)
    fi
    for dir in $dirs; do
        rm -f "$dir/reinstall-vmlinuz"
        rm -f "$dir/reinstall-initrd"
    done
    find $dirs -type f \
        \( -ipath '*/EFI/reinstall/grubx64.efi' \
        -o -ipath '*/EFI/reinstall/grubaa64.efi' \
        -o -ipath '*/EFI/reinstall/netboot.xyz.efi' \
        -o -ipath '*/EFI/reinstall/netboot.xyz-arm64.efi' \) |
        while IFS= read -r efi_file; do
            reinstall_dir=$(dirname "$efi_file")
            echo "removing $reinstall_dir"
            rm -rf "$reinstall_dir"
        done
}

init_bootloader_facts() {
    if is_in_windows; then
        if is_efi; then
            _grub_cfg=/cygdrive/$c/grub.cfg
        else
            _grub_cfg=/cygdrive/$c/grub/grub.cfg
        fi
        target_cfg=$_grub_cfg
    else
        if is_efi; then
            efi_dir=$(get_maybe_efi_dirs_in_linux | head -1)
            _grub_cfg=$efi_dir/EFI/reinstall/grub.cfg
            target_cfg=$_grub_cfg
        else
            if is_mbr_using_grub; then
                if is_have_cmd update-grub; then
                    _grub_cfg=$(grep -o '[^ ]*grub.cfg' "$(get_cmd_path update-grub)" | head -1)
                else
                    _grub_cfg=$(find_grub_extlinux_cfg '/boot/grub*' grub.cfg 'menuentry|blscfg')
                fi
                target_cfg=$(dirname $_grub_cfg)/custom.cfg

                if is_have_cmd grub2-mkconfig; then
                    grub=grub2
                elif is_have_cmd grub-mkconfig; then
                    grub=grub
                else
                    error_and_exit "grub not found"
                fi
            else
                _extlinux_cfg=$(find_grub_extlinux_cfg /boot extlinux.conf LINUX)
                target_cfg=$_extlinux_cfg
            fi
        fi
    fi
}

recreate_grub_or_extlinux_cfg() {
    if is_efi || is_in_windows; then
        return
    fi

    if is_mbr_using_grub; then
        info "recreate grub.cfg"

        if [ -x /nix/var/nix/profiles/system/bin/switch-to-configuration ]; then
            /nix/var/nix/profiles/system/bin/switch-to-configuration boot
            nixos_grub_home="$(dirname "$(readlink -f "$(get_cmd_path grub-mkconfig)")")/.."
            $nixos_grub_home/etc/grub.d/41_custom >>$target_cfg
        elif is_have_cmd update-grub; then
            update-grub
        else
            $grub-mkconfig -o $target_cfg
        fi
    elif is_have_cmd update-extlinux; then
        info "recreate extlinux.conf"
        update-extlinux
    else
        error_and_exit "unsupported bootloader."
    fi
}

remove_exist_reinstall() {
    info "remove exist reinstall"

    rm -f /reinstall-vmlinuz /reinstall-initrd
    rm -f /boot/reinstall-vmlinuz /boot/reinstall-initrd
    if is_in_windows; then
        rm -f /cygdrive/$c/reinstall-vmlinuz /cygdrive/$c/reinstall-initrd
    fi

    if ! is_use_local_grub_extlinux; then
        rm -f "$target_cfg"
    fi

    if is_in_windows; then
        if is_efi; then
            remove_exist_reinstall_efi_dir

            bcdedit /set '{fwbootmgr}' bootsequence '{bootmgr}'
            bcdedit /enum bootmgr | grep --text -B3 'reinstall' | awk '{print $2}' | grep '{.*}' |
                xargs -I {} cmd /c bcdedit /delete {}
        else
            id='{1c41f649-1637-52f1-aea8-f96bfebeecc8}'
            if bcdedit /enum all | grep --text "$id"; then
                bcdedit /delete "$id"
            fi
        fi
    else
        if is_efi; then
            remove_exist_reinstall_efi_dir

            install_pkg efibootmgr
            efibootmgr | grep -q 'BootNext:' && efibootmgr --quiet --delete-bootnext
            efibootmgr | grep_efi_entry | grep 'reinstall' | grep_efi_index |
                xargs -I {} efibootmgr --quiet --bootnum {} --delete-bootnum
        else
            if [ -f "$target_cfg" ]; then
                sed -i "/^$BOOT_ENTEY_START_MARK/,/^$BOOT_ENTEY_END_MARK/d" "$target_cfg"
            fi

            if is_use_local_grub; then
                $grub-editenv - unset next_entry
            elif is_use_local_extlinux; then
                extlinux --clear-once "$(dirname "$target_cfg")"
            fi

            recreate_grub_or_extlinux_cfg
        fi
    fi
}

reset_and_exit() {
    from_ctrl_c=${1:-false}

    if $from_ctrl_c; then
        info "Caught Ctrl+C, reseting..."
    fi

    remove_exist_reinstall
    rm -rf "$tmp"
    echo "reset done."

    if $from_ctrl_c; then
        exit 1
    else
        exit 0
    fi
}

# 脚本入口

if is_in_windows; then
    c=$(echo $SYSTEMDRIVE | cut -c1)

    sysnative=$(cygpath -u $WINDIR\\Sysnative)
    if [ -d $sysnative ]; then
        PATH=$PATH:$sysnative
    fi

    mode.com con cp select=437 >/dev/null

    for exe in $WINDOWS_EXES; do
        if get_function $exe >/dev/null 2>&1; then
            eval "_$(get_function $exe)"
        fi
        eval "$exe(){ $(get_function_content run_with_del_cr_template | sed "s/\$exe/$exe/g") }"
    done
fi

if is_in_windows; then
    if ! fltmc >/dev/null 2>&1; then
        error_and_exit "Please run as administrator."
    fi
else
    if [ "$EUID" -ne 0 ]; then
        error_and_exit "Please run as root."
    fi
fi

if mount | grep -q 'tmpfs on / type tmpfs'; then
    error_and_exit "Can't run this script in Live OS."
fi

if is_in_container; then
    error_and_exit "Not Supported OS in Container.\nPlease use https://github.com/LloydAsp/OsMutation"
fi

if is_secure_boot_enabled; then
    error_and_exit "Please disable secure boot first."
fi

long_opts=
for o in ci installer debug minimal allow-ping force-cn help \
    add-driver: \
    hold: sleep: \
    iso: \
    image-name: \
    boot-wim: \
    img: \
    cloud-data: \
    lang: \
    passwd: password: \
    ssh-port: \
    ssh-key: public-key: \
    rdp-port: \
    web-port: http-port: \
    allow-ping: \
    commit: \
    frpc-conf: frpc-config: \
    target-disk: \
    force-boot-mode: \
    force-old-windows-setup:; do
    [ -n "$long_opts" ] && long_opts+=,
    long_opts+=$o
done

if ! ORIGINAL_OPTS=$(getopt -n $0 -o "h,x" --long "$long_opts" -- "$@"); then
    exit 1
fi

eval set -- "$ORIGINAL_OPTS"
while true; do
    case "$1" in
    -x | --debug)
        set -x
        shift
        ;;
    --)
        shift
        verify_os_name "$@"
        break
        ;;
    *)
        shift
        ;;
    esac
done

mkdir_clear "$tmp"
init_basearch
init_confhome
init_bootloader_facts

if [ "$distro" = reset ]; then
    reset_and_exit
fi

install_pkg curl grep

eval set -- "$ORIGINAL_OPTS"
# shellcheck disable=SC2034
while true; do
    case "$1" in
    -x | --debug)
        shift
        ;;
    -h | --help)
        usage_and_exit
        ;;
    --commit)
        commit=$2
        shift 2
        ;;
    --ci)
        cloud_image=1
        unset installer
        shift
        ;;
    --installer)
        installer=1
        unset cloud_image
        shift
        ;;
    --minimal)
        minimal=1
        shift
        ;;
    --allow-ping)
        allow_ping=1
        shift
        ;;
    --force-cn)
        force_cn=1
        shift
        ;;
    --hold | --sleep)
        if ! { [ "$2" = 0 ] || [ "$2" = 1 ] || [ "$2" = 2 ]; }; then
            error_and_exit "Invalid $1 value: $2"
        fi
        hold=$2
        shift 2
        ;;
    --frpc-conf | --frpc-config)
        [ -n "$2" ] || error_and_exit "Need value for $1"

        case "$(to_lower <<<"$2")" in
        http://* | https://*)
            frpc_config_url=$2
            frpc_config=$tmp/frpc.conf
            if ! curl -L "$frpc_config_url" -o "$frpc_config"; then
                error_and_exit "Can't get frpc config from $frpc_config_url"
            fi
            ;;
        *)
            if ! { frpc_config=$(get_unix_path "$2") && [ -f "$frpc_config" ]; }; then
                error_and_exit "File not exists: $2"
            fi
            ;;
        esac

        frpc_config=$(readlink -f "$frpc_config")

        shift 2
        ;;
    --force-boot-mode)
        if ! { [ "$2" = bios ] || [ "$2" = efi ]; }; then
            error_and_exit "Invalid $1 value: $2"
        fi
        force_boot_mode=$2
        shift 2
        ;;
    --passwd | --password)
        [ -n "$2" ] || error_and_exit "Need value for $1"
        password=$2
        shift 2
        ;;
    --ssh-key | --public-key)
        ssh_key_error_and_exit() {
            error "$1"
            cat <<EOF
Available options:
  --ssh-key "ssh-rsa ..."
  --ssh-key "ssh-ed25519 ..."
  --ssh-key "ecdsa-sha2-nistp256/384/521 ..."
  --ssh-key github:your_username
  --ssh-key gitlab:your_username
  --ssh-key http://path/to/public_key
  --ssh-key https://path/to/public_key
  --ssh-key /path/to/public_key
  --ssh-key C:\path\to\public_key
EOF
            exit 1
        }

        is_valid_ssh_key() {
            grep -qE '^(ecdsa-sha2-nistp(256|384|521)|ssh-(ed25519|rsa)) ' <<<"$1"
        }

        [ -n "$2" ] || ssh_key_error_and_exit "Need value for $1"

        case "$(to_lower <<<"$2")" in
        github:* | gitlab:* | http://* | https://*)
            if [[ "$(to_lower <<<"$2")" = http* ]]; then
                key_url=$2
            else
                IFS=: read -r site user <<<"$2"
                [ -n "$user" ] || ssh_key_error_and_exit "Need a username for $site"
                key_url="https://$site.com/$user.keys"
            fi
            if ! ssh_key=$(curl -L "$key_url"); then
                error_and_exit "Can't get ssh key from $key_url"
            fi
            ;;
        *)
            if is_valid_ssh_key "$2"; then
                ssh_key=$2
            else
                if ! { ssh_key_file=$(get_unix_path "$2") && [ -f "$ssh_key_file" ]; }; then
                    ssh_key_error_and_exit "SSH Key/File/Url \"$2\" is invalid."
                fi
                ssh_key=$(<"$ssh_key_file")
            fi
            ;;
        esac

        if ! is_valid_ssh_key "$ssh_key"; then
            ssh_key_error_and_exit "SSH Key/File/Url \"$2\" is invalid."
        fi

        if [ -n "$ssh_keys" ]; then
            ssh_keys+=$'\n'
        fi
        ssh_keys+=$ssh_key

        shift 2
        ;;
    --ssh-port)
        is_port_valid $2 || error_and_exit "Invalid $1 value: $2"
        ssh_port=$2
        shift 2
        ;;
    --rdp-port)
        is_port_valid $2 || error_and_exit "Invalid $1 value: $2"
        rdp_port=$2
        shift 2
        ;;
    --web-port | --http-port)
        is_port_valid $2 || error_and_exit "Invalid $1 value: $2"
        web_port=$2
        shift 2
        ;;
    --add-driver)
        [ -n "$2" ] || error_and_exit "Need value for $1"

        inf_or_dir=$(get_unix_path "$2")

        if ! [ -d "$inf_or_dir" ] &&
            ! { [ -f "$inf_or_dir" ] && [[ "$inf_or_dir" =~ \.[iI][nN][fF]$ ]]; }; then
            error_and_exit "Not a inf or dir: $2"
        fi

        inf_or_dir=$(readlink -f "$inf_or_dir")

        info "finding inf in $inf_or_dir"
        if infs=$(find "$inf_or_dir" -type f -iname '*.inf' | grep .); then
            while IFS= read -r inf; do
                if ! grep -Fqx "$inf" <<<"$custom_infs"; then
                    echo "inf found: $inf"
                    if [ -n "$custom_infs" ]; then
                        custom_infs+=$'\n'
                    fi
                    custom_infs+=$inf
                fi
            done <<<"$infs"
        else
            error_and_exit "Can't find inf files in $2"
        fi

        shift 2
        ;;
    --force-old-windows-setup)
        force_old_windows_setup=$2
        shift 2
        ;;
    --target-disk)
        xda=${2##*/dev/}
        if ! [ -b "/dev/$xda" ]; then
            error_and_exit "Can't not find Disk $2."
        fi
        shift 2
        ;;
    --img)
        img=$2
        shift 2
        ;;
    --cloud-data)
        cloud_data=$2
        shift 2
        ;;
    --iso)
        iso=$2
        shift 2
        ;;
    --boot-wim)
        boot_wim=$2
        shift 2
        ;;
    --image-name)
        image_name=$(echo "$2" | to_lower)
        shift 2
        ;;
    --lang)
        lang=$(echo "$2" | to_lower)
        shift 2
        ;;
    --)
        shift
        break
        ;;
    *)
        echo "Unexpected option: $1."
        usage_and_exit
        ;;
    esac
done

verify_os_args

# ── 预置默认值 ──────────────────────────────────────────────────────────────
# 默认密码（用户未通过 --password 指定时生效）
if [ "$distro" = windows ] && [ -z "$password" ] && [ -z "$ssh_keys" ]; then
    password='Youhong@888'
    echo "Using default password: $password"
fi

# 默认语言（Windows 安装时若未指定 --lang 则使用 zh-cn）
if [ "$distro" = windows ] && [ -z "$lang" ]; then
    lang='zh-cn'
fi

# 默认关闭 NLA（网络级别身份验证），解决 CredSSP 报错
# 通过写入注册表实现，安装完成后永久生效，无需 VNC 手动操作
if [ "$distro" = windows ]; then
    # 将关闭 NLA 的注册表命令注入到应答文件的 FirstLogonCommands 中
    # trans.sh 在安装完成后会读取 configs/windows-post-install.ps1 并执行
    mkdir -p "$tmp/win-post"
    cat > "$tmp/win-post/disable-nla.ps1" <<'PSEOF'
# 关闭网络级别身份验证（NLA），解决 CredSSP 身份验证错误
Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp' -Name 'UserAuthentication' -Value 0
Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp' -Name 'SecurityLayer' -Value 0
# 确保远程桌面服务已启用
Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server' -Name 'fDenyTSConnections' -Value 0
PSEOF
fi
# ────────────────────────────────────────────────────────────────────────────

if ! is_netboot_xyz && [ -z "$ssh_keys" ] && [ -z "$password" ]; then
    if is_use_dd; then
        show_dd_password_tips
    fi
    prompt_password
fi

case "$distro" in
dd | windows | netboot.xyz | kali | alpine | arch | gentoo | aosc | nixos | fnos)
    if is_use_cloud_image; then
        echo "ignored --ci"
        unset cloud_image
    fi
    ;;
oracle | opensuse | anolis | opencloudos | openeuler)
    cloud_image=1
    ;;
redhat | centos | almalinux | rocky | fedora | ubuntu)
    if is_force_use_installer; then
        unset cloud_image
    else
        cloud_image=1
    fi
    ;;
esac

check_ram

if is_netboot_xyz ||
    { ! is_use_cloud_image && {
        [ "$distro" = "alpine" ] || is_distro_like_debian ||
            { is_distro_like_redhat && [ $releasever -eq 7 ] && [ $ram_size -ge 1024 ] && [ $basearch = "x86_64" ]; } ||
            { is_distro_like_redhat && [ $releasever -eq 7 ] && [ $ram_size -ge 1536 ] && [ $basearch = "aarch64" ]; } ||
            { is_distro_like_redhat && [ $releasever -ge 8 ] && [ $ram_size -ge 2048 ]; }
    }; }; then
    setos nextos $distro $releasever
else
    alpine_ver_for_trans=$(get_latest_distro_releasever alpine)
    setos finalos $distro $releasever
    setos nextos alpine $alpine_ver_for_trans
fi

if [ -f /etc/default/kexec ]; then
    sed -i 's/LOAD_KEXEC=true/LOAD_KEXEC=false/' /etc/default/kexec
fi

remove_exist_reinstall

if is_netboot_xyz; then
    if is_efi; then
        if is_in_windows; then
            add_efi_entry_in_windows $nextos_efi
        else
            add_efi_entry_in_linux $nextos_efi
        fi
    else
        curl -Lo /reinstall-vmlinuz $nextos_vmlinuz
    fi
else
    info download vmlnuz and initrd
    curl -Lo /reinstall-vmlinuz $nextos_vmlinuz
    curl -Lo /reinstall-initrd $nextos_initrd
    if is_use_firmware; then
        curl -Lo /reinstall-firmware $nextos_firmware
    fi
fi

if [ "$nextos_distro" = alpine ] || is_distro_like_debian "$nextos_distro"; then
    mod_initrd
fi

if is_need_boot_vmlinuz; then
    if is_in_windows; then
        install_grub_win
    else
        if is_efi; then
            install_grub_linux_efi
        fi
    fi

    if is_in_windows; then
        dir=$(cygpath -m / | cut -d: -f2-)/
    else
        if is_use_local_extlinux && is_boot_in_separate_partition; then
            dir=
        else
            if is_os_in_btrfs; then
                dir=$(btrfs subvolume show / | head -1)
                if ! [ "$dir" = / ]; then
                    dir="/$dir/"
                fi
            else
                dir=/
            fi
        fi
    fi

    vmlinuz=${dir}reinstall-vmlinuz
    initrd=${dir}reinstall-initrd
    firmware=${dir}reinstall-firmware

    if is_use_local_extlinux; then
        linux_cmd=LINUX
        initrd_cmd=INITRD
    else
        if is_netboot_xyz; then
            linux_cmd=linux16
            initrd_cmd=initrd16
        else
            linux_cmd=linux
            initrd_cmd=initrd
        fi
    fi

    if ! is_netboot_xyz; then
        find_main_disk
        build_cmdline

        initrds="$initrd"
        if is_use_firmware; then
            initrds+=" $firmware"
        fi
    fi

    if is_use_local_extlinux; then
        info extlinux
        echo "$target_cfg"
        extlinux_dir="$(dirname "$target_cfg")"

        sed -i "/^MENU HIDDEN/d" "$target_cfg"
        sed -i "/^TIMEOUT /d" "$target_cfg"

        del_empty_lines <<EOF | tee -a "$target_cfg"
$BOOT_ENTEY_START_MARK
TIMEOUT 5
LABEL reinstall
  MENU LABEL $(get_entry_name)
  $linux_cmd $vmlinuz
  $([ -n "$initrds" ] && echo "$initrd_cmd $initrds")
  $([ -n "$cmdline" ] && echo "APPEND $cmdline")
$BOOT_ENTEY_END_MARK
EOF
        extlinux --once=reinstall $extlinux_dir

        if is_boot_in_separate_partition; then
            info "copying files to $extlinux_dir"
            is_have_initrd && cp -f /reinstall-initrd $extlinux_dir
            is_use_firmware && cp -f /reinstall-firmware $extlinux_dir
            cp -f /reinstall-vmlinuz $extlinux_dir
        fi
    else
        load_grubenv_if_not_loaded() {
            if ! [ -s $prefix/grubenv ]; then
                for dir in /boot/grub /boot/grub2 /grub /grub2; do
                    set grubenv="($root)$dir/grubenv"
                    if [ -s $grubenv ]; then
                        load_env --file $grubenv
                        if [ "${next_entry}" ]; then
                            set default="${next_entry}"
                            set next_entry=
                            save_env --file $grubenv next_entry
                        else
                            set default="0"
                        fi
                        return
                    fi
                done
            fi
        }

        info grub
        echo $target_cfg

        echo '### BEGIN reinstall.sh ###' >$target_cfg

        get_function_content load_grubenv_if_not_loaded >>$target_cfg

        del_empty_lines <<EOF | del_comment_lines | tee -a $target_cfg
set timeout_style=menu
set timeout=5
menuentry "$(get_entry_name)" --unrestricted {
    $(! is_in_windows && echo 'insmod lvm')
    $(is_os_in_btrfs && echo 'set btrfs_relative_path=n')
    insmod all_video
    search --no-floppy --file --set=root $vmlinuz
    $linux_cmd $vmlinuz $cmdline
    $([ -n "$initrds" ] && echo "$initrd_cmd $initrds")
}
EOF
        echo '### END reinstall.sh ###' >>$target_cfg

        if is_use_local_grub; then
            $grub-reboot "$(get_entry_name)"
        fi
    fi
fi

info 'info'
echo "$distro $releasever"

case "$distro" in
windows) username=administrator ;;
netboot.xyz) username= ;;
dd | *) username=root ;;
esac

if [ -n "$username" ]; then
    echo "用户名: $username"
    if [ -n "$ssh_keys" ]; then
        echo "公钥: $ssh_keys"
    else
        echo "密码: $password"
    fi
fi

if is_netboot_xyz; then
    echo '重启后进入 netboot.xyz。'
elif is_alpine_live; then
    echo '重启后进入 Alpine Live OS。'
elif is_use_dd; then
    if [ -n "$cloud_data" ]; then
        echo "Cloud Data: $cloud_data"
        echo "Cloud Data Files: $cloud_data_files"
    fi
    show_dd_password_tips
    echo '重启后开始 DD。'
elif [ "$distro" = fnos ]; then
    echo "飞牛 OS 注意事项："
    echo "重启后开始安装。"
    echo "安装完成后不支持 SSH 登录。"
    echo "你需要尽快在 http://SERVER_IP:5666 配置账号密码。"
else
    echo "重启后开始安装。"
fi

if is_in_windows; then
    echo '可以运行以下命令重启:'
    echo 'shutdown /r /t 0'
fi

echo
echo "如需撤销本脚本的所有更改，请运行 \"$reinstall_____ reset\""
echo
