#!/bin/bash

## This contains the majority of the functions required to
## get the system to a state where ansible and python is available

#function config_err_msg () {
#    cat << EOH >&2
#  There was an error finding the full path to the qubinode-installer project directory.
#EOH
#}
#
## this function just make sure the script
## knows the full path to the project directory
## and runs the config_err_msg if it can't determine
## that start_deployment.conf can find the project directory
#function setup_required_paths () {
#    project_dir="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
#
#    if [ ! -d "${project_dir}/playbooks/vars" ] ; then
#        printf "%s\n" "  ${red:?}There was an error finding the full path to the qubinode-installer project directory${end:?}"
#    fi
#}


##---------------------------------------------------------------------
## Functions for setting up sudoers
##---------------------------------------------------------------------
function setup_sudoers () 
{
   local __admin_pass="$1"
   sudo -k
   if ! prompt=$(sudo -n ls 2>&1)
   then
       printf "%s\n" ""
       printf "%s\n" "  ${blu:?}Setup Sudoers${end:?}"
       printf "%s\n" "  ${blu:?}***********************************************************${end:?}"
       printf "%s\n" "  The qubinode-installer runs as a normal user. It sets up your username {ADMIN_USER}"
       printf "%s\n" "  for passwordless sudo."
       printf "%s\n" ""
       SUDOERS_TMP=$(mktemp)
       echo "${ADMIN_USER} ALL=(ALL) NOPASSWD:ALL" > "${SUDOERS_TMP}"
       echo "$__admin_pass" | sudo -S test -f "/etc/sudoers.d/${ADMIN_USER}" > /dev/null 2>&1
       echo "$__admin_pass" | sudo -S cp "${SUDOERS_TMP}" "/etc/sudoers.d/${ADMIN_USER}" > /dev/null 2>&1
       echo "$__admin_pass" | sudo -S chmod 0440 "/etc/sudoers.d/${ADMIN_USER}" > /dev/null 2>&1
   fi

   # check again
   if ! prompt=$(sudo -n ls 2>&1)
   then
       printf "%s\n" "Setting up passwordless sudo for $ADMIN_USER was unsuccessful"
       printf "%s\n" "Error msg: $prompt"
       exit 1
   fi
}


##---------------------------------------------------------------------
## Get Storage Information
##---------------------------------------------------------------------
function getPrimaryDisk () 
{
    primary_disk="${PRIMARY_DISK:-none}"
    if [ "A${primary_disk}" == "Anone" ]
    then
        if which lsblk >/dev/null 2>&1
        then
            declare -a DISKS=()
            dev=$(eval "$(lsblk -oMOUNTPOINT,PKNAME -P| \
		    grep 'MOUNTPOINT="/"')"; echo "${PKNAME//[0-9]*/}") 
                #grep 'MOUNTPOINT="/"')"; echo "$PKNAME" | sed 's/[0-9]*$//')
            if [ "A${dev}" != "A" ]
            then
               primary_disk="$dev"
	    fi
        fi
    fi

    ## get all available disk
    mapfile -t DISKS < <(lsblk -dp | \
        grep -o '^/dev[^ ]*'|awk -F'/' '{print $3}' | \
        grep -v "${primary_disk}")
    ALL_DISK="${DISKS[*]}"
}


## Came across this Gist that provides the functions tonum and toaddr
## # https://gist.githubusercontent.com/cskeeters/278cb27367fbaa21b3f2957a39087abf/raw/9cb338b28d041092391acd78e451a45d31a1917e/broadcast_calc.sh

function toaddr () 
{
    b1=$(( ($1 & 0xFF000000) >> 24))
    b2=$(( ($1 & 0xFF0000) >> 16))
    b3=$(( ($1 & 0xFF00) >> 8))
    b4=$(( $1 & 0xFF ))

    ## the echo exist to resolv SC2034
    echo "$b1 $b2 $b3 $b4" >/dev/null
    eval "$2=\$b1.\$b2.\$b3.\$b4"
}

function tonum () 
{
    if [[ $1 =~ ([[:digit:]]+)\.([[:digit:]]+)\.([[:digit:]]+)\.([[:digit:]]+) ]]; then
	# shellcheck disable=SC2034 #addr var is valid
        #addr=$(( (${BASH_REMATCH[1]} << 24) + (${BASH_REMATCH[2]} << 16) + (${BASH_REMATCH[3]} << 8) + ${BASH_REMATCH[4]} ))
        addr=$(( BASH_REMATCH[1] << 24 + BASH_REMATCH[2] << 16 + BASH_REMATCH[3] << 8 + BASH_REMATCH[4] ))
        eval "$2=\$addr"
    fi
}


function return_netmask_ipaddr ()
{
    if [[ $1 =~ ^([0-9\.]+)/([0-9]+)$ ]]; then
        # CIDR notation
        IPADDR=${BASH_REMATCH[1]}
        NETMASKLEN=${BASH_REMATCH[2]}
        zeros=$((32-NETMASKLEN))
        NETMASKNUM=0
        for (( i=0; i<zeros; i++ )); do
            NETMASKNUM=$(( (NETMASKNUM << 1) ^ 1 ))
        done
        NETMASKNUM=$((NETMASKNUM ^ 0xFFFFFFFF))
        toaddr $NETMASKNUM NETMASK
    else
        IPADDR=${1:-192.168.1.1}
        NETMASK=${2:-255.255.255.0}
    fi

    tonum "$IPADDR" IPADDRNUM
    tonum "$NETMASK" NETMASKNUM
    NETWORKNUM=$(( IPADDRNUM & NETMASKNUM ))
    toaddr "$NETWORKNUM" NETWORK
}

##---------------------------------------------------------------------
## Get network information
##---------------------------------------------------------------------
function get_primary_interface () 
{
    ## Default Vars
    netdevice="${NETWORK_DEVICE:-none}"
    ipaddress="${IPADDRESS:-none}"
    gateway="${GATEWAY:-none}"
    network="${NETWORK:-none}"
    macaddr="${MACADDR:-none}"
    netmask="${NETMASK:-none}"
    reverse_zone="${REVERSE_ZONE:-none}"
    confirm_networking="${CONFIRM_NETWORKING:-yes}"

    ## Get all interfaces except wireless and bridge
    declare -a INTERFACES=()
    mapfile -t INTERFACES < <(ip link | \
	    awk -F: '$0 !~ "lo|vir|wl|^[^0-9]"{print $2;getline}'|\
	    sed -e 's/^[[:space:]]*//')
    # shellcheck disable=SC2034 
    ALL_INTERFACES="${INTERFACES[*]}"

    ## Get primary network device
    ## Get ipaddress, netmask, netmask cidr prefix
    if [ "A${netdevice}" == "Anone" ]
    then
        netdevice=$(ip route get 8.8.8.8 | awk -- '{printf $5}')
        IPADDR_NETMASK=$(ip -o -f inet addr show "$netdevice" | awk '/scope global/ {print $4}')
        # shellcheck disable=SC2034 
        NETMASK_PREFIX=$(echo "$IPADDR_NETMASK" | awk -F'/' '{print $2}')
        ## Return netmask and ipaddress
        return_netmask_ipaddr "$IPADDR_NETMASK"
    fi

    ## Set ipaddress varaible
    if [ "A${ipaddress}" == "Anone" ]
    then
        ipaddress="${IPADDR}"
    fi

    ## Set netmask address
    if [ "A${netmask}" == "Anone" ]
    then
        netmask="${NETMASK}"
    fi

    ## set gateway
    if [ "A${gateway}" == "Anone" ]
    then
        gateway=$(ip route get 8.8.8.8 | awk -F"via " 'NR==1{split($2,a," ");print a[1]}')
    fi

    ## network 
    if [ "A${network}" == "Anone" ]
    then
        network="$NETWORK"
    fi

    ## reverse zone
    if [ "A${reverse_zone}" == "Anone" ]
    then
        reverse_zone=$(echo "$network" | awk -F . '{print $4"."$3"."$2"."$1".in-addr.arpa"}'| sed 's/^[^.]*.//g')
    fi

    ## mac address
    if [ "A${macaddr}" == "Anone" ]
    then
        macaddr=$(ip addr show "$netdevice" | grep link | awk '{print $2}' | head -1)
    fi

    ## Verify networking
    if [ "A${confirm_networking}" == "Ayes" ]
    then
        verify_networking
    fi
}

function verify_networking () {
    printf "%s\n\n" ""
    printf "%s\n" "  ${blu:?}Networking Details${end:?}"
    printf "%s\n" "  ${blu:?}***********************************************************${end:?}"
    printf "%s\n\n" "  The below networking information was discovered and will be used for setting a bridge network."
    
    printf "%s\n" "  ${blu:?}NETWORK_DEVICE${end:?}=${cyn:?}${netdevice:?}${end:?}"
    printf "%s\n" "  ${blu:?}IPADDRESS${end:?}=${cyn:?}${ipaddress:?}${end:?}"
    printf "%s\n" "  ${blu:?}GATEWAY${end:?}=${cyn:?}${gateway:?}${end:?}"
    printf "%s\n" "  ${blu:?}NETMASK${end:?}=${cyn:?}${netmask:?}${end:?}"
    printf "%s\n" "  ${blu:?}NETWORK${end:?}=${cyn:?}${network:?}${end:?}"
    printf "%s\n\n" "  ${blu:?}MACADDR${end:?}=${cyn:?}${macaddr:?}${end:?}"
    confirm "  Would you like to change these details? ${cyn:?}yes/no${end:?}"
    if [ "A${response}" == "Ayes" ]
    then
        printf "%s\n\n" "  ${blu:?}Choose a attribute to change: ${end:?}"
        tmp_file=$(mktemp)
        while true
        do
            networking_opts=("netdevice - ${cyn:?}${netdevice:?}${end:?}" \
                             "ipaddress - ${cyn:?}${ipaddress:?}${end:?}" \
                             "gateway   - ${cyn:?}${gateway:?}${end:?}" \
                             "network   - ${cyn:?}${network:?}${end:?}" \
                             "netmask   - ${cyn:?}${netmask:?}${end:?}" \
                             "macaddr   - ${cyn:?}${macaddr:?}${end:?}" \
                             "Reset     - Revert changes" \
                             "Save      - Save changes")
            createmenu "${networking_opts[@]}"
            result=$(echo "${selected_option}"| awk '{print $1}')
            case $result in
                netdevice)
            	    echo "netdevice=$netdevice" >> "$tmp_file"
                    confirm_correct "Enter the network interface" netdevice
                    ;;
                ipaddress)
            	    echo "ipaddress=$ipaddress" >> "$tmp_file"
                    confirm_correct "Enter ip address to assign to ${netdevice}" ipaddress
                    ;;
                gateway)
            	    echo "gateway=$gateway" >> "$tmp_file"
                    confirm_correct "Enter gateway address to assign to ${netdevice}" gateway
                    ;;
                network)
            	    echo "network=$network" >> "$tmp_file"
                    confirm_correct "Enter the netmask cidr for ip ${ipaddress}" network
                    ;;
                macaddr)
            	    echo "macaddr=$macaddr" >> "$tmp_file"
                    confirm_correct "Enter the mac address assocaited with ${netdevice}" macaddr
                    ;;
                Reset)
		    # shellcheck disable=SC1091
		    # shellcheck source="$tmp_file"
            	    source "$tmp_file"
            	    echo > "$tmp_file"
                    ;;
                Save) 
                    confirm_networking=no
                    break
            	;;
                * ) 
                    echo "Please answer a valid choice"
            	;;
            esac
        
        done
    else
        confirm_networking=no
    fi
}

