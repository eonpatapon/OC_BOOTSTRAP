#!/bin/bash

[ -z $OS_USERNAME ] && echo "Source OS credentials first." && exit 0

[ -f localrc ] && source localrc

uuid()
{
     echo $( cat /proc/sys/kernel/random/uuid | cut -d '-' -f 1 )
}

TLD=${TLD:-occi.}
KEY_NAME=${KEY_NAME:-bootstrap}
IMAGE=${IMAGE:-5db66a8a-3165-4606-982d-43e89846c16f}
ADM_NETWORK=${ADM_NETWORK:-c2abf4aa-3631-4d6d-a4ab-f54fed99bdfb}
USR_NETWORK=${USR_NETWORK:-95b20e17-38c1-446e-b2b5-eecf6ced198f}

BOOTSTARP_UUID=$( uuid )
BOOTSTRAP_ID=${BOOTSTRAP_ID:-$BOOTSTARP_UUID}

wait_for_controller()
{
    CONTROLLER=$1
    
    while true
    do
        echo Waiting for $CONTROLLER
        CONTROLLER_IP=$( nova --insecure show $CONTROLLER | grep "adm network" | awk -F '|' '{print $3}' | tr -d '[[:space:]]' )
        curl http://$CONTROLLER_IP:8082 2>/dev/null 1>/dev/null && break
    done
}

spawn_controller()
{
    CONTROLLER_UUID=controller-${1}-$( uuid )
    
    nova --insecure boot --flavor m1.large --image $IMAGE --key-name $KEY_NAME \
        --nic net-id=$ADM_NETWORK --nic net-id=$USR_NETWORK \
        --user-data controller.yaml $CONTROLLER_UUID > /dev/null

    echo $CONTROLLER_UUID
}

get_adm_ip()
{
    NAME=$1
    nova --insecure show $NAME | grep "adm network" | awk -F '|' '{print $3}' | tr -d '[[:space:]]'
}

get_usr_ip()
{
    NAME=$1
    nova --insecure show $NAME | grep "usr network" | awk -F '|' '{print $3}' | tr -d '[[:space:]]'
}

ssh_command()
{
    NAME=$1
    CMD=$2
    IP=$( get_adm_ip $NAME )
    ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null $IP "$CMD"
}

register_dns()
{
    NODE_NAME=$1
    NODE_IP=$( get_usr_ip $NODE_NAME )

    # A
    ( echo update del $NODE_NAME.$TLD ; echo send ) | sudo nsupdate -v -l -k /etc/bind/rndc.key
    ( echo update add $NODE_NAME.$TLD 300 A $NODE_IP ; echo send ) | sudo nsupdate -v -l -k /etc/bind/rndc.key

    # PTR
    PTR=$( echo $NODE_IP | awk 'BEGIN{FS="."}{print $4"."$3"."$2"."$1".in-addr.arpa"}' )
    ( echo update del $PTR ; echo send ) | sudo nsupdate -v -l -k /etc/bind/rndc.key
    ( echo update add $PTR 300 PTR $NODE_NAME.$TLD ; echo send ) | sudo nsupdate -v -l -k /etc/bind/rndc.key
}

get_post_install_config()
{
    CONFIG_IP=$( get_usr_ip $1 )
    CONTROLLER1_IP=$( get_usr_ip $2 )
    CONTROLLER2_IP=$( get_usr_ip $3 )

cat <<EOF

#--------------------------

CONTRAIL_VGW_INTERFACE=vgw
CONTRAIL_VGW_PUBLIC_NETWORK=default-domain:admin:public:public
CONTRAIL_VGW_PUBLIC_SUBNET=$4

IFMAP_IP=$CONTROLLER1_IP
RABBIT_IP=$CONFIG_IP
OPENSTACK_IP=$CONFIG_IP
SERVICE_HOST=$CONTROLLER1_IP
CONTROL_IP=$CONTROLLER1_IP
USE_DISCOVERY=True
CASSANDRA_IP=$CONFIG_IP
CASSANDRA_IP_LIST=$CONFIG_IP
DNS_IP_LIST=$CONFIG_IP
CONTROL_IP_LIST=("$CONTROLLER1_IP" "$CONTROLLER2_IP")
DISCOVERY_IP=$CONFIG_IP
ZOOKEEPER_IP_LIST=$CONFIG_IP
EOF
}

