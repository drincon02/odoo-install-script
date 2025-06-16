#!/bin/bash
set -euo pipefail

### CONFIGURATION ###
enterprise="False"
enterprise_path="/enterprise/odoo-server"
enterprise_folder_name="odoo-server"
odoo_path="/opt/odoo18"
odoo_user="odoo"
odoo_port="8069"
postgres_install="True"
admin_passwd="admin"
odoo_db_password="123456"

######################

# Determine addon and requirements path
if [ "$enterprise" == "False" ]; then
    requirements_path="$odoo_path/requirements.txt"
    addons_path="$odoo_path/addons"
else
    requirements_path="$odoo_path/$enterprise_folder_name/requirements.txt"
    addons_path="$odoo_path/$enterprise_folder_name/odoo/addons"
fi

echo -e "\n📦 Updating system packages..."
sudo apt-get update && sudo apt-get upgrade -y

echo -e "\n🔒 Installing and configuring UFW firewall..."
sudo apt-get install -y ufw
sudo ufw allow OpenSSH
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw --force enable

echo -e "\n🔒 Installing and configuring Fail2Ban..."
sudo apt-get install -y fail2ban
sudo tee /etc/fail2ban/jail.local > /dev/null <<'EOF'
[DEFAULT]
bantime = 1h
findtime = 10m
maxretry = 5

[sshd]
enabled = true
port = ssh
logpath = %(sshd_log)s
backend = systemd
maxretry = 5
bantime = 1h
findtime = 10m
EOF
sudo systemctl restart fail2ban
sudo systemctl enable fail2ban

echo -e "\n🛡️ Setting up audit logging with auditd..."
sudo apt-get install -y auditd audispd-plugins
sudo tee /etc/audit/rules.d/odoo.rules > /dev/null <<'EOF'
-w /usr/bin/sudo -p x -k sudo-log
-w /etc/odoo.conf -p rwxa -k odoo-conf
-w /etc/systemd/system/odoo.service -p rwxa -k odoo-service
-w /var/log/auth.log -p rwa -k ssh-log
EOF
sudo systemctl restart auditd
sudo systemctl enable auditd

echo -e "\n🧾 Creating persistent deployment log at /var/log/odoo/deployment.log"
sudo mkdir -p /var/log/odoo
exec > >(tee -i /var/log/odoo/deployment.log)
exec 2>&1

echo -e "\n🐍 Installing Python and build dependencies..."
sudo apt-get install -y python3 python3-pip python3-venv
sudo apt-get install -y build-essential libxml2-dev libxslt1-dev zlib1g-dev \
    libsasl2-dev libldap2-dev libssl-dev libffi-dev libjpeg-dev libpq-dev \
    libjpeg8-dev liblcms2-dev libblas-dev libatlas-base-dev libmysqlclient-dev

if [ "$postgres_install" == "True" ]; then
    echo -e "\n🐘 Installing PostgreSQL..."
    sudo apt-get install -y postgresql
    sudo -u postgres psql -c "CREATE USER $odoo_user WITH PASSWORD '$odoo_db_password' SUPERUSER;"
fi

echo -e "\n👤 Creating system user $odoo_user..."
sudo adduser --system --home=$odoo_path --group $odoo_user || true

echo -e "\n📁 Installing Git and cloning Odoo..."
sudo apt install -y git
if [ "$enterprise" == "False" ]; then
    git clone https://www.github.com/odoo/odoo --depth 1 --branch 18.0 --single-branch $odoo_path
else
    sudo mv $enterprise_path $odoo_path
fi

echo -e "\n📦 Creating and activating Python virtual environment..."
python3 -m venv $odoo_path/venv
source $odoo_path/venv/bin/activate
pip install --upgrade pip
pip install -r $requirements_path
deactivate

