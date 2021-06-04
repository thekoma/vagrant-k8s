#!/bin/bash

set -x 
export OS=CentOS_7
export VERSION=1.21
export NETWORK=flannel
export PODNETWORK=100.64.0.0/16
export PATH="$PATH:/usr/local/bin"

# ####################

setenforce 0
sed -i 's/^SELINUX=enforcing$/SELINUX=permissive/' /etc/selinux/config
sed -i '/^\/swapfile/d' /etc/fstab
swapoff -a

# Create the .conf file to load the modules at bootup
cat <<EOF | tee /etc/modules-load.d/crio.conf
overlay
br_netfilter
EOF

modprobe overlay
modprobe br_netfilter

# Set up required sysctl params, these persist across reboots.
cat <<EOF | tee /etc/sysctl.d/99-kubernetes-cri.conf
net.bridge.bridge-nf-call-iptables  = 1
net.ipv4.ip_forward                 = 1
net.bridge.bridge-nf-call-ip6tables = 1
EOF

sysctl --system

curl -s -L -o /etc/yum.repos.d/devel:kubic:libcontainers:stable.repo https://download.opensuse.org/repositories/devel:/kubic:/libcontainers:/stable/$OS/devel:kubic:libcontainers:stable.repo
curl -s -L -o /etc/yum.repos.d/devel:kubic:libcontainers:stable:cri-o:$VERSION.repo https://download.opensuse.org/repositories/devel:kubic:libcontainers:stable:cri-o:$VERSION/$OS/devel:kubic:libcontainers:stable:cri-o:$VERSION.repo

cat <<EOF | tee /etc/yum.repos.d/kubernetes.repo
[kubernetes]
name=Kubernetes
baseurl=https://packages.cloud.google.com/yum/repos/kubernetes-el7-\$basearch
enabled=1
gpgcheck=1
repo_gpgcheck=1
gpgkey=https://packages.cloud.google.com/yum/doc/yum-key.gpg https://packages.cloud.google.com/yum/doc/rpm-package-key.gpg
exclude=kubelet kubeadm kubectl
EOF

yum install -y epel-release
yum install --disableexcludes=kubernetes -y kubelet kubeadm kubectl cri-o htop ncdu vim git tmux zsh wget

curl -fsSL -o get_helm.sh https://raw.githubusercontent.com/helm/helm/master/scripts/get-helm-3
chmod 700 get_helm.sh
./get_helm.sh


systemctl daemon-reload
systemctl enable crio --now
systemctl enable --now kubelet

kubeadm init --pod-network-cidr=$PODNETWORK| tee ~vagrant/init.log

mkdir -p ~vagrant/.kube
cp /etc/kubernetes/admin.conf ~vagrant/.kube/config
chown vagrant:vagrant -R ~vagrant/.kube
mkdir -p ~root/.kube
cp /etc/kubernetes/admin.conf ~root/.kube/config
cp /etc/kubernetes/admin.conf /host/kubeconfig

NET=${NETWORK:-calico}
if [ $NET == flannel ]; then 
  kubectl apply -f https://github.com/coreos/flannel/raw/master/Documentation/kube-flannel.yml --wait
  # Wait for the deployment/daemonset to spawn up
  # There is a known Bug where you need to restart cni0 but you also need to restart all pads using old network.
  sleep 10
  kubectl wait --for=condition=ready --timeout=30s -n kube-system "$(kubectl get pod -n kube-system -l app=flannel -o name|tail -n 1)"
  ip link delete cni0
  kubectl delete pod -n kube-system -l k8s-app=kube-dns --force --grace-period=0
  kubectl wait --for=condition=ready --timeout=30s -n kube-system -l k8s-app=kube-dns pod
fi

if [ $NET == calico ]; then 
  kubectl apply -f https://docs.projectcalico.org/manifests/calico.yaml
fi
NGINX=true
if [ $NGINX ]; then
  helm repo add nginx-stable https://helm.nginx.com/stable
  helm repo update
  helm install nginx-ingress nginx-stable/nginx-ingress \
  --set controller.service.type=NodePort \
  --set controller.service.httpPort.nodePort=32080 \
  --set controller.service.httpsPort.nodePort=32443 \
  --set controller.setAsDefaultIngress=true \
  --namespace nginx \
  --create-namespace
fi

kubectl completion bash > /etc/bash_completion.d/kubectl
echo 'alias k=kubectl' |tee /etc/profile.d/99-kubectl.sh
echo 'complete -F __start_kubectl k' |tee -a /etc/profile.d/99-kubectl.sh
chmod +x /etc/profile.d/99-kubectl.sh
kubectl taint nodes --all node-role.kubernetes.io/master-

# Install Krew utils
TEMPDIR=$(mktemp -d)
chmod -R 777 "${TEMPDIR}"
export TEMPDIR
cd "${TEMPDIR}" || exit 99
OS="$(uname | tr '[:upper:]' '[:lower:]')" &&
ARCH="$(uname -m | sed -e 's/x86_64/amd64/' -e 's/\(arm\)\(64\)\?.*/\1\2/' -e 's/aarch64$/arm64/')"
curl -fsSLO "https://github.com/kubernetes-sigs/krew/releases/latest/download/krew.tar.gz"
tar zxvf krew.tar.gz
KREW=$PWD/krew-"${OS}_${ARCH}"
chmod +r "$KREW"
"$KREW" install krew
sudo -u vagrant "$KREW" install krew

# shellcheck disable=SC2016
echo 'export PATH="${KREW_ROOT:-$HOME/.krew}/bin:$PATH"' > /etc/profile.d/99-krew.sh
chmod +x /etc/profile.d/krew.sh

# shellcheck disable=SC1091
source "/etc/profile.d/99-krew.sh"

kubectl krew install ns
kubectl krew install ctz

sudo -u vagrant kubectl krew install ctx
sudo -u vagrant kubectl krew install ns
sudo -u vagrant "$KREW" install krew
chmod -R 777 "${TEMPDIR}"
usermod --shell /bin/zsh vagrant
sh -c "$(curl -fsSL https://starship.rs/install.sh)" "" --yes
sudo -u vagrant git clone --depth 1 https://github.com/junegunn/fzf.git /home/vagrant/.fzf
sudo -u vagrant /home/vagrant/.fzf/install

cat <<EOF |tee ~vagrant/.zshrc
autoload -Uz compinit
compinit
source <(kubectl completion zsh)
eval "\$(starship init zsh)"
[ -f ~/.fzf.zsh ] && source ~/.fzf.zsh
EOF


mkdir -p ~/.config && touch ~/.config/starship.toml
cat <<EOF |tee ~/.config/starship.toml
[kubernetes]
format = 'on [⛵ $context \(\$namespace\)](dimmed green) '
disabled = false
[kubernetes.context_aliases]
"localhost.localdomain" = "local"
[line_break]
disabled = "false"
EOF

cp -rp ~/.config ~vagrant/.config
chown -R vagrant:vagrant ~vagrant/.config



echo export KUBECONFIG=\$PWD/kube/kubeconfig
  