CONTROLLER1=$( spawn_controller $BOOTSTRAP_ID )
CONTROLLER2=$( spawn_controller $BOOTSTRAP_ID )
# From 10.10.0.0 to 10.210.255.0 to not conflict with VPN routes
PUBLIC_SUBNET=10.$((($RANDOM % 200) + 10)).$((($RANDOM % 255) + 1)).0/24

get_post_install_devstack_config()
{
    CONTROLLER1_IP=$( get_usr_ip $1 )

cat <<EOF

#--------------------------

CASSANDRA_SERVER=$CONTROLLER1_IP
RABBIT_HOST=$CONTROLLER1_IP
KEYSTONE_SERVICE_HOST=$CONTROLLER1_IP
SERVICE_HOST=$CONTROLLER1_IP
MYSQL_HOST=$CONTROLLER1_IP
RABBIT_HOST=$CONTROLLER1_IP
GLANCE_HOSTPORT=$CONTROLLER1_IP:9292
Q_HOST=$CONTROLLER1_IP
ENABLED_SERVICES=n-cpu,n-api-meta,q-meta,neutron
NOVA_VNC_ENABLED=True
NOVNCPROXY_URL="http://$CONTROLLER1_IP:6080/vnc_auto.html"
VNCSERVER_LISTEN=\$HOST_IP
APISERVER_IP=$CONTROLLER1_IP
APISERVER_PORT=8082
VNCSERVER_PROXYCLIENT_ADDRESS=\$VNCSERVER_LISTEN
EOF
}

register_dns $CONTROLLER1
register_dns $CONTROLLER2

wait_for_controller $CONTROLLER1
wait_for_controller $CONTROLLER2
echo Controllers ready !

echo Updating controller configurations
POST_CONFIG=$( get_post_install_config $CONTROLLER1 $CONTROLLER1 $CONTROLLER2 $PUBLIC_SUBNET )
echo -e $POST_CONFIG

ssh_command $CONTROLLER1 "echo -e \"$POST_CONFIG\" >> ~/contrail-installer/localrc"
ssh_command $CONTROLLER1 "cd ~/contrail-installer; ./contrail.sh configure; ./contrail.sh stop; ./contrail.sh restart"

POST_CONFIG=$( get_post_install_config $CONTROLLER1 $CONTROLLER2 $CONTROLLER1 $PUBLIC_SUBNET )
echo -e $POST_CONFIG

ssh_command $CONTROLLER2 "echo -e \"$POST_CONFIG\" >> ~/contrail-installer/localrc"
ssh_command $CONTROLLER2 "cd ~/contrail-installer; ./contrail.sh configure; ./contrail.sh stop; ./contrail.sh restart"

ssh_command $CONTROLLER1 "echo -e \"CASSANDRA_SERVER=$( get_usr_ip $CONTROLLER1 )\" >> ~/devstack/localrc && cd ~/devstack && ./stack.sh"
POST_CONFIG=$( get_post_install_devstack_config $CONTROLLER1 )
ssh_command $CONTROLLER2 "echo -e \"$POST_CONFIG\" >> ~/devstack/localrc && cd ~/devstack && ./stack.sh"

# Public subnet creation
ssh_command $CONTROLLER1 "cd ~/devstack && . openrc admin admin && neutron net-create --router:external --shared public && neutron subnet-create public $PUBLIC_SUBNET"
sudo ip route add $PUBLIC_SUBNET via $(get_adm_ip $CONTROLLER1)

echo $BOOTSTRAP_ID $(date +%F-%H:%M:%S) $CONTROLLER1 $CONTROLLER2 $PUBLIC_SUBNET >> bootstraped
echo Done
