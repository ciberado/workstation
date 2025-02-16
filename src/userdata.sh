#!/bin/bash

apt upgrade --assume-yes -y
snap install core; snap refresh core
sudo apt-get install software-properties-common -y


# Install AWS CLI
apt install -y unzip
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
unzip awscliv2.zip
sudo ./aws/install
rm -fr aws awscliv2.zip

# Set Public IP

INSTANCE_PUBLIC_IP=$(aws ec2 allocate-address --domain vpc --query "PublicIp" --output text)
TOKEN=`curl -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600"`
INSTANCE_ID=$(curl -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/instance-id)


cat << 'EOF' > /usr/local/bin/dns.sh 
#!/bin/bash

# DNS update
NAME=$(curl http://169.254.169.254/latest/meta-data/tags/instance/Name)
INSTANCE_DNS=$NAME-workstation.aprender.cloud

INSTANCE_ID=$(curl -s  http://instance-data/latest/meta-data/instance-id)
INSTANCE_EC2_DNS=$(curl -s http://169.254.169.254/latest/meta-data/public-hostname) 
INSTANCE_PUBLIC_IP=$(curl -s http://169.254.169.254/latest/meta-data/public-ipv4)

echo "Server $NAME FQDN is $INSTANCE_DNS, reconfiguring to point to $INSTANCE_PUBLIC_IP."

curl -s "https://wqgpdns5io5qghzjmr3l7kwcjq0glyqz.lambda-url.eu-west-1.on.aws/?name=$NAME-workstation&ip=$INSTANCE_PUBLIC_IP"; echo

until [ "$RESOLVED_IP" == "$INSTANCE_PUBLIC_IP" ]; do RESOLVED_IP=$(dig +short $INSTANCE_DNS); echo -n .; sleep 1; done; echo
EOF

NAME=$(curl http://169.254.169.254/latest/meta-data/tags/instance/Name)
INSTANCE_DNS=$NAME-workstation.aprender.cloud


echo Registering DNS. *********************************************
chmod +x /usr/local/bin/dns.sh
bash /usr/local/bin/dns.sh

crontab -l > mycron
echo "@reboot bash /usr/local/bin/dns.sh" >> mycron
crontab mycron
rm mycron

echo Installing nginx

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
          proxy_http_version 1.1;
          proxy_set_header Host \$host;
          proxy_set_header X-Forwarded-Proto \$scheme;
          proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
          proxy_set_header Upgrade \$http_upgrade;
          proxy_set_header Connection "upgrade";
          proxy_pass http://127.0.0.1:7681;
        }
}
EOF

ln -s /etc/nginx/sites-available/$INSTANCE_DNS /etc/nginx/sites-enabled/

service nginx restart

echo Generating TLS certificates, thanks to Letsencrypt *****************

apt remove certbot -y
snap install --classic certbot
ln -s /snap/bin/certbot /usr/bin/certbot

certbot --non-interactive \
  --nginx \
  -d $INSTANCE_DNS \
  --agree-tos \
  --email email+autocertbot@javier-moreno.com 


systemctl restart nginx

echo Configuring Docker *************************************************
apt install apt-transport-https ca-certificates curl software-properties-common -y
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | apt-key add -
add-apt-repository "deb [arch=amd64] https://download.docker.com/linux/ubuntu focal stable" -y
apt install docker-ce -y
usermod -aG docker ubuntu


# Install and configure tmux

apt install wget tmux -y
wget -O ~/.tmux.conf https://raw.githubusercontent.com/gpakosz/.tmux/master/.tmux.conf
wget -O ~/.tmux.conf.local https://raw.githubusercontent.com/gpakosz/.tmux/master/.tmux.conf.local

cat << EOF_ >> ~/.tmux.conf
set -g status-interval 1
set -g status-right '%H:%M:%S'
set-option -g window-size smallest
EOF_


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

echo Configure ttdy *********************************************

wget -O /usr/local/bin/ttyd https://github.com/tsl0922/ttyd/releases/download/1.4.2/ttyd_linux.i386
chmod +x /usr/local/bin/ttyd

cat << EOF > /etc/systemd/system/ttyd.service
[Unit]
Description=TTYD
After=syslog.target
After=network.target

[Service]
ExecStart=/usr/local/bin/ttyd login
Type=simple
Restart=always
User=root
Group=root

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl start ttyd
sudo systemctl enable ttyd

# Configure admin

echo -e "workshop@2025\nworkshop@2025" | passwd ubuntu

# Configure users

wget -O /etc/skel/.tmux.conf https://raw.githubusercontent.com/gpakosz/.tmux/master/.tmux.conf
wget -O /etc/skel/.tmux.conf.local https://raw.githubusercontent.com/gpakosz/.tmux/master/.tmux.conf.local
  
echo '[ "$TMUX" ] || tmux attach || tmux' >> /etc/skel/.profile

PASS=workshop@2025
for i in {1..30}
do
  sudo useradd -m seat$i
  sudo usermod -aG docker seat$i
  # sudo usermod -aG sudo seat$i
  sudo chsh -s /usr/bin/bash seat$i
  yes $PASS | sudo passwd seat$i
done
