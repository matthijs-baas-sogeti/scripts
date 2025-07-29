#!/bin/bash
set -euo pipefail

# SWAP
# immediately disable swap
swapoff -a
# add # infront of lines with 'swap' in them,  make backup fstab.bak
sudo sed -i.bak '/\bswap\b/ s/^/#/' /etc/fstab

# Change hostname to controlplane as expected by kubeadm
sudo hostnamectl set-hostname controlplane && \
sudo sed -i -e '/^127\.0\.0\.1/s/.*/127.0.0.1 controlplane controlplane.localdomain controlplane4 controlplane4.localdomain4/' \
            -e '/^::1/s/.*/::1 controlplane controlplane.localdomain controlplane6 controlplane6.localdomain6/' /etc/hosts && \
hostnamectl

# Allow firewalld to pass traffic
sudo firewall-cmd --permanent --add-port={6443,2379,2380,10250,10251,10252,10257,10259,179}/tcp
sudo firewall-cmd --permanent --add-port=4789/udp
sudo firewall-cmd --reload

# allow on worker nodes
# sudo firewall-cmd --permanent --add-port={179,10250,30000-32767}/tcp
# sudo firewall-cmd --permanent --add-port=4789/udp
# sudo firewall-cmd --reload

sudo firewall-cmd --permanent --add-rich-rule='rule family=ipv4 source address=10.244.0.0/16 protocol value=udp accept'
sudo firewall-cmd --permanent --add-rich-rule='rule family=ipv4 source address=10.96.0.0/12 protocol value=udp accept'
sudo firewall-cmd --reload

# SELinux
# Set SELinux in permissive mode (effectively disabling it)
sudo setenforce 0
sudo sed -i --follow-symlinks 's/SELINUX=enforcing/SELINUX=permissive/g' /etc/sysconfig/selinux

# This sets some variables needed to ensure network traffic goes well
echo -e "overlay\nbr_netfilter" | sudo tee /etc/modules-load.d/k8s.conf
sudo modprobe overlay
sudo modprobe br_netfilter

# sysctl params required by setup, params persist across reboots
cat <<EOF | sudo tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF

echo "Change net.ipv4.conf.defaul and all.rp_filter to 2"
sudo tee -a /etc/sysctl.d/99-calico.conf <<EOF
net.ipv4.conf.default.rp_filter=2
net.ipv4.conf.all.rp_filter=2
EOF

# Apply sysctl params without reboot
sudo sysctl --system

# Install Cri-o container runtime and K8s
KUBERNETES_VERSION=v1.33
CRIO_VERSION=v1.33

# K8s repo
cat <<EOF | tee /etc/yum.repos.d/kubernetes.repo
[kubernetes]
name=Kubernetes
baseurl=https://pkgs.k8s.io/core:/stable:/$KUBERNETES_VERSION/rpm/
enabled=1
gpgcheck=1
gpgkey=https://pkgs.k8s.io/core:/stable:/$KUBERNETES_VERSION/rpm/repodata/repomd.xml.key
exclude=kubelet kubeadm kubectl cri-tools kubernetes-cni
EOF

# Cri-o repo
cat <<EOF | tee /etc/yum.repos.d/cri-o.repo
[cri-o]
name=CRI-O
baseurl=https://download.opensuse.org/repositories/isv:/cri-o:/stable:/$CRIO_VERSION/rpm/
enabled=1
gpgcheck=1
gpgkey=https://download.opensuse.org/repositories/isv:/cri-o:/stable:/$CRIO_VERSION/rpm/repodata/repomd.xml.key
EOF

# Install packages from official repositories
dnf install -y container-selinux
dnf install -y cri-o kubelet kubeadm kubectl --disableexcludes=kubernetes

# set node ip based on what it can find in the bridge link in this case br-lan
KUBELET_EXTRA_ARGS=10.10.20.10

# make sure crio uses cgroup_manager systemd as the kubeadm also uses it
echo -e '[crio.runtime]\ncgroup_manager = "systemd"' | sudo tee /etc/crio/crio.conf.d/99-cgroup.conf

