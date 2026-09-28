#!/bin/bash
set -euxo pipefail

if [ ! -f /swapfile ]; then
  fallocate -l 2G /swapfile
  chmod 600 /swapfile
  mkswap /swapfile
  swapon /swapfile
  echo '/swapfile none swap sw 0 0' >> /etc/fstab
  echo 'vm.swappiness=10' > /etc/sysctl.d/99-swappiness.conf
  sysctl -p /etc/sysctl.d/99-swappiness.conf
fi

export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y curl git jq unzip htop

hostnamectl set-hostname gitops-k3s
touch /var/log/user-data-done
