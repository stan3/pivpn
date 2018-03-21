#!/bin/bash
set -eu
. "$(dirname "$0")"/lib.sh

easyrsaVer="3.0.1-pivpn1"
easyrsaRel="https://github.com/pivpn/easy-rsa/releases/download/${easyrsaVer}/EasyRSA-${easyrsaVer}.tgz"
useUpdateVars=false


setCustomProto() {
    local pivpn_dir="$1"
    # Set the available protocols into an array so it can be used with a whiptail dialog
    if protocol=$(whiptail --title "Protocol" --radiolist \
    "Choose a protocol (press space to select). Please only choose TCP if you know why you need TCP." ${r} ${c} 2 \
    "UDP" "" ON \
    "TCP" "" OFF 3>&1 1>&2 2>&3)
    then
        # Convert option into lowercase (UDP->udp)
        pivpnProto="${protocol,,}"
        echo "::: Using protocol: $pivpnProto"
        echo "${pivpnProto}" > /tmp/pivpnPROTO
    else
        echo "::: Cancel selected, exiting...."
        exit 1
    fi
    # write out the PROTO
    PROTO=$pivpnProto
    echo $PROTO > "$pivpn_dir/INSTALL_PROTO"
}


setCustomPort() {
    local pivpn_dir="$1"
    local PORTNumCorrect=false
    until [[ $PORTNumCorrect = True ]]
        do
            portInvalid="Invalid"

            PROTO="$(cat "$pivpn_dir"/INSTALL_PROTO)"
            if [ "$PROTO" = "udp" ]; then
              DEFAULT_PORT=1194
            else
              DEFAULT_PORT=443
            fi
            if PORT=$(whiptail --title "Default OpenVPN Port" --inputbox "You can modify the default OpenVPN port. \nEnter a new value or hit 'Enter' to retain the default" ${r} ${c} $DEFAULT_PORT 3>&1 1>&2 2>&3)
            then
                if [[ "$PORT" =~ ^[0-9]+$ ]] && [ "$PORT" -ge 1 ] && [ "$PORT" -le 65535 ]; then
                    :
                else
                    PORT=$portInvalid
                fi
            else
                echo "::: Cancel selected, exiting...."
                exit 1
            fi

            if [[ $PORT == "$portInvalid" ]]; then
                whiptail --msgbox --backtitle "Invalid Port" --title "Invalid Port" "You entered an invalid Port number.\n    Please enter a number from 1 - 65535.\n    If you are not sure, please just keep the default." ${r} ${c}
                PORTNumCorrect=False
            else
                if (whiptail --backtitle "Specify Custom Port" --title "Confirm Custom Port Number" --yesno "Are these settings correct?\n    PORT:   $PORT" ${r} ${c}) then
                    PORTNumCorrect=True
                else
                    # If the settings are wrong, the loop continues
                    PORTNumCorrect=False
                fi
            fi
        done
    # write out the port
    echo ${PORT} > "$pivpn_dir"/INSTALL_PORT
#    $SUDO cp /tmp/INSTALL_PORT /etc/pivpn/INSTALL_PORT
}


