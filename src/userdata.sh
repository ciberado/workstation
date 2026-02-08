#!/bin/bash

apt update
apt upgrade --assume-yes -y
snap install core; snap refresh core

# Docker
apt install apt-transport-https ca-certificates curl software-properties-common -y
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | apt-key add -
add-apt-repository "deb [arch=amd64] https://download.docker.com/linux/ubuntu focal stable" -y
apt install docker-ce -y
usermod -aG docker ubuntu


# Install and configure tmux

apt install wget tmux -y
wget -O ~/.tmux.conf https://raw.githubusercontent.com/gpakosz/.tmux/master/.tmux.conf
wget -O ~/.tmux.conf.local https://raw.githubusercontent.com/gpakosz/.tmux/master/.tmux.conf.local

## tmux on login

cat << EOF >> ~/.bashrc
if [[ -z \$TMUX ]]; then
  tmux attach -t default || tmux new -s default
fi
EOF

# Install AWS CLI v2

apt install unzip -y
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
unzip awscliv2.zip
./aws/install
rm -rf awscliv2.zip aws

# Install Terraform

apt install -y gnupg software-properties-common curl
curl -fsSL https://apt.releases.hashicorp.com/gpg | sudo apt-key add -
apt-add-repository "deb [arch=amd64] https://apt.releases.hashicorp.com jammy main" -y
apt update 
apt install terraform -y

# Install node (with NVM)

curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.2/install.sh | bash
export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"  # This loads nvm
[ -s "$NVM_DIR/bash_completion" ] && \. "$NVM_DIR/bash_completion"  
nvm install --lts
n=$(which node);n=${n%/bin/node}; chmod -R 755 $n/bin/*; sudo cp -r $n/{bin,lib,share} /usr/local	

# Install kubectl

curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
mv kubectl /usr/local/bin/
chmod +x /usr/local/bin/kubectl

# Install several tools

apt install -y jq

# Set ubuntu user password

echo "ubuntu:arch@1234" | chpasswd

# Configure ttyd

wget -O /usr/local/bin/ttyd https://github.com/tsl0922/ttyd/releases/download/1.7.7/ttyd.x86_64
chmod +x /usr/local/bin/ttyd

cat << EOF > /etc/systemd/system/ttyd.service
[Unit]
Description=TTYD
After=syslog.target
After=network.target

[Service]
ExecStart=/usr/local/bin/ttyd -p 7681 -i 127.0.0.1 login
Type=simple
Restart=always
User=root
Group=root

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl start ttyd
sudo systemctl enable ttyd

# Install and configure Caddy

apt install -y debian-keyring debian-archive-keyring apt-transport-https curl
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | tee /etc/apt/sources.list.d/caddy-stable.list
apt update
apt install caddy -y

# Create Caddyfile for reverse proxy to ttyd
# Get public hostname from EC2 metadata (using IMDSv2)

TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
PUBLIC_HOSTNAME=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/public-hostname)

cat << EOF > /etc/caddy/Caddyfile
${PUBLIC_HOSTNAME} {
	reverse_proxy localhost:7681 {
		header_up Host {host}
		header_up X-Real-IP {remote}
		header_up X-Forwarded-For {remote}
		header_up X-Forwarded-Proto {scheme}
	}
}
EOF

# Enable and start Caddy

sudo systemctl enable caddy
sudo systemctl start caddy