# Start CRI-O
sudo systemctl restart crio.service
sudo systemctl enable crio.service

# and enable kubelet
systemctl enable --now kubelet

# Write kubeadm configuration to file
cat <<EOF > "kubeadm.config"
apiVersion: kubeadm.k8s.io/v1beta4
kind: InitConfiguration
localAPIEndpoint:
  advertiseAddress: "10.10.20.10"
  bindPort: 6443
nodeRegistration:
  name: "controlplane"
  kubeletExtraArgs:
    - name: "node-ip"
      value: "10.10.20.10"
---
apiVersion: kubeadm.k8s.io/v1beta4
kind: ClusterConfiguration
kubernetesVersion: "v1.33.0"
controlPlaneEndpoint: "10.10.20.10:6443"
apiServer:
  extraArgs:
    - name: "enable-admission-plugins"
      value: "NodeRestriction"
    - name: "audit-log-path"
      value: "/var/log/kubernetes/audit.log"
  extraVolumes:
    - name: "audit-log"
      hostPath: "/var/log/kubernetes"
      mountPath: "/var/log/kubernetes"
      pathType: DirectoryOrCreate
controllerManager:
  extraArgs:
    - name: "node-cidr-mask-size"
      value: "24"
scheduler:
  extraArgs:
    - name: "leader-elect"
      value: "true"
networking:
  podSubnet: "10.244.0.0/16"
  serviceSubnet: "10.96.0.0/12"
  dnsDomain: "cluster.local"
---
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
cgroupDriver: "systemd"
syncFrequency: "1m"
clusterDNS:
- "10.96.0.10"
clusterDomain: "cluster.local"
---
apiVersion: kubeproxy.config.k8s.io/v1alpha1
kind: KubeProxyConfiguration
mode: "ipvs"
conntrack:
  maxPerCore: 32768
  min: 131072
  tcpCloseWaitTimeout: "1h"
  tcpEstablishedTimeout: "24h"
EOF

echo "kubeadm configuration written to kubeadm.config"

kubeadm init --config=kubeadm.config

mkdir -p $HOME/.kube
sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config

# Add aliases to .bashrc
echo -e "\nalias k='kubectl'\nexport y='--dry-run=client -o yaml'" >> ~/.bashrc
BASHRCSOURCED=1
source ~/.bashrc

# Run a health check
kubectl get --raw='/readyz?verbose'
kubectl cluster-info 

# (Optional) untaint controlplane so pods can be deployed
kubectl taint nodes --all node-role.kubernetes.io/control-plane-

# Install Tigera operator for monitoring lifecycle of Calico CNI which is responsible for networking in kubernetes
# Find latest versions here https://docs.tigera.io/calico/latest/getting-started/kubernetes/self-managed-onprem/onpremises
# it will also download a Custom Resource Definition
kubectl create -f https://raw.githubusercontent.com/projectcalico/calico/v3.30.2/manifests/operator-crds.yaml
kubectl create -f https://raw.githubusercontent.com/projectcalico/calico/v3.30.2/manifests/tigera-operator.yaml
# download custom resources needed to configure Calico
curl https://raw.githubusercontent.com/projectcalico/calico/v3.30.2/manifests/custom-resources.yaml -O

echo "Editing YAML to change podNetwork, add bgp and interface for calico and use Nftables instead of IPTables"

sed -i '/^kind: Installation/,/^---/ {
  # Insert lines after calicoNetwork:
  /^  calicoNetwork:/a\
    nodeAddressAutodetectionV4:\
      interface: br-lan\
    bgp: Enabled\
    linuxDataplane: Nftables

  # Replace cidr value under ipPools
  s/\(cidr: \)192\.168\.0\.0\/16/\110.244.0.0\/16/
}' custom-resources.yaml

# Customize the Calico Install YAML called custom-resources.yaml
kubectl create -f custom-resources.yaml

# watch if pods go up
kubectl get po -A -w
