#!/bin/bash
# Ubuntu 18.04.6 上为 PetaLinux 2020.2 做准备
# 用法：在 VM 里把本脚本存成 setup.sh，然后  bash setup.sh
# 注意：bionic 已 EOL，官方源已下架，第一步必须先把 apt 源指到 old-releases。
set -e

echo "==> [1/6] 把 apt 源切到 old-releases.ubuntu.com"
sudo cp /etc/apt/sources.list /etc/apt/sources.list.bak
sudo tee /etc/apt/sources.list > /dev/null <<'EOF'
deb http://old-releases.ubuntu.com/ubuntu/ bionic main restricted universe multiverse
deb http://old-releases.ubuntu.com/ubuntu/ bionic-updates main restricted universe multiverse
deb http://old-releases.ubuntu.com/ubuntu/ bionic-backports main restricted universe multiverse
deb http://old-releases.ubuntu.com/ubuntu/ bionic-security main restricted universe multiverse
EOF

echo "==> [2/6] 允许 i386 架构（PetaLinux 32 位工具链依赖）"
sudo dpkg --add-architecture i386

echo "==> [3/6] 更新索引"
sudo apt-get update

echo "==> [4/6] 安装 UG1144 依赖"
sudo apt-get install -y \
  build-essential gcc g++ make autoconf automake libtool \
  gcc-multilib libc6-dev-i386 \
  git git-core curl wget rsync unzip zip cpio tar gzip bzip2 xz-utils \
  python3 python3-pip python3-dev python2.7 python \
  zlib1g zlib1g-dev zlib1g:i386 libssl-dev libssl1.0.0 \
  libncurses5 libncurses5-dev libncursesw5-dev \
  libsdl1.2-dev libglib2.0-dev libgtk2.0-0 \
  bison flex gawk texinfo diffstat chrpath socat pax \
  xvfb xterm screen tofrodos iproute2 net-tools tftpd tftp-hpa \
  device-tree-compiler bc \
  libstdc++6:i386 libselinux1 gnupg

echo "==> [5/6] dash 换成 bash（PetaLinux 脚本要用 bash）"
echo "dash dash/sh boolean false" | sudo debconf-set-selections
sudo dpkg-reconfigure -f noninteractive dash
sudo ln -sf /bin/bash /bin/sh

echo "==> [6/6] 校验"
echo "--- sh -> $(readlink -f /bin/sh)"
echo "--- gcc: $(gcc --version | head -1)"
echo "--- python3: $(python3 --version)"
echo "--- 32bit zlib: $(dpkg -l zlib1g:i386 | tail -1 | awk '{print $3}')"
echo
echo "现在可以装 PetaLinux 2020.2 了："
echo "  mkdir -p ~/petalinux"
echo "  ./petalinux-v2020.2-final-installer.run -d ~/petalinux"
echo
echo "提示：安装脚本用 /bin/sh，装之前先 source 环境："
echo "  source ~/petalinux/settings.sh"
