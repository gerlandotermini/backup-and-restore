#!/bin/sh

# This script will scan the current Apache access log on a recurring basis looking for IP addresses 
# that generate too many suspicious requests (4xx or 5xx), and ban them by adding a "Deny" entry to the
# .htaccess file governing the ASRC website

# Define initial script params
THRESHOLD_4XX_5XX=30
THRESHOLD_KEYWORDS=5
THRESHOLD_DOS=10000
LOOKBACK_MINUTES=60
PATH_TO_SELF="$(cd -- "$(dirname "$0")" >/dev/null 2>&1 ; pwd -P)"

# Load banned keywords
IFS=$'\n' read -d '' -r -a KEYWORDS < "${PATH_TO_SELF}/keywords.txt"

# Make sure all the parameters were specified
if [[ -z "$1" || -z "$2" ]]; then
    echo -e "Error: Please provide the path to the .htaccess file and the list of log files to scan:\nip2ban.sh /var/www/html/.htaccess '/var/logs/site1/ssl_access.log /var/logs/site2/ssl_access.log /var/www/site3/ssl_access.log'"
    exit 1
fi

# Does the file exist?
if [ ! -f "$1" ]; then
    echo "Error: Path $1 does not exist. Aborting."
    exit 1
fi

HTACCESS="$1"
IFS=' ' read -r -a LOGS <<< "$2"

function in_subnet {
    # Determine whether IP address is in the specified subnet.
    #
    # Args:
    #   sub: Subnet, in CIDR notation.
    #   ip: IP address to check.
    #
    # Returns:
    #   1|0
    #
    local ip ip_a mask netmask sub sub_ip rval start end

    # Define bitmask.
    local readonly BITMASK=0xFFFFFFFF

    # Set DEBUG status if not already defined in the script.
    [[ "${DEBUG}" == "" ]] && DEBUG=0

    # Read arguments.
    IFS=/ read sub mask <<< "${1}"
    IFS=. read -a sub_ip <<< "${sub}"
    IFS=. read -a ip_a <<< "${2}"

    # Take care of empty CIDR masks
    [[ -z "$mask" ]] && mask=32 

    # Calculate netmask.
    netmask=$(($BITMASK<<$((32-$mask)) & $BITMASK))

    # Determine address range.
    start=0
    for o in "${sub_ip[@]}"
    do
        start=$(($start<<8 | $o))
    done

    start=$(($start & $netmask))
    end=$(($start | ~$netmask & $BITMASK))

    # Convert IP address to 32-bit number.
    ip=0
    for o in "${ip_a[@]}"
    do
        ip=$(($ip<<8 | $o))
    done

    # Determine if IP in range.
    (( $ip >= $start )) && (( $ip <= $end )) && rval=1 || rval=0

    (( $DEBUG )) &&
        printf "ip=0x%08X; start=0x%08X; end=0x%08X; in_subnet=%u\n" $ip $start $end $rval 1>&2

    echo "${rval}"
}

# Find which access log is being used
BANLIST=""
for server_log in ${LOGS[*]}; do
  if [ -f $server_log ]; then
    # Get a list of IP addresses that have exceeded the threshold amount of 4xx or 5xx requests
    NEWITEMS=$(awk -v datestring=$(date -d "now -${LOOKBACK_MINUTES} minutes" +[%d/%b/%Y:%H:%M:%S) '{if ($4 > datestring && ($9 ~ /^4/ || $9 ~ /^5/)) {print $1 " " $9}}' $server_log | sort | uniq -c | sort -nr | awk -v threshold="$THRESHOLD_4XX_5XX" -v lookback_minutes="$LOOKBACK_MINUTES" '{if ($1 > threshold) {print $2 "|" $3 " HTTP error recorded " $1 " times in the last " lookback_minutes " minutes"}}')
    if [ ! -z "${NEWITEMS}" ]; then
        BANLIST="${BANLIST}${NEWITEMS}"$'\n'
    fi

    # Look for IP addresses trying to access suspicious URL
    NEWITEMS=$(awk -v datestring=$(date -d "now -${LOOKBACK_MINUTES} minutes" +[%d/%b/%Y:%H:%M:%S) -v already_found="$NEWITEMS" '{if (already_found !~ $1 && $4 > datestring) {print $0}}' $server_log | awk -v keywords="${KEYWORDS[*]}" '{split(keywords, kw, " "); for (x in kw) {if ($7 ~ kw[x]) {print $1 " " kw[x] " " $7}}}' | sort | uniq -c | sort -nr | awk -v threshold="$THRESHOLD_KEYWORDS" -v lookback_minutes="$LOOKBACK_MINUTES" '{if ($1 > threshold) {print $2 "|String " $4 " accessed " $1 " times in the last " lookback_minutes " minutes"}}')
    if [ ! -z "${NEWITEMS}" ]; then
        BANLIST="${BANLIST}${NEWITEMS}"$'\n'
    fi

    # Is any IP address flooding the server with requests (DoS)?
    NEWITEMS=$(awk -v datestring=$(date -d "now -${LOOKBACK_MINUTES} minutes" +[%d/%b/%Y:%H:%M:%S) -v already_found="$NEWITEMS" '{if (already_found !~ $1 && $4 > datestring) {print $1}}' $server_log | sort | uniq -c | sort -nr | awk -v threshold="$THRESHOLD_DOS" -v lookback_minutes="$LOOKBACK_MINUTES" '{if ($1 > threshold) {print $2 "|DoS Attempt with " $1 " requests in the last " lookback_minutes " minutes"}}')
    if [ ! -z "${NEWITEMS}" ]; then
        BANLIST="${BANLIST}${NEWITEMS}"$'\n'
    fi 
  fi
done

# Read the whitelist from the .htaccess file (CIDR notation)
WHITELIST=$(awk '/Start Whitelist/{f=1;next} /End Whitelist/{f=0} f' $HTACCESS | awk '{print $2}')
IPFOUND=0

# Now, for each IP, let's add it to our .htaccess file, if it doesn't exist already (via grep).
# This allows to maintain a manual whitelist of IPs we don't want to block, right in the .htaccess itself
if [ ! -z "${BANLIST}" ]; then
  while IFS="|" read -r ip comment; do
    for subnet in ${WHITELIST[*]}; do
        if [[ $(in_subnet $subnet $ip) -eq 1 ]]; then
          IPFOUND=1
          break
        fi
    done

    # If this IP address didn't match any of the whitelisted subnets, add it to the .htaccess file, if not already there
    if [[ $IPFOUND -eq 0 && -z $(grep -F "Deny from $ip" $HTACCESS) ]]; then
      IPHOSTNAME=$(nslookup $ip | awk '/name / {gsub(/.$/,""); print " [" $NF "]"; exit}')
      echo "# $(date +'%Y/%m/%d %H:%M:%S')$IPHOSTNAME - $comment" >> $HTACCESS
      echo "Deny from $ip" >> $HTACCESS
      echo "Added: $ip$IPHOSTNAME - $comment"
    else
      IPFOUND=0
    fi
  done <<< "$BANLIST"
fi
