
screen_size=$(stty size 2>/dev/null || echo 24 80)
rows=$(echo $screen_size | awk '{print $1}')
columns=$(echo $screen_size | awk '{print $2}')

# Divide by two so the dialogs take up half of the screen, which looks nice.
r=$(( rows / 2 ))
c=$(( columns / 2 ))
# Unless the screen is tiny
r=$(( r < 20 ? 20 : r ))
c=$(( c < 70 ? 70 : c ))

CA="ca.crt"
TA="ta.key"

catOVPNInline() {
    local easyrsa_dir="$1"
    local pivpn_dir="$2"
    local name="$3"
    local dh="$4"
    #Now, append the CA Public Cert

    echo "<ca>"
    cat "$easyrsa_dir"/pki/ca.crt
    echo "</ca>"

    #Next append the client Public Cert
    echo "<cert>"
    sed -ne '/-BEGIN CERTIFICATE-/,/-END CERTIFICATE-/p' < "$easyrsa_dir/pki/issued/$name.crt"
    echo "</cert>"

    #Then, append the client Private Key
    echo "<key>"
    cat "$easyrsa_dir/pki/private/$name.key"
    echo "</key>"

  	#Finally, append the TA Private Key
  	if [ -f "$pivpn_dir/TWO_POINT_FOUR" ]; then
    		echo "<tls-crypt>"
    		cat "$easyrsa_dir"/pki/ta.key
    		echo "</tls-crypt>"
  	else
    		echo "<tls-auth>"
    		cat "$easyrsa_dir"/pki/ta.key
    		echo "</tls-auth>"
  	fi

    if [ -n "$dh" ] && [ -f "$dh" ]; then
        echo "<dh>"
        cat "$dh"
        echo "</dh>"
    fi

}