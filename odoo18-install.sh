#!/bin/bash

enterprise="False"
enterprise_path="/enterprise/odoo-server"
enterprise_folder_name="odoo-server"
odoo_path="/opt/odoo18"
odoo_user="odoo"
odoo_port="8069"
postgres_install="True"

if [ $enterprise == "False" ]; then
    requirements_path="$odoo_path/requirements.txt"
    addons_path="$odoo_path/addons"
else
    requirements_path="$odoo_path/$enterprise_folder_name/requirements.txt"
    addons_path="$odoo_path/$enterprise_folder_name/odoo/addons"
fi

echo -e "\nUpdating server"
sudo apt-get update
sudo apt-get upgrade -y

echo -e "\n--- Installing Python ---"
sudo apt-get install -y python3 python3-pip
sudo apt-get install -y python3-dev libxml2-dev libxslt1-dev zlib1g-dev libsasl2-dev libldap2-dev build-essential libssl-dev libffi-dev libmysqlclient-dev libjpeg-dev libpq-dev libjpeg8-dev liblcms2-dev libblas-dev libatlas-base-dev

if [ $postgres_install == 'True' ]; then
    echo -e "\n--- Installling Postgresql ---"
    sudo apt-get install -y postgresql
    sudo -u postgres createuser --createdb --username postgres --no-createrole --superuser --pwprompt $odoo_user
fi

echo -e "\nCreating odoo system user named $odoo_user at $odoo_path"
sudo adduser --system --home=$odoo_path --group $odoo_user

sudo apt-get install -y git

echo -e "\nDownloading Odoo 18.0"
if [ $enterprise == "False" ]; then
    cd $odoo_path
    git clone https://www.github.com/odoo/odoo --depth 1 --branch 18.0 --single-branch .
else 
    mv $enterprise_path $odoo_path    
fi

echo -e "\nInstalling Dependencies"
sudo apt install -y python3-venv
sudo python3 -m venv $odoo_path/venv
source $odoo_path/venv/bin/activate
pip install -r $requirements_path
cd $odoo_path
sudo wget https://github.com/wkhtmltopdf/wkhtmltopdf/releases/download/0.12.5/wkhtmltox_0.12.5-1.bionic_amd64.deb
sudo wget http://archive.ubuntu.com/ubuntu/pool/main/o/openssl/libssl1.1_1.1.1f-1ubuntu2_amd64.deb
sudo dpkg -i libssl1.1_1.1.1f-1ubuntu2_amd64.deb
sudo apt-get install -y xfonts-75dpi
sudo dpkg -i wkhtmltox_0.12.5-1.bionic_amd64.deb
sudo apt install -f
deactivate

echo -e "\nSetting Configuration File"
sudo touch /etc/$odoo_user.conf
echo "[options]
   ; This is the password that allows database operations:
   ; admin_passwd = admin
   db_host = localhost
   db_port = 5432
   db_user = $odoo_user
   db_password = 123456
   addons_path = $addons_path
   default_productivity_apps = True
   logfile = /var/log/odoo/$odoo_user.log
" > "/etc/$odoo_user.conf"

sudo chown $odoo_user: /etc/$odoo_user.conf
sudo chmod 640 /etc/$odoo_user.conf
sudo mkdir /var/log/odoo
sudo chown $odoo_user:root /var/log/odoo

if [ $enterprise == "True" ]; then
    cp $odoo_path/$enterprise_folder_name/setup/odoo $odoo_path/$enterprise_folder_name/odoo-bin
    odoobinpath="$odoo_path/$enterprise_folder_name/odoo-bin"
else
    odoobinpath="$odoo_path/odoo-bin"
fi

echo -e "\nCreating systemd service"
echo "[Unit]
Description=$odoo_user
Documentation=http://www.odoo.com
[Service]
# Ubuntu/Debian convention:
Type=simple
User=$odoo_user
ExecStart=$odoo_path/venv/bin/python3.12 $odoobinpath -c /etc/$odoo_user.conf
[Install]
WantedBy=default.target"
> "/etc/systemd/system/$odoo_user.service"


sudo chmod 755 /etc/systemd/system/$odoo_user.service
sudo chown root: /etc/systemd/system/$odoo_user.service
sudo systemctl enable $odoo_user.service
sudo systemctl restart $odoo_user.service