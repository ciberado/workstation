#!/bin/bash

apt update
apt upgrade --assume-yes -y
snap install core; snap refresh core

# DNS update
NAME=$(curl http://169.254.169.254/latest/meta-data/tags/instance/Name)
INSTANCE_DNS=$NAME-workstation.aprender.cloud

INSTANCE_ID=$(curl -s  http://instance-data/latest/meta-data/instance-id)
INSTANCE_EC2_DNS=$(curl -s http://169.254.169.254/latest/meta-data/public-hostname) 
INSTANCE_PUBLIC_IP=$(curl -s http://169.254.169.254/latest/meta-data/public-ipv4)

echo "Server $NAME FQDN is $INSTANCE_DNS, reconfiguring to point to $INSTANCE_PUBLIC_IP."

curl -s "https://wqgpdns5io5qghzjmr3l7kwcjq0glyqz.lambda-url.eu-west-1.on.aws/?name=$NAME-workstation&ip=$INSTANCE_PUBLIC_IP"; echo

until [ "$RESOLVED_IP" == "$INSTANCE_PUBLIC_IP" ]; do RESOLVED_IP=$(dig +short $INSTANCE_DNS); echo -n .; sleep 1; done; echo


# Install nginx

# apt-get remove --purge nginx nginx-full nginx-common 
apt install nginx -y

sed -i 's/# server_names_hash_bucket_size 64/server_names_hash_bucket_size 512/' /etc/nginx/nginx.conf
sed -i '/server_names_hash_bucket_size/a proxy_headers_hash_max_size 512;' /etc/nginx/nginx.conf
sed -i '/server_names_hash_bucket_size/a proxy_headers_hash_bucket_size 128;' /etc/nginx/nginx.conf

mkdir -p /var/www/$INSTANCE_DNS/html
chmod -R 755 /var/www/$INSTANCE_DNS
echo "Empty." > /var/www/$INSTANCE_DNS/html/index.html

cat << EOF > /etc/nginx/sites-available/$INSTANCE_DNS
server {
        listen 80;
        listen [::]:80;

        root /var/www/$INSTANCE_DNS/html;
        index index.html index.htm index.nginx-debian.html;

        server_name $INSTANCE_DNS;

        location / {
                try_files \$uri \$uri/ =404;
        }
}
EOF

ln -s /etc/nginx/sites-available/$INSTANCE_DNS /etc/nginx/sites-enabled/

service nginx restart

# Generating TLS certificates, thanks to Letsencrypt

apt remove certbot -y
snap install --classic certbot
ln -s /snap/bin/certbot /usr/bin/certbot

certbot --non-interactive \
  --nginx \
  -d $INSTANCE_DNS \
  --agree-tos \
  --email email+autocertbot@javier-moreno.com 


systemctl restart nginx

# Docker
apt install apt-transport-https ca-certificates curl software-properties-common -y
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | apt-key add -
add-apt-repository "deb [arch=amd64] https://download.docker.com/linux/ubuntu focal stable" -y
apt install docker-ce -y
usermod -aG docker ubuntu

# Firefox

docker run \
    -d \
    --name=firefox \
 --network host \
 --restart=unless-stopped  \
 -v /docker/appdata/firefox:/config:rw \
    jlesage/firefox

cat << 'EOF' > /tmp/firefox-prefix.txt

map $http_upgrade $connection_upgrade {
        default upgrade;
        ''      close;
}

upstream docker-firefox {
        server 127.0.0.1:5800;
}

EOF

sed -i '0,/^/e cat /tmp/firefox-prefix.txt' /etc/nginx/sites-enabled/$INSTANCE_DNS

cat << 'EOF' > /tmp/firefox-server.txt

  location = /firefox {return 301 $scheme://$http_host/firefox/;}
  location /firefox/ {
    proxy_pass http://docker-firefox/;
    location /firefox/websockify {
      proxy_pass http://docker-firefox/websockify/;
      proxy_http_version 1.1;
      proxy_set_header Upgrade $http_upgrade;
      proxy_set_header Connection $connection_upgrade;
      proxy_read_timeout 86400;
    }
  }

EOF

sed -i -e '/root/r /tmp/firefox-server.txt' /etc/nginx/sites-enabled/$INSTANCE_DNS

# VSCode

docker run  \
   -d \
   --name=code-server-ls \
   -e PASSWORD=supersecret \
   -e PUID=0 \
   -e PGID=0 \
   -e TZ=Europe/London \
   --network host \
   -v /docker/appdata/coder-ls/.config:/config \
   --restart unless-stopped \
   lscr.io/linuxserver/code-server:latest

cat << 'EOF' > /tmp/vscode.txt

    location /vscode/ {
      proxy_pass http://localhost:8443/;
      proxy_redirect off;
      proxy_set_header Host $host;
      proxy_set_header Upgrade $http_upgrade;
      proxy_set_header Connection upgrade;
      proxy_set_header Accept-Encoding gzip;
    }

EOF

sed -i '/root/r /tmp/vscode.txt' /etc/nginx/sites-enabled/$INSTANCE_DNS

service nginx restart


# Container configuration

docker exec -i code-server-ls bash << 'EOF'

apt update
apt upgrade -y
sudo apt-get install software-properties-common -y

# Install and configure tmux

apt install wget tmux -y
wget -O ~/.tmux.conf https://raw.githubusercontent.com/gpakosz/.tmux/master/.tmux.conf
wget -O ~/.tmux.conf.local https://raw.githubusercontent.com/gpakosz/.tmux/master/.tmux.conf.local

cat << EOF_ >> ~/.tmux.conf
set -g status-interval 1
set -g status-right '%H:%M:%S'
set-option -g window-size smallest
EOF_

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

wget https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64 -O /usr/bin/yq &&\
    chmod +x /usr/bin/yq

EOF


# Configure ttdy

wget -O /usr/local/bin/ttyd https://github.com/tsl0922/ttyd/releases/download/1.4.2/ttyd_linux.i386
chmod +x /usr/local/bin/ttyd

cat << EOF > /etc/systemd/system/ttyd.service
[Unit]
Description=TTYD
After=syslog.target
After=network.target

[Service]
ExecStart=/usr/local/bin/ttyd docker exec -it code-server-ls bash -c "tmux attach || tmux"
Type=simple
Restart=always
User=root
Group=root

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl start ttyd
sudo systemctl enable ttyd