confOpenVPN() {
    local easyrsa_dir="$(realpath "$1")"
    local pivpn_dir="$(realpath "$2")"
    local source_dir="$3"

    setCustomProto "$pivpn_dir"
    setCustomPort "$pivpn_dir"

    # Generate a random, alphanumeric identifier of 16 characters for this server so that we can use verify-x509-name later that is unique for this server installation. Source: Earthgecko (https://gist.github.com/earthgecko/3089509)
    NEW_UUID=$(cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w 16 | head -n 1)
    SERVER_NAME="server_${NEW_UUID}"

    if [[ ${useUpdateVars} == false ]]; then
        # Ask user for desired level of encryption
        ENCRYPT=$(whiptail --backtitle "Setup OpenVPN" --title "Encryption strength" --radiolist \
        "Choose your desired level of encryption (press space to select):\n   This is an encryption key that will be generated on your system.  The larger the key, the more time this will take.  For most applications, it is recommended to use 2048 bits.  If you are testing, you can use 1024 bits to speed things up, but do not use this for normal use!  If you are paranoid about ... things... then grab a cup of joe and pick 4096 bits." ${r} ${c} 3 \
        "1024" "Use 1024-bit encryption (testing only)" OFF \
        "2048" "Use 2048-bit encryption (recommended level)" ON \
        "4096" "Use 4096-bit encryption (paranoid level)" OFF 3>&1 1>&2 2>&3)

        exitstatus=$?
        if [ $exitstatus != 0 ]; then
            echo "::: Cancel selected. Exiting..."
            exit 1
        fi
    fi

    # If easy-rsa exists, remove it
    if [ -d easyrsa_dir ]; then
        rm -rf "$easyrsa_dir"
    fi

    # Get the PiVPN easy-rsa
    wget -q -O - "${easyrsaRel}" | tar xz -C "$(dirname "$easyrsa_dir")" && mv "$(dirname "$easyrsa_dir")"/EasyRSA-${easyrsaVer} "$easyrsa_dir"
    # fix ownership
    # $SUDO chown -R root:root /etc/openvpn/easy-rsa
    # $SUDO mkdir /etc/openvpn/easy-rsa/pki

    # Write out new vars file
    set +e
    IFS= read -d '' String <<"EOF"
if [ -z "$EASYRSA_CALLER" ]; then
    echo "Nope." >&2
    return 1
fi
# set_var EASYRSA            "/etc/openvpn/easy-rsa"
set_var EASYRSA_PKI        "$EASYRSA/pki"
set_var EASYRSA_KEY_SIZE   2048
set_var EASYRSA_ALGO       rsa
set_var EASYRSA_CURVE      secp384r1
EOF

    echo "${String}" | tee "$easyrsa_dir"/vars >/dev/null
    set -e

    # Edit the KEY_SIZE variable in the vars file to set user chosen key size
    cd "$easyrsa_dir" || exit
    sed -i "s/\(KEY_SIZE\).*/\1   ${ENCRYPT}/" vars

    # Remove any previous keys
    EASYRSA="$easyrsa_dir" ./easyrsa --batch init-pki

    # Build the certificate authority
    printf "::: Building CA...\n"
    EASYRSA="$easyrsa_dir" ./easyrsa --batch build-ca nopass
    printf "\n::: CA Complete.\n"

    if [[ ${useUpdateVars} == false ]]; then
        whiptail --msgbox --backtitle "Setup OpenVPN" --title "Server Information" "The server key, Diffie-Hellman key, and HMAC key will now be generated." ${r} ${c}
    fi

    # Build the server
    EASYRSA="$easyrsa_dir" ./easyrsa build-server-full ${SERVER_NAME} nopass

 	  if [[ ${useUpdateVars} == false ]]; then
        if (whiptail --backtitle "Setup OpenVPN" --title "Version 2.4 improvements" --yesno --defaultno "OpenVPN 2.4 brings support for stronger key exchange using Elliptic Curves and encrypted control channel, along with faster LZ4 compression.\n\nIf you your clients do run OpenVPN 2.4 or later you can enable these features, otherwise choose 'No' for best compatibility.\n\nNOTE: Current mobile app, that is OpenVPN connect, is supported." ${r} ${c}); then
            APPLY_TWO_POINT_FOUR=true
            touch "$pivpn_dir"/TWO_POINT_FOUR
        else
            APPLY_TWO_POINT_FOUR=false
        fi
    fi

    if [[ ${useUpdateVars} == false ]]; then
    		if [[ ${APPLY_TWO_POINT_FOUR} == false ]]; then
    		    if ([ "$ENCRYPT" -ge "4096" ] && whiptail --backtitle "Setup OpenVPN" --title "Download Diffie-Hellman Parameters" --yesno --defaultno "Download Diffie-Hellman parameters from a public DH parameter generation service?\n\nGenerating DH parameters for a $ENCRYPT-bit key can take many hours on a Raspberry Pi. You can instead download DH parameters from \"2 Ton Digital\" that are generated at regular intervals as part of a public service. Downloaded DH parameters will be randomly selected from a pool of the last 128 generated.\nMore information about this service can be found here: https://2ton.com.au/dhtool/\n\nIf you're paranoid, choose 'No' and Diffie-Hellman parameters will be generated on your device." ${r} ${c}); then
    		        DOWNLOAD_DH_PARAM=true
    		    else
    		        DOWNLOAD_DH_PARAM=false
    		    fi
    		fi
    fi

  	if [[ ${APPLY_TWO_POINT_FOUR} == false ]]; then
    		if [ "$ENCRYPT" -ge "4096" ] && [[ ${DOWNLOAD_DH_PARAM} == true ]]; then
    		    # Downloading parameters
    		    RANDOM_INDEX=$(( RANDOM % 128 ))
    		    curl "https://2ton.com.au/dhparam/${ENCRYPT}/${RANDOM_INDEX}" -o "$easyrsa_dir/pki/dh${ENCRYPT}.pem"
    		else
    		    # Generate Diffie-Hellman key exchange
    		    EASYRSA="$easyrsa_dir" ./easyrsa gen-dh
    		    mv pki/dh.pem pki/dh${ENCRYPT}.pem
    		fi
  	fi

    # Generate static HMAC key to defend against DDoS
    openvpn --genkey --secret pki/ta.key

    # Generate an empty Certificate Revocation List
    EASYRSA="$easyrsa_dir" ./easyrsa gen-crl
    # cp pki/crl.pem "$openvpn_dir"/crl.pem
    # ${SUDOE} chown nobody:nogroup /etc/openvpn/crl.pem

    pwd
    # Write config file for server using the template .txt file
    cp "$source_dir"/server_config.txt "$pivpn_dir"/server.conf

   
    local dh_file="pki/dh${ENCRYPT}.pem"
  	if [[ ${APPLY_TWO_POINT_FOUR} == true ]]; then
  		  #If they enabled 2.4 change compression algorithm and use tls-crypt instead of tls-auth to encrypt control channel
  		  sed -i "s/comp-lzo/compress lz4/" "$pivpn_dir"/server.conf
        # dh_file="pki/dh${ENCRYPT}.pem"
  	fi

    # if they modified port put value in server.conf
    if [ $PORT != 1194 ]; then
        sed -i "s/1194/${PORT}/g" "$pivpn_dir"/server.conf
    fi

    # if they modified protocol put value in server.conf
    if [ "$PROTO" != "udp" ]; then
        sed -i "s/proto udp/proto tcp/g" "$pivpn_dir"/server.conf
    fi

    catOVPNInline "$easyrsa_dir" "$pivpn_dir" "$SERVER_NAME" "$dh_file" >> "$pivpn_dir"/server.conf
}

