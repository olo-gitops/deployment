#!/bin/bash

set -eux

function part_one()
{
	echo "fixing locale"
	truncate -s 0 /etc/default/locale
	locale-gen -a
	echo ': "${LANG:=en_US.utf8}"; export LANG' >> /etc/profile

	echo "limiting journald logging to 1 day"
	echo "MaxRetentionSec=86400" >> /etc/systemd/journald.conf

	echo "enabling serial console"
	sed -i \
		-e '/^GRUB_CMDLINE_LINUX=.*/c\GRUB_CMDLINE_LINUX="console=tty0 console=ttyS0,115200n8"' \
		-e '/^#GRUB_DISABLE_OS_PROBER=.*/c\GRUB_DISABLE_OS_PROBER="true"' \
		-e '/^#GRUB_DISABLE_RECOVERY=.*/c\GRUB_DISABLE_RECOVERY="true"' \
		-e '/^#GRUB_TERMINAL=.*/c\GRUB_TERMINAL=console' /etc/default/grub
	systemctl enable --now serial-getty@ttyS0.service

	echo "installing cloud kernel"
	apt install -y linux-image-cloud-amd64 && reboot
}

function part_two()
{
	echo "removing unneeded packages"
	apt purge -y \
		'?and(?name(linux-image), ~i, ?not(?name(cloud)))' \
		bash-completion \
		eject \
		emacsen-common \
		dhcpcd-base \
		groff-base \
		krb5-locales \
		laptop-detect \
		installation-report \
		manpages \
		nano \
		os-prober \
		reportbug \
		tasksel \
		wamerican \
		xauth

	apt autoremove -y

	echo "installing required packages"
	apt install \
		--no-install-suggests --no-install-recommends -y \
		chrony \
		curl \
		git \
		qemu-guest-agent \
		vim-nox \
		zsh

	echo "fetching grml zsh config"
	wget -O "${HOME}/.zshrc" "https://grml.org/console/zshrc"
	wget -O "${HOME}/.zshrc.local" "https://grml.org/console/zshrc.local"
	chsh -s /bin/zsh

	echo "setting hostname"
	sed -i '/127\.0\.1\.1/d' /etc/hosts
	echo "$(hostname --all-ip-addresses | head -n1)	control-01.k8s.home.lrnz.at	control-01" >> /etc/hosts
}

function part_three()
{
	wget -O "/tmp/k3s" "https://github.com/k3s-io/k3s/releases/latest/download/k3s"

	#
	kube-vip manifest daemonset \
    --bgp \
    --controlplane \
    --address $VIP \
    --interface $INTERFACE \
    --inCluster \
    --taint \
    --bgpRouterID 192.168.50.33 \
    --localAS 65000 \
    --peerAddress 192.168.50.1 \
    --peerAS 65000 > /var/lib/rancher/k3s/server/manifests/kube-vip-ds.yaml
	#
	#local MANIFEST_DIR='/var/lib/rancher/k3s/server/manifests'
	#mkdir -p "$MANIFEST_DIR"
	#wget -O "${MANIFEST_DIR}/kube-vip-rbac.yaml" "https://kube-vip.io/manifests/rbac.yaml"
	https://get.helm.sh/helm-v3.19.0-linux-amd64.tar.gz
	kubectl kustomize --enable-helm ~/deployment/cluster/cilium | kubectl apply --server-side=true -f -
}

function main()
{
	if [[ $(uname -r) != *cloud* ]]; then
		part_one
		exit 0
	fi

	#part_two
	part_three
}

function cilium_cli()
{
	CILIUM_CLI_VERSION=$(curl -s https://raw.githubusercontent.com/cilium/cilium-cli/main/stable.txt)
	CLI_ARCH=amd64
	if [ "$(uname -m)" = "aarch64" ]; then CLI_ARCH=arm64; fi
	curl -L --fail --remote-name-all https://github.com/cilium/cilium-cli/releases/download/${CILIUM_CLI_VERSION}/cilium-linux-${CLI_ARCH}.tar.gz{,.sha256sum}
	sha256sum --check cilium-linux-${CLI_ARCH}.tar.gz.sha256sum
	tar xzvfC cilium-linux-${CLI_ARCH}.tar.gz /usr/local/bin
	rm cilium-linux-${CLI_ARCH}.tar.gz{,.sha256sum}
}

function cilium_install()
{
	cilium install \
		--version 1.18.3 \
		--set=bpf.masquerade=true \
		--set=ipam.operator.clusterPoolIPv4PodCIDRList="10.16.0.0/12" \
		--set=operator.replicas=1 \
		--set=k8s.apiServerURLs='https://control.k8s.home.lrnz.at:6443 https://control-01.k8s.home.lrnz.at:6443' \
		--set=kubeProxyReplacement=true \
		--set=rollOutCiliumPods=true
}

function k3s_install()
{
	local CONFIG_DIR="/etc/rancher/k3s"

	mkdir -p "$CONFIG_DIR"
	cp "resources/k3s-config.yaml" "${CONFIG_DIR}/config.yaml"
	curl -sfL https://get.k3s.io | sh -s - server
}

function sealed_secrets_install()
{
	kubectl apply -f "resources/ss-bootstrap-secret.yaml"
	kubectl apply -f https://github.com/bitnami-labs/sealed-secrets/releases/download/v0.32.2/controller.yaml
}

#main
#cilium_cli
k3s_install
sleep 300
cilium_install
cilium status --wait
sealed_secrets_install
