#!/bin/bash

###########################
#  MIT License            #
#  Copyright (c) 2020.    #
###########################

function run() {
  red="\033[0;31m"
  green="\033[0;32m"
  noc="\033[0m"
  cmd_text="$1"

  echo -e "=========== ${cmd_text}"
  shift
  $@ 2>&1 | while read -r line; do
    echo -e "\r\e[K$line"
  done
  ret=$?
  if [ ${ret} -eq 0 ]; then
    echo -e "\r[ ${green}SUCCESS${noc} ]\n"
  else
    echo -e "\r[   ${red}FAIL${noc}  ]\n"
    exit 1
  fi
}

function loomio_env() {
  cd ${loomio_gitdir}
  ./scripts/create_env ${LOOMIO_FQDN} ${LOOMIO_CONTACT_EMAIL} || return 1

  if [ -f env ]; then
    # set smtp variables
    sed -i "s/^.*SMTP_AUTH.*=.*$/SMTP_AUTH=${SMTP_AUTH}/g" env
    sed -i "s/^.*SMTP_DOMAIN.*=.*$/SMTP_DOMAIN=${SMTP_DOMAIN}/g" env
    sed -i "s/^.*SMTP_SERVER.*=.*$/SMTP_SERVER=${SMTP_SERVER}/g" env
    sed -i "s/^.*SMTP_PORT.*=.*$/SMTP_PORT=${SMTP_PORT}/g" env
    sed -i "s/^.*SMTP_USERNAME.*=.*$/SMTP_USERNAME=${SMTP_USERNAME}/g" env
    sed -i "s/^.*SMTP_PASSWORD.*=.*$/SMTP_PASSWORD=${SMTP_PASSWORD}/g" env
    sed -i "s/^.*SMTP_USE_SSL.*=.*$/SMTP_USE_SSL=${SMTP_USE_SSL}/g" env

    # set usage reporting to Loomio
    echo -e "\nDISABLE_USAGE_REPORTING=${DISABLE_USAGE_REPORTING}" >> env
  else
    echo "Loomio env file was not created, something bad might has happened!"
    return 1
  fi
}

function loomio_swap() {
  cd ${loomio_gitdir}
  totalram=$(cat /proc/meminfo | grep MemTotal | awk '{ kbyte =$2 /1024/1024; print kbyte }')

  if (( $(echo "$totalram < 2.0" | bc -l) ))
  then
    echo "Memory is less than 2GB, setting swapfile..."
    ./scripts/create_swapfile || return 1
  fi
}

function loomio_db() {
  if [[ $(docker ps --filter 'name=loomio-db' --filter 'name=loomio-redis' --format '{{.Names}}' | wc -l) != 2 ]]; then
    docker-compose up -d db || return 1
    docker-compose run app rake db:setup || return 1
  fi

  if [[ $(crontab -l | egrep -v "^(#|$)" | grep -q "${crontab_entry}"; echo $?) == 1 ]]; then
    echo "$(crontab -l; echo "${crontab_entry}")" | crontab -
  fi
}

function wait_for_letsencrypt() {
  while (( wait_timeout-- > 0 )) || { echo "ERROR! Letsencrypt certificate was not created in time, quit."; return 1; }
  do
    echo -e "waiting \e[7m$((${wait_timeout}*2))\e[27m sec to letsencrypt certificate generation...\r"
    echo -en "\r\033[1A\033[K"
    [ -f ${ssl_cert_path} ] && [ -f ${ssl_key_path} ] && return 0
    sleep 2
  done
}

function apache_restart() {
  systemctl restart apache2.service || return 1
  systemctl reload apache2 || return 1
}

function clone_loomio_repo() {
  [ ! -d ./loomio-deploy ] && git clone https://github.com/loomio/loomio-deploy.git || return 0
}

function get_docker_compose() {
  curl -L "https://github.com/docker/compose/releases/download/1.25.5/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose || return 1
  chmod +x /usr/local/bin/docker-compose || return 1
}