echo -e "\n🖨 Installing wkhtmltopdf with patched Qt..."
cd $odoo_path
wget https://github.com/wkhtmltopdf/wkhtmltopdf/releases/download/0.12.5/wkhtmltox_0.12.5-1.bionic_amd64.deb
wget http://archive.ubuntu.com/ubuntu/pool/main/o/openssl/libssl1.1_1.1.1f-1ubuntu2_amd64.deb
sudo dpkg -i libssl1.1_1.1.1f-1ubuntu2_amd64.deb || true
sudo apt-get install -y xfonts-75dpi
sudo dpkg -i wkhtmltox_0.12.5-1.bionic_amd64.deb || true
sudo apt install -f -y

echo -e "\n🛠 Configuring Odoo..."
sudo touch /etc/$odoo_user.conf
cat <<EOF | sudo tee /etc/$odoo_user.conf
[options]
admin_passwd = $admin_passwd
db_host = localhost
db_port = 5432
db_user = $odoo_user
logfile = /var/log/odoo/$odoo_user.log
db_password = $odoo_db_password
addons_path = $addons_path
gevent_port = 8072
proxy_mode = True
workers = 2
limit_memory_soft = 512000000
limit_memory_hard = 640000000
limit_time_cpu = 60
limit_time_real = 120
max_cron_threads = 1
limit_time_real_cron = -1
EOF

sudo chown $odoo_user: /etc/$odoo_user.conf
sudo chmod 640 /etc/$odoo_user.conf
sudo chown $odoo_user:root /var/log/odoo

odoobinpath="$odoo_path/odoo-bin"
if [ "$enterprise" == "True" ]; then
    cp $odoo_path/$enterprise_folder_name/setup/odoo $odoo_path/$enterprise_folder_name/odoo-bin
    odoobinpath="$odoo_path/$enterprise_folder_name/odoo-bin"
fi

echo -e "\n🔧 Creating systemd service for Odoo..."
cat <<EOF | sudo tee /etc/systemd/system/$odoo_user.service
[Unit]
Description=Odoo instance for $odoo_user
After=network.target postgresql.service

[Service]
Type=simple
User=$odoo_user
ExecStart=$odoo_path/venv/bin/python3 $odoobinpath -c /etc/$odoo_user.conf
Restart=always
RestartSec=5s
LimitNOFILE=65535
PrivateTmp=true
ProtectSystem=full

[Install]
WantedBy=multi-user.target
EOF

sudo chmod 644 /etc/systemd/system/$odoo_user.service
sudo systemctl daemon-reexec
sudo systemctl daemon-reload
sudo systemctl enable --now $odoo_user

# echo -e "\n📊 Installing Node Exporter..."
# NODE_EXPORTER_VERSION="1.9.1"
# cd /opt
# wget https://github.com/prometheus/node_exporter/releases/download/v${NODE_EXPORTER_VERSION}/node_exporter-${NODE_EXPORTER_VERSION}.linux-amd64.tar.gz
# tar -xzf node_exporter-${NODE_EXPORTER_VERSION}.linux-amd64.tar.gz
# sudo mv node_exporter-${NODE_EXPORTER_VERSION}.linux-amd64/node_exporter /usr/local/bin/
# rm -rf node_exporter-${NODE_EXPORTER_VERSION}*

# sudo useradd -rs /bin/false node_exporter

# sudo tee /etc/systemd/system/node_exporter.service > /dev/null <<EOF
# [Unit]
# Description=Node Exporter
# After=network.target

# [Service]
# User=node_exporter
# Group=node_exporter
# Type=simple
# ExecStart=/usr/local/bin/node_exporter

# [Install]
# WantedBy=default.target
# EOF

# sudo systemctl daemon-reload
# sudo systemctl enable --now node_exporter

# echo -e "\n📊 Installing Postgres Exporter..."
# POSTGRES_EXPORTER_VERSION="0.17.1"
# cd /opt
# wget https://github.com/prometheus-community/postgres_exporter/releases/download/v${POSTGRES_EXPORTER_VERSION}/postgres_exporter-${POSTGRES_EXPORTER_VERSION}.linux-amd64.tar.gz
# tar -xzf postgres_exporter-${POSTGRES_EXPORTER_VERSION}.linux-amd64.tar.gz
# sudo mv postgres_exporter-${POSTGRES_EXPORTER_VERSION}.linux-amd64/postgres_exporter /usr/local/bin/
# rm -rf postgres_exporter-${POSTGRES_EXPORTER_VERSION}*

