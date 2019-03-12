#!/bin/bash -x

help() {
    echo "This script installs/configures haproxy on Ubuntu VM"
    echo "Options:"
    echo "        -a Backend application VM hostname (multiple allowed)"
    echo "        -l Load balancer DNS name"
    }

while getopts ":a:" opt; do
    case $opt in
        a)
          TRITVMS+=("$OPTARG")
          ;;

        \?) echo "Invalid option: -$OPTARG" >&2
          help
          ;;
    esac
done

setup_haproxy() {
    # Install haproxy

    apt-get upgrade -y
    hostnamectl set-hostname ha-proxy
    PROXY_IP=`host ha-proxy | awk '/has address/ { print $4 }'`
    apt-get install -y build-essential
    add-apt-repository -y ppa:vbernat/haproxy-1.9
    apt-get update
    apt-get install -y haproxy

    # Enable haproxy (to be started during boot)
    tmpf=`mktemp` && mv /etc/default/haproxy $tmpf && sed -e "s/ENABLED=0/ENABLED=1/" $tmpf > /etc/default/haproxy && chmod --reference $tmpf /etc/default/haproxy

    # Setup haproxy configuration file
    HAPROXY_CFG=/etc/haproxy/haproxy.cfg
    cp -p $HAPROXY_CFG ${HAPROXY_CFG}.default

    echo "
global
        log /dev/log    local0
        log /dev/log    local1 notice
        chroot /var/lib/haproxy
        stats socket /run/haproxy/admin.sock mode 660 level admin expose-fd listeners
        stats timeout 30s
        user haproxy
        group haproxy
        daemon

        # Default SSL material locations
        ca-base /etc/ssl/certs
        crt-base /etc/ssl/private

        ssl-default-bind-ciphers ECDH+AESGCM:DH+AESGCM:ECDH+AES256:DH+AES256:ECDH+AES128:DH+AES:RSA+AESGCM:RSA+AES:!aNULL:!MD5:!DSS
        ssl-default-bind-options no-sslv3

defaults
        log     global
        mode    http
        option  httplog
        option  dontlognull
        timeout connect 5000
        timeout client  50000
        timeout server  50000
        errorfile 400 /etc/haproxy/errors/400.http
        errorfile 403 /etc/haproxy/errors/403.http
        errorfile 408 /etc/haproxy/errors/408.http
        errorfile 500 /etc/haproxy/errors/500.http
        errorfile 502 /etc/haproxy/errors/502.http
        errorfile 503 /etc/haproxy/errors/503.http
        errorfile 504 /etc/haproxy/errors/504.http

frontend Local_Server

    bind $PROXY_IP:8080
    acl valid_http_method method GET HEAD OPTIONS POST
    http-request deny if ! valid_http_method
    mode http
    default_backend TRIT_Servers

backend TRIT_Servers
    mode http
    balance leastconn
    option forwardfor
    http-request set-header X-Forwarded-Port %[dst_port]
    http-request add-header X-Forwarded-Proto https if { ssl_fc }
    option httpchk /tag/health/getHealthStatus  HTTP/1.1\r\nHost:localhost "  > $HAPROXY_CFG

    # Add application VMs to haproxy listener configuration
    for TRITVM in "${TRITVMS[@]}"; do
        TRITVM_IP=`host $TRITVM | awk '/has address/ { print $4 }'`
        if [[ -z $TRITVM_IP ]]; then
            echo "Unknown hostname $TRITVM. Cannot be added to $HAPROXY_CFG." >&2
        else
            echo "    server $TRITVM $TRITVM_IP check fall 3 rise 2" >> $HAPROXY_CFG
        fi
    done


    # Start haproxy service
    service haproxy start
}


# Setup haproxy
setup_haproxy