############################
##########  MAIN  ##########
############################

. config.properties 2>/dev/null || { echo "Could not find config.properties, exit!"; exit 1; }

set -o pipefail
workdir_fullpath=$(pwd)
ssl_cert_path="${workdir_fullpath}/loomio-deploy/nginx/certs/${LOOMIO_FQDN}/fullchain.pem"
ssl_key_path="${workdir_fullpath}/loomio-deploy/nginx/certs/${LOOMIO_FQDN}/key.pem"
crontab_entry='0 * * * *  /snap/bin/docker exec loomio-worker bundle exec rake loomio:hourly_tasks > ~/rake.log 2>&1'
loomio_gitdir="./loomio-deploy"
wait_timeout=60

echo "Starting Loomio automated deployment..."

run "Updating apt cache" apt update
run "Installing docker engine..." snap install docker
run "Installing yq..." snap install yq
run "Installing Apache2..." apt install -y apache2
run "Enabling Apache2 modproxy..." a2enmod proxy
run "Enabling Apache2 proxy_http..." a2enmod proxy_http
run "Enabling Apache2 ssl..." a2enmod ssl

# this is not a fatal problem, so temporary disable pipefail
set +o pipefail
run "Temporary disable loomio-vhost-https..." a2query -c loomio-vhost-https && a2disconf loomio-vhost-https
set -o pipefail

cat << EOF > /etc/apache2/conf-available/loomio-vhost-http.conf
<VirtualHost *:80>
  ProxyPreserveHost On
  ProxyRequests Off
  ServerName www.${LOOMIO_FQDN}
  ServerAlias ${LOOMIO_FQDN}
  ProxyPass / http://127.0.0.1:${LOOMIO_NGINX_HTTP_PORT}/
  ProxyPassReverse / http://127.0.0.1:${LOOMIO_NGINX_HTTP_PORT}/
</VirtualHost>
EOF

run "Enabling Loomio http virtual host..." a2enconf loomio-vhost-http
run "Restarting Apache2 service..." apache_restart
run "Getting docker-compose binary..." get_docker_compose
run "Checking git binary..." which git || apt install git
run "Cloning loomio repository..." clone_loomio_repo

# Loomio swap file if needed
run "Creating Loomio swap..." loomio_swap

# Loomio env
run "Creating Loomio env..." loomio_env

# customize Loomio
cd ${loomio_gitdir}
run "Customizing Loomio (1)..." yq w -i docker-compose.yml 'services.nginx.ports[0]' 127.0.0.1:${LOOMIO_NGINX_HTTP_PORT}:80
run "Customizing Loomio (2)..." yq w -i docker-compose.yml 'services.nginx.ports[1]' 127.0.0.1:${LOOMIO_NGINX_HTTPS_PORT}:443

# initialize new database for Loomio
run "Initialize Loomio database..." loomio_db

# start loomio
docker-compose up -d || return 1

# create https virtual host for Apache2
cat << EOF > /etc/apache2/conf-available/loomio-vhost-https.conf
<VirtualHost *:443>
  ProxyPreserveHost On
  ProxyRequests Off
  ServerName www.${LOOMIO_FQDN}
  ServerAlias ${LOOMIO_FQDN}
  SSLProxyEngine on
  SSLCertificateFile ${ssl_cert_path}
  SSLCertificateKeyFile ${ssl_key_path}
  ProxyPass / https://127.0.0.1:${LOOMIO_NGINX_HTTPS_PORT}/
  ProxyPassReverse / https://127.0.0.1:${LOOMIO_NGINX_HTTPS_PORT}/
</VirtualHost>
EOF

run "Wait for Letsencrypt certificate to create..." wait_for_letsencrypt
run "Enabling Loomio https virtal host..." a2enconf loomio-vhost-https
run "Restarting Apache2 service..." apache_restart