# sudo useradd -rs /bin/false postgres_exporter

# # Create PostgreSQL metrics user
# sudo -u postgres psql -c "CREATE USER exporter PASSWORD 'exporterpassword' SUPERUSER;"

# sudo tee /etc/postgres_exporter.env > /dev/null <<EOF
# DATA_SOURCE_NAME=postgresql://exporter:exporterpassword@localhost:5432/postgres?sslmode=disable
# EOF

# sudo tee /etc/systemd/system/postgres_exporter.service > /dev/null <<EOF
# [Unit]
# Description=PostgreSQL Exporter
# After=network.target

# [Service]
# User=postgres_exporter
# Group=postgres_exporter
# EnvironmentFile=/etc/postgres_exporter.env
# ExecStart=/usr/local/bin/postgres_exporter

# [Install]
# WantedBy=multi-user.target
# EOF

# sudo systemctl daemon-reload
# sudo systemctl enable --now postgres_exporter

echo -e "\n✅ Odoo installation completed and running on port $odoo_port"

### CONFIGURATION FOR NGINX + SSL ###
domain_name="backoffice.codesign.codes"  # <-- Set this as needed

echo -e "\n🌐 Installing and configuring Nginx..."
sudo apt-get install -y nginx

echo -e "\n🌐 Creating Nginx config for domain $domain_name..."
sudo tee /etc/nginx/sites-available/$domain_name > /dev/null <<'EOF'
server {
    listen 80;
    server_name $domain_name www.$domain_name;

    location / {
        proxy_pass http://127.0.0.1:8069;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }

    access_log /var/log/nginx/odoo_access.log;
    error_log /var/log/nginx/odoo_error.log;
    #   increase    proxy   buffer  size
    proxy_buffers   16  64k;
    proxy_buffer_size   128k;

    proxy_read_timeout 900s;
    proxy_connect_timeout 900s;
    proxy_send_timeout 900s;

    #   force   timeouts    if  the backend dies
    proxy_next_upstream error   timeout invalid_header  http_500    http_502
    http_503;

    types {
        text/less less;
        text/scss scss;
    }

    #   enable  data    compression
    gzip    on;
    gzip_min_length 1100;
    gzip_buffers    4   32k;
    gzip_types  text/css text/less text/plain text/xml application/xml application/json application/javascript application/pdf image/jpeg image/png;
    gzip_vary   on;
    client_header_buffer_size 4k;
    large_client_header_buffers 4 64k;
    client_max_body_size 0;

    location /websocket {
        proxy_redirect off;
        proxy_pass http://127.0.0.1:8072;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
    }

    location ~* .(js|css|png|jpg|jpeg|gif|ico)$ {
        expires 2d;
        proxy_pass http://127.0.0.1:8069;
        add_header Cache-Control "public, no-transform";
    }

    # cache some static data in memory for 60mins.
    location ~ /[a-zA-Z0-9_-]*/static/ {
    proxy_cache_valid 200 302 60m;
    proxy_cache_valid 404      1m;
    proxy_buffering    on;
    expires 864000;
    proxy_pass    http://127.0.0.1:8069;
}}
EOF

echo -e "\n🔗 Enabling Nginx site and restarting Nginx..."
sudo ln -s /etc/nginx/sites-available/$domain_name /etc/nginx/sites-enabled/
sudo nginx -t && sudo systemctl restart nginx

echo -e "\n🔐 Installing Certbot for Let's Encrypt SSL..."
sudo apt-get install -y certbot python3-certbot-nginx

echo -e "\n🔐 Requesting SSL certificate for $domain_name..."
sudo certbot --nginx -d $domain_name -d www.$domain_name --non-interactive --agree-tos -m admin@$domain_name --redirect

echo -e "\n🔁 Setting up automatic certificate renewal..."
sudo systemctl enable certbot.timer

sudo systemctl restart $odoo_user