confOVPN() {
    local source_dir="$1"
    local pivpn_dir="$2"
    if ! IPv4pub=$(dig +short myip.opendns.com @resolver1.opendns.com)
    then
        echo "dig failed, now trying to curl eth0.me"
        if ! IPv4pub=$(curl eth0.me)
        then
            echo "eth0.me failed, please check your internet connection/DNS"
            exit $?
        fi
    fi
    # $SUDO cp /tmp/pivpnUSR /etc/pivpn/INSTALL_USER
    # $SUDO cp /tmp/DET_PLATFORM /etc/pivpn/DET_PLATFORM

    cp "$source_dir"/Default.txt "$pivpn_dir"/Default.txt

  	if [[ ${APPLY_TWO_POINT_FOUR} == true ]]; then
    		#If they enabled 2.4 change compression algorithm and remove key-direction options since it's not required
    		sed -i "s/comp-lzo/compress lz4/" "$pivpn_dir"/Default.txt
    		sed -i "/key-direction 1/d" "$pivpn_dir"/Default.txt
  	fi

    if [[ ${useUpdateVars} == false ]]; then
        METH=$(whiptail --title "Public IP or DNS" --radiolist "Will clients use a Public IP or DNS Name to connect to your server (press space to select)?" ${r} ${c} 2 \
        "$IPv4pub" "Use this public IP" "ON" \
        "DNS Entry" "Use a public DNS" "OFF" 3>&1 1>&2 2>&3)

        exitstatus=$?
        if [ $exitstatus != 0 ]; then
            echo "::: Cancel selected. Exiting..."
            exit 1
        fi

        if [ "$METH" == "$IPv4pub" ]; then
            sed -i 's/IPv4pub/'"$IPv4pub"'/' "$pivpn_dir"/Default.txt
        else
            local publicDNSCorrect=false
            until [[ $publicDNSCorrect = True ]]
            do
                PUBLICDNS=$(whiptail --title "PiVPN Setup" --inputbox "What is the public DNS name of this Server?" ${r} ${c} 3>&1 1>&2 2>&3)
                exitstatus=$?
                if [ $exitstatus != 0 ]; then
                echo "::: Cancel selected. Exiting..."
                exit 1
                fi
                if (whiptail --backtitle "Confirm DNS Name" --title "Confirm DNS Name" --yesno "Is this correct?\n\n Public DNS Name:  $PUBLICDNS" ${r} ${c}) then
                    publicDNSCorrect=True
                    sed -i 's/IPv4pub/'"$PUBLICDNS"'/' "$pivpn_dir"/Default.txt
                else
                    publicDNSCorrect=False
                fi
            done
        fi
    else
        sed -i 's/IPv4pub/'"$PUBLICDNS"'/' "$pivpn_dir"/Default.txt
    fi

    # if they modified port put value in Default.txt for clients to use
    if [ $PORT != 1194 ]; then
        sed -i -e "s/1194/${PORT}/g" "$pivpn_dir"/Default.txt
    fi

    # if they modified protocol put value in Default.txt for clients to use
    if [ "$PROTO" != "udp" ]; then
        $SUDO sed -i -e "s/proto udp/proto tcp/g" /etc/openvpn/easy-rsa/pki/Default.txt
    fi

    # verify server name to strengthen security
    sed -i "s/SRVRNAME/${SERVER_NAME}/" "$pivpn_dir"/Default.txt

    # if [ ! -d "/home/$pivpnUser/ovpns" ]; then
    #     $SUDO mkdir "/home/$pivpnUser/ovpns"
    # fi
    # $SUDO chmod 0777 -R "/home/$pivpnUser/ovpns"
}



pivpn_dir="$(realpath "$1")"
easyrsa_dir="$1"/easyrsa

mkdir "$pivpn_dir"
confOpenVPN "$easyrsa_dir" "$pivpn_dir" "$(dirname "$0")"/..
confOVPN "$(dirname "$0")"/.. "$pivpn_dir"