##---------------------------------------------------------------------
## Check for RHSM registration
##---------------------------------------------------------------------
function pre_os_check () {
    # shellcheck disable=SC2034
    rhel_release=$(< /etc/redhat-release grep -o "[7-8].[0-9]")
    # shellcheck disable=SC2034
    rhel_major=$(sed -rn 's/.*([0-9])\.[0-9].*/\1/p' /etc/redhat-release)
    os_name=$(awk -F= '/^NAME/{print $2}' /etc/os-release)
    if [ "A${os_name}" == 'A"Red Hat Enterprise Linux"' ]
    then
	RHSM_SYSTEM=yes
        if ! which subscription-manager > /dev/null 2>&1
        then
            printf "%s\n" ""
            printf "%s\n" " ${red:?}Error: subcription-manager command not found.${end:?}"
            printf "%s\n" " ${red:?}The subscription-manager command is required.${end:?}"
	    exit 1
	fi
    else
        RHSM_SYSTEM=no
    fi
}

	    
function check_rhsm_status () {
    ## define message var
    local system_registered_msg
    if [ "A${RHSM_SYSTEM-}" == 'Ayes' ]
    then
        printf "%s\n" ""
        printf "%s\n" "  ${blu:?}Confirming System Registration Status${end:?}"
        printf "%s\n" "  ${blu:?}***********************************************************${end:?}"
	if sudo subscription-manager status | grep -q 'Overall Status: Current'
        then
	    SYSTEM_REGISTERED=yes
	    system_registered_msg="$(hostname) is registered to Red Hat"
	else
	    SYSTEM_REGISTERED=no
	    system_registered_msg="$(hostname) is not registered to Red Hat"
        fi
    fi
    printf "%s\n" "  ${yel:?}${system_registered_msg}${end:?}"
}

function verify_rhsm_status () {
   
   ## Ensure the system is registered
   sudo subscription-manager identity > /dev/null 2>&1
   sub_identity_status="$?"
   if [ "A${sub_identity_status}" == "A1" ]
   then
       ## Register system to Red Hat
       register_system
   fi

   ## Ensure the system status is current
   status_result=$(mktemp)
   # shellcheck disable=SC2024
   sudo subscription-manager status > "${status_result}" 2>&1
   #sub_status=$(awk -F: '/Overall Status:/ {print $2}' "${status_result}"|sed 's/^ *//g')
   if [ "A${status}" != "ACurrent" ]
   then
       sudo subscription-manager refresh > /dev/null 2>&1
       sudo subscription-manager attach --auto > /dev/null 2>&1
   fi

   #check again
   # shellcheck disable=SC2024
   sudo subscription-manager status > "${status_result}" 2>&1
   status=$(awk -F: '/Overall Status:/ {print $2}' "${status_result}"|sed 's/^ *//g')
   if [ "A${status}" != "ACurrent" ]
   then
       printf "%s\n" " ${red:?}Cannot determine the subscription status of ${end:?}${cyn:?}$(hostname)${end:?}"
       printf "%s\n" " ${red:?}Error details are:${end:?} "
       cat "${status_result}"
       printf "%s\n\n" " Please resolved and try again"
       exit 1
   else
       printf "%s\n\n" "  ${yel:?}Successfully registered $(hostname) to RHSM${end:?}"
   fi
}

function register_system () {

    if [ "A${RHSM_SYSTEM}" == "Ayes" ] && [ "A${SYSTEM_REGISTERED}" == "Ano" ]
    then
        printf "%s\n\n" ""
        printf "%s\n" "  ${blu:?}***********************************************************${end:?}"
        printf "%s\n" "  ${blu:?}RHSM Registration${end:?}"
        rhsm_reg_result=$(mktemp)
        echo sudo subscription-manager register \
    	      "${RHSM_CMD_OPTS}" --force \
    	      --release="'${RHEL_RELEASE-}'"|\
    	      sh > "${rhsm_reg_result}" 2>&1
        RESULT="$?"
        if [ ${RESULT} -eq 0 ]
        then
            verify_rhsm_status
	    SYSTEM_REGISTERED="yes"
    	else
    	    printf "%s\n" " ${red:?}$(hostname) registration to RHSM was unsuccessfull.${end:?}"
            cat "${rhsm_reg_result}"
	    exit 1
        fi
    fi
}


##---------------------------------------------------------------------
## Get User Input
##---------------------------------------------------------------------
function confirm_menu_option () 
{
    entry_is_correct=""
    local __input_array="$1"
    local __input_question=$2
    local __resultvar="$3"
    local data_array
    IFS=" " read -r -a data_array <<< "$__input_array"
    #mapfile -t data_array <<< $__input_array
    #data_array=( "$__input_array" )

    while [[ "${entry_is_correct}" != "yes" ]];
    do
        ## Get input from user
	printf "%s\n" " ${__input_question}"
        createmenu "${data_array[@]}"
        user_choice=$(echo "${selected_option}"|awk '{print $1}')
        if [[ "$__resultvar" ]]; then
	    result="'$user_choice'"
            eval "$__resultvar"="$result"
            #eval "$__resultvar"="'$user_choice'"
        else
            echo "$user_choice"
        fi

        read -r -p "  You entered ${cyn:?}$user_choice${end:?}, is this correct? ${cyn:?}yes/no${end:?} " response
        if [[ $response =~ ^([yy][ee][ss]|[yy])$ ]]
        then
            entry_is_correct="yes"
        fi
    done
}

## confirm with user if they want to continue
function confirm () {
    continue=""
    while [[ "${continue}" != "yes" ]];
    do
        read -r -p "${1:-are you sure yes or no?} " response
        if [[ $response =~ ^([yy][ee][ss]|[yy])$ ]]
        then
            response="yes"
            continue="yes"
        elif [[ $response =~ ^([nn][oo])$ ]]
        then
            #echo "you choose $response"
            response="no"
            continue="yes"
        else
            printf "%s\n" " ${blu:?}try again!${end:?}"
        fi
    done
}

## accept input from user and return the input
function accept_user_input ()
{
    local __questionvar="$1"
    local __resultvar="$2"
    echo -n "  ${__questionvar} and press ${cyn:?}[ENTER]${end:?}: "
    read -r input_from_user
    local output_data="$input_from_user"
    local result

    if [[ "$__resultvar" ]]; then
	result="'$output_data'"
        eval "$__resultvar"="$result"
        #eval "$__resultvar"="'$output_data'"
    else
        echo "$output_data"
    fi
}

## confirm if input is correct
function confirm_correct () {
    entry_is_correct=""
    local __user_question=$1
    local __resultvar=$2
    user_input_data=""
    local result

    while [[ "${entry_is_correct}" != "yes" ]];
    do
	## Get input from user
        accept_user_input "$__user_question" user_input_data
        if [[ "$__resultvar" ]]; then
	    result="'$user_input_data'"
            eval "$__resultvar"="$result"
            #eval "$__resultvar"="'$user_input_data'"
        else
            echo "$user_input_data"
        fi

	read -r -p "  You entered ${cyn:?}$user_input_data${end:?}, is this correct? ${cyn:?}yes/no${end:?} " response
        if [[ $response =~ ^([yy][ee][ss]|[yy])$ ]]
        then
            entry_is_correct="yes"
	fi
    done
}

# generic user choice menu
# this should eventually be used anywhere we need
# to provide user with choice
function createmenu () {
    select selected_option; do # in "$@" is the default
        if ! [[ "$REPLY" =~ ^[0-9]+$ ]]
        then 
	    REPLY=80
        fi
        if [ $REPLY -eq $REPLY ]
        #if [ $REPLY -eq $REPLY 2>/dev/null ]
        then
            if [ 1 -le "$REPLY" ] && [ "$REPLY" -le $(($#)) ]; then
                break;
            else
                echo "    ${blu:?}Please make a vaild selection (1-$#).${end:?}"
            fi
         else
            echo "    ${blu:?}Please make a vaild selection (1-$#).${end:?}"
         fi
    done
}

# this configs prints out asterisks when sensitive data
# is being entered
function read_sensitive_data () {
    # based on shorturl.at/BEHY3
    sensitive_data=''
    while IFS= read -r -s -n1 char; do
      [[ -z $char ]] && { printf '\n'; break; } # ENTER pressed; output \n and break.
      if [[ $char == $'\x7f' ]]; then # backspace was pressed
          # Remove last char from output variable.
          [[ -n $sensitive_data ]] && sensitive_data=${sensitive_data%?}
          # Erase '*' to the left.
          printf '\b \b'
      else
        # Add typed char to output variable.
        sensitive_data+=$char
        # Print '*' in its stead.
        printf '*'
      fi
    done
}

function load_vault_vars () 
{
    vault_parse_cmd="cat"
    if which ansible-vault >/dev/null 2>&1
    then
        if ansible-vault view "${VAULT_FILE}" >/dev/null 2>&1
        then
	    vault_parse_cmd="ansible-vault view"
	fi
    fi

    if [ -f "${VAULT_FILE}" ]
    then
        RHSM_USERNAME=$($vault_parse_cmd "${VAULT_FILE}" | awk '/^rhsm_username:/ {print $2}')
        RHSM_PASSWORD=$($vault_parse_cmd "${VAULT_FILE}" | awk '/^rhsm_password:/ {print $2}')
        RHSM_ORG=$($vault_parse_cmd "${VAULT_FILE}" | awk '/^rhsm_org:/ {print $2}')
        RHSM_ACTKEY=$($vault_parse_cmd "${VAULT_FILE}" | awk '/^rhsm_activationkey:/ {print $2}')
        ADMIN_USER_PASS=$($vault_parse_cmd "${VAULT_FILE}" | awk '/^admin_user_password:/ {print $2}')

	# shellcheck disable=SC2034 # used when vault file is generated
        IDM_DM_PASS=$($vault_parse_cmd "${VAULT_FILE}" | awk '/^idm_dm_pwd:/ {print $2}')
        IDM_ADMIN_PASS=$($vault_parse_cmd "${VAULT_FILE}" | awk '/^idm_admin_pwd:/ {print $2}')
	
	# shellcheck disable=SC2034 # used when vault file is generated
        TOWER_PG_PASS=$($vault_parse_cmd "${VAULT_FILE}" | awk '/^tower_pg_password:/ {print $2}')
        
	# shellcheck disable=SC2034 # used when vault file is generated
	TOWER_MQ_PASS=$($vault_parse_cmd "${VAULT_FILE}" | awk '/^tower_rabbitmq_password:/ {print $2}')
        #IDM_USER_PASS=$($vault_parse_cmd "${VAULT_FILE}" | awk '/^idm_admin_pwd:/ {print $2}')
    fi
}

function rhsm_get_reg_method () {
    local user_response
    printf "%s\n\n" ""
    printf "%s\n" "  ${blu:?}***********************************************************${end:?}"
    printf "%s\n\n" "  ${blu:?}Red Hat Subscription Registration${end:?}"

    printf "%s\n" "  Your credentials for access.redhat.com is needed."
    printf "%s\n" "  RHSM registration has two methods:"
    printf "%s\n" "     option 1: ${cyn:?}activation key${end:?}"
    printf "%s\n\n" "     option 2: ${cyn:?}username/password${end:?}"
    printf "%s\n\n" "  Option 2 is the most commonly used"
    printf "%s\n" "  ${blu:?}Choose a registration method${end:?}"
    rhsm_msg=("Activation Key" "Username and Password")
    createmenu "${rhsm_msg[@]}"
    user_response="${selected_option}"
    RHSM_REG_METHOD=$(echo "${user_response}"|awk '{print $1}')
}

function accept_sensitive_input () {
    printf "%s\n" ""
    printf "%s\n" "  Try not to ${cyn:?}Backspace${end:?} to correct a typo, "
    printf "%s\n\n" "  you will be prompted again if the input does not match."
    while true
    do
        printf "%s" "  $MSG_ONE"
        read_sensitive_data
        USER_INPUT1="${sensitive_data}"
        printf "%s" "  $MSG_TWO"
        read_sensitive_data
        USER_INPUT2="${sensitive_data}"
        if [ "$USER_INPUT1" == "$USER_INPUT2" ] 
        then
	    sensitive_data="$USER_INPUT2"
	    break
	fi
        printf "%s\n"  "  ${cyn:?}Please try again${end:?}: "
        printf "%s\n" ""
    done
}

        
function rhsm_credentials_prompt () {

    rhsm_reg_method="${RHSM_REG_METHOD:-none}"
    rhsm_username="${RHSM_USERNAME:-none}"
    rhsm_password="${RHSM_PASSWORD:-none}"
    rhsm_org="${RHSM_ORG:-none}"
    rhsm_actkey="${RHSM_ACTKEY:-none}"
    if [ "A${rhsm_reg_method}" == "AUsername" ]
    then
        if [ "A${rhsm_username}" == "Anone" ]
        then
            printf "%s\n" ""
	    confirm_correct "Enter your RHSM username and press" RHSM_USERNAME
        fi

        if [ "A${rhsm_password}" == 'Anone' ]
        then
	    MSG_ONE="Enter your RHSM password and press ${cyn:?}[ENTER]${end:?}:"
            MSG_TWO="Enter your RHSM password password again ${cyn:?}[ENTER]${end:?}:"
	    accept_sensitive_input
            RHSM_PASSWORD="${sensitive_data}"
        fi

	## set registration argument
	RHSM_CMD_OPTS="--username=${RHSM_USERNAME} --password=${RHSM_PASSWORD}"
    fi

    if [ "A${rhsm_reg_method}" == "AActivation" ]
    then
        if [ "A${rhsm_org}" == 'Anone' ]
        then
            printf "%s\n\n" ""
	    MSG_ONE="Enter your RHSM org id and press ${cyn:?}[ENTER]${end:?}:"
            MSG_TWO="Enter your RHSM org id again ${cyn:?}[ENTER]${end:?}:"
	    accept_sensitive_input
            RHSM_ORG="${sensitive_data}"
        fi

        if [ "A${rhsm_actkey}" == 'Anone' ]
        then
	    confirm_correct "Enter your RHSM activation key" RHSM_ACTKEY
        fi

	## Set registration argument
	RHSM_CMD_OPTS="--org=${RHSM_ORG} --activationkey=${RHSM_ACTKEY}"
    fi
}

function ask_user_for_rhsm_credentials () {
    rhsm_reg_method="${RHSM_REG_METHOD:-none}"

    if [ "A${rhsm_reg_method}" == "Anone" ]
    then
	rhsm_get_reg_method
        rhsm_credentials_prompt
    else
        rhsm_credentials_prompt
    fi
}

function ask_for_admin_user_pass () {
    admin_user_password="${ADMIN_USER_PASS:-none}"
    # root user password to be set for virtual instances created
    if [ "A${admin_user_password}" == "Anone" ]
    then
        printf "%s\n\n" ""
        printf "%s\n" "  Admin User Credentials"
	printf "%s\n" "  ${blu:?}***********************************************************${end:?}"
        printf "%s\n" "  Your username ${cyn:?}${ADMIN_USER}${end:?} will be used to ssh into all the VMs created."

        MSG_ONE="Enter a password for ${cyn:?}${ADMIN_USER}${end:?} ${blu:?}[ENTER]${end:?}:"
        MSG_TWO="Enter a password again for ${cyn:?}${ADMIN_USER}${end:?} ${blu:?}[ENTER]${end:?}:"
        accept_sensitive_input
        admin_user_password="$sensitive_data"
    fi
}

function check_additional_storage () {
    getPrimaryDisk
    create_libvirt_lvm="${CREATE_LIBVIRT_LVM:-yes}"
    libvirt_pool_disk="${LIBVIRT_POOL_DISK:-none}"
    libvirt_dir_verify="${LIBVIRT_DIR_VERIFY:-none}"
    libvirt_dir="${LIBVIRT_DIR:-/var/lib/libvirt/images}"
    LIBVIRT_DIR="${LIBVIRT_DIR:-$libvirt_dir}"

    # confirm directory for libvirt images
    if [ "A${libvirt_dir_verify}" != "Ano" ]
    then
        printf "%s\n\n" ""
        printf "%s\n" "  ${blu:?}***********************************************************${end:?}"
        printf "%s\n\n" "  ${blu:?}Location for Libvirt directory Pool${end:?}"
        printf "%s\n" "  The current path is set to ${cyn:?}$libvirt_dir${end:?}."
        printf "%s\n" ""
        confirm "  Do you want to change it? ${blu:?}yes/no${end:?}"
        if [ "A${response}" == "Ayes" ]
        then
	    confirm_correct "Enter a new path" LIBVIRT_DIR
	fi
        libvirt_dir_verify=no
    fi

    if [[ "A${create_libvirt_lvm}" == "Ayes" ]] && [[ "A${libvirt_pool_disk}" == "Anone" ]]
    then
        printf "%s\n\n" ""
        printf "%s\n" "  ${blu:?}***********************************************************${end:?}"
        printf "%s\n\n" "    ${blu:?}Dedicated Storage Device For Libvirt Directory Pool${end:?}"
        printf "%s\n" "   It is recommended to dedicate a disk to ${cyn:?}$LIBVIRT_DIR${end:?}."
        printf "%s\n" "   Qubinode uses libvirt directory pool for VM disk storage"
        printf "%s\n" ""

	local AVAILABLE_DISKS
	IFS=" " read -r -a AVAILABLE_DISKS <<< "$ALL_DISK"
        if [ ${#AVAILABLE_DISKS[@]} -gt 1 ]
        then
            printf "%s\n" "   Your primary storage device appears to be ${blu:?}${primary_disk}${end:?}."
            printf "%s\n\n" "   The following additional storage devices where found:"

            for disk in "${AVAILABLE_DISKS[@]}"
            #for disk in $(echo "${AVAILABLE_DISKS[@]}")
            do
                printf "%s\n" "     ${blu:?} * ${end:?}${blu:?}$disk${end:?}"
            done
        fi


        confirm "   Do you want to dedicate a storage device: ${blu:?}yes/no${end:?}"
        printf "%s\n" " "
        if [ "A${response}" == "Ayes" ]
        then
            disk_msg="Please select secondary disk to be used"
            confirm_menu_option "${AVAILABLE_DISKS[*]}" "$disk_msg" libvirt_pool_disk
            LIBVIRT_POOL_DISK="$libvirt_pool_disk"
            CREATE_LIBVIRT_LVM=yes
	else
            LIBVIRT_POOL_DISK="none"
            CREATE_LIBVIRT_LVM=no
        fi
    fi
}

function ask_idm_password () {
    idm_admin_pass="${IDM_ADMIN_PASS:=none}"
    if [ "A${idm_admin_pass}" == "Anone" ]
    then
        printf "%s\n" ""
        MSG_ONE="Enter a password for the IdM server ${cyn:?}${idm_server_hostname}${end:?} ${blu:?}[ENTER]${end:?}:"
        MSG_TWO="Enter a password again for the IdM server ${cyn:?}${idm_server_hostname}${end:?} ${blu:?}[ENTER]${end:?}:"
        accept_sensitive_input
        # shellcheck disable=SC2034
        idm_admin_pwd="${sensitive_data}"
    fi
}

function set_idm_static_ip () {
    printf "%s\n" ""
    confirm_correct "$static_ip_msg" idm_server_ip
    if [ "A${idm_server_ip}" != "A" ]
    then
        printf "%s\n" "  The qubinode-installer will connect to the IdM server on ${cyn:?}$idm_server_ip${end:?}"
    fi
}


function ask_about_domain() 
{
    domain_tld="${DOMAIN_TLD:-lan}"
    generated_domain="${ADMIN_USER}.${domain_tld}"
    domain="${DOMAIN:-$generated_domain}"
    confirmed_user_domain="${CONFIRMED_USER_DOMAIN:-yes}"
    confirmation_question=null
    idm_deploy_method="${IDM_DEPLOY_METHOD:-none}"

    if [ "A${confirmed_user_domain}" == "Ayes" ]
    then
        printf "%s\n\n" ""
        printf "%s\n" "  ${blu:?}***********************************************************${end:?}"
        printf "%s\n\n" "  ${blu:?}DNS Domain${end:?}"

        if [[ "A${idm_deploy_method}" == "Ayes" ]]
        then
            confirmation_question="Enter your existing IdM server domain, e.g. example.com"
        else
            printf "%s\n" "   The domain ${cyn:?}${generated_domain}${end:?} was generated for you."
            confirm "   Do you want to change it? ${blu:?}yes/no${end:?}"
            if [ "A${response}" == "Ayes" ]
            then
                confirmation_question="Enter your domain name"
	    else
		confirmed_user_domain=no
	    fi
        fi

        ## Ask user to confirm domain
        if [ "A${confirmation_question}" != "Anull" ]
        then
            confirm_correct "${confirmation_question}" USER_DOMAIN
            if [ "A${USER_DOMAIN}" != "A" ]
            then
	        domain="$USER_DOMAIN"
		confirmed_user_domain=no
            fi
        fi
	
    fi
}

function connect_existing_idm ()
{
    idm_hostname="${generated_idm_hostname:-none}"
    static_ip_msg=" Enter the ip address for the existing IdM server"
    allow_zone_overlap=no
    if [ "A${idm_hostname}" != "Anone" ]
    then
        printf "%s\n\n" ""
        printf "%s\n" "  Please provide the hostname of the existing IdM server."
        printf "%s\n\n" "  For example if you IdM server is ${cyn:?}dns01.lab.com${end:?}, you should enter ${blu:?}dns01${end:?}."
        local existing_msg="Enter the existing DNS server hostname"
	confirm_correct "${existing_msg}" idm_server_hostname

	## Get ip address for Idm server
	get_idm_server_ip

	## get_idm_admin_user
	get_idm_admin_user

	##get user password not working
	ask_idm_password
    fi
}

function get_idm_server_ip () 
{
    if [ "A${idm_server_ip}" == "Anone" ]
    then
        set_idm_static_ip
    fi
}

function get_idm_admin_user ()
{
    ## set idm_admin_user vars
    idm_admin_user="${IDM_ADMIN_USER:-admin}"
    idm_admin_existing_user="${IDM_EXISTING_ADMIN_USER:-none}"

    if [ "A${idm_admin_user}" == "Aadmin" ] && [ "A${idm_admin_existing_user}" == "Anone" ]
    then
        printf "%s\n\n" ""
        local admin_user_msg="What is the admin username for ${cyn:?}${idm_server_hostname}${end:?}?"
	confirm_correct "$admin_user_msg" idm_admin_existing_user
	idm_admin_user="$idm_admin_existing_user"
    fi
}


function ask_about_idm ()
{
    ## Default variables
    idm_server_ip="${IDM_SERVER_IP:-none}"
    allow_zone_overlap="${ALLOW_ZONE_OVERLAP:-none}"
    deploy_idm="${DEPLOY_IDM:-yes}"
    idm_deploy_method="${IDM_DEPLOY_METHOD:-none}"
    idm_choices="deploy existing"
    idm_hostname_prefix="${IDM_HOSTNAME_PREFIX:-idm01}"
    idm_server_hostname="${IDM_SERVER_HOSTNAME:-none}"
    name_prefix="${name_prefix:-qbn}"

    ## set hostname
    if [ "A${idm_server_hostname}" == "Anone" ]
    then
        generated_idm_hostname="${name_prefix}-${idm_hostname_prefix}"
	idm_server_hostname="$generated_idm_hostname"
    fi

    ## Should IdM be deployed
    if [ "A${deploy_idm}" == "Ayes" ] && [ "A${idm_deploy_method}" == "Anone" ]
    then
        printf "%s\n" "  ${blu:?}***********************************************************${end:?}"
        printf "%s\n\n" "  ${blu:?}Red Hat Identity Manager (IdM)${end:?}"

	if [ "A${idm_deploy_method}" == "Anone" ]
	then
	    ## FOR FUTURE USE
            ##printf "%s\n" "  CoreDNS is deployed is the default DNS server deployed."
            ##printf "%s\n" "  If you would like to have access to LDAP, then you can deploy"
	    ##printf "%s\n" "  Red Hat Identity manager (IdM)"
            printf "%s\n" "  IdM is use as the dns server for all qubinode dns needs."
            printf "%s\n\n" "  The installer can ${cyn:?}deploy${end:?} a local IdM server or connect to an ${cyn:?}existing${end:?} IdM server."
            idm_msg="Do you want to ${cyn:?}deploy${end:?} a new IdM or connect to an ${cyn:?}existing${end:?}? "
            confirm_menu_option "${idm_choices}" "${idm_msg}" idm_deploy_method
        fi

	## check idm setup method
	case "$idm_deploy_method" in
	    deploy)
		deploy_new_idm
	        ;;
	    existing)
		connect_existing_idm
	        ;;
	    *)
                #echo nothing > /dev/null
		break
		;;
	esac
    fi
}

function deploy_new_idm ()
{
    if [ "A${idm_server_ip}" == "Anone" ]
    then
        printf "%s\n" ""
        printf "%s\n" "  The IdM server will be assigned a dynamic ip address from"
        printf "%s\n\n" "  your network. You can assign a static ip address instead."
        confirm "  Would you like to assign a static ip address to the IdM server? ${cyn:?}yes/no${end:?}"
        if [ "A${response}" == "Ayes" ]
        then
            static_ip_msg=" Enter the ip address you would like to assign to the IdM server"
            set_idm_static_ip
        fi
    fi

    if [ "A${allow_zone_overlap}" == "Anone" ]
    then
        printf "%s\n" ""
        printf "%s\n\n" " ${blu:?} You can safely choose no for this next question.${end:?}"
        printf "%s\n" "  Choose ${cyn:?}yes${end:?} if ${cyn:?}$domain${end:?} is already in use on your network."
        confirm "  Would you like to enable allow-zone-overlap? ${cyn:?}yes/no${end:?}"
        if [ "A${response}" == "Ayes" ]
        then
             allow_zone_overlap=yes
	else
             allow_zone_overlap=no
        fi
   fi

}

##---------------------------------------------------------------------
## YUM, PIP packages and Ansible roles, collections
##---------------------------------------------------------------------
function install_packages () {

    ## default vars
    _rhel7_packages="python python3-pip python2-pip python-dns"
    _rhel8_repos="rhel-8-for-x86_64-baseos-rpms rhel-8-for-x86_64-appstream-rpms ansible-2-for-rhel-8-x86_64-rpms"
    _yum_packages="python3-pyyaml python3 python3-pip python3-dns ansible git podman python-podman-api toolbox"
    rhel8_repos="${RHEL8_REPOS:-$_rhel8_repos}"
    pip_packages="${PIP_PACKAGES:-yml2json}"
    rhel7_packages="${RHEL7_PACKAGES:-$_rhel7_packages}"
    yum_packages="${YUM_PACKAGES:-$_yum_packages}"

    # install python
    if [ "A${PYTHON3_INSTALLED-}" == "Ano" ] && [ "A${ANSIBLE_INSTALLED-}" == "Ano" ]
    then
        printf "%s\n" "  ${blu:?}***********************************************************${end:?}"
        printf "%s\n\n" "  ${blu:?}Install Packages${end:?}"
        if [[ $rhel_major == "8" ]]
        then
	    ENABLED_REPOS=$(mktemp)
	    # shellcheck disable=SC2024
	    sudo subscription-manager repos --list-enabled > "${ENABLED_REPOS}"
	    for repo in $rhel8_repos
	    do
                if ! grep -q "$repo" "${ENABLED_REPOS}"
		then
	            # shellcheck disable=SC2024
                    sudo subscription-manager repos --enable="${repo}" > /dev/null 2>&1
                fi
            done
	fi

	## RHEL7
        if [[ $rhel_major == "7" ]]
	then
            if [ ! -f /usr/bin/python ]
            then
                printf "%s\n" "   ${yel:?}Installing required rpms..${end:?}"
                sudo yum clean all > /dev/null 2>&1
                sudo yum install -y -q -e 0 "$rhel7_packages" "$yum_packages"> /dev/null 2>&1
            fi
	fi

	 ## Install on RHEL8 and fedora
	 if [[ "A${OS_NAME-}" == "AFedora" ]] || [[ "$rhel_major" == "8" ]]
         then
             printf "%s\n" "   ${blu:?}Installing required python rpms..${end:?}"
             sudo yum clean all > /dev/null 2>&1
             sudo rm -r /var/cache/dnf
             sudo yum install -y -q -e 0 "$yum_packages"> /dev/null 2>&1
	 fi
    fi

    ## check if python3 is installed
    if which python3> /dev/null 2>&1
    then
        PYTHON3_INSTALLED=yes
    else
        PYTHON3_INSTALLED=no
    fi

    ## install pip3 packages
    if which /usr/bin/pip3 > /dev/null 2>&1
    then
	for pkg in $pip_packages
	do
	    if ! pip3 list --format=legacy| grep "$pkg" > /dev/null 2>&1
            then
                /usr/bin/pip3 install "$pkg" --user
	    fi
        done
    fi
}

##---------------------------------------------------------------------
##  MENU OPTIONS
##---------------------------------------------------------------------
function display_help() {
    project_dir="${project_dir:-none}"
    if [ -d "$project_dir" ]
    then
        printf "%s\n" "   ${red:?}Error: could not locate project_dir${end:?}" 
	exit 1
    fi
    cat < "${project_dir}/docs/qubinode/qubinode-menu-options.adoc"
}
