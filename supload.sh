#!/bin/bash
#
########### Cloud Storage Uploader #################
#
# Script for upload files to cloud storage supported
# Cloud Files API (such as OpenStack Swift).
#
# Site: https://github.com/selectel/supload
# Version: 1.1
#
# Feature:
# - recursive upload
# - check files by MD5 hash
# - upload only modified files
#
# Requires:
# - util curl
# - util file
#
# Restrictions:
# - support only less than 5G file to upload
#
# Authors:
# - Konstantin Kapustin <sirkonst@gmail.com>
#
# License: GPL-3
#
####################################################


usage() {
    echo "USAGE: $0 [-a auth_url] -u <USER> -k <KEY> [-r] [-M] <dest_dir> <src_path>"
    echo -e "Options:"
    echo -e "\t-a <auth_url>\tauthentication url (default: https://selcdn.ru/auth/v1.0/)"
    echo -e "\t-u <USER>\tuser name"
    echo -e "\t-k <KEY>\tuser password"
    echo -e "\t-r\t\trecursive upload"
    echo -e "\t-M\t\tdisable check upload by md5 sum"
    echo -e "\t-q\t\tquiet mode (error output only)"
    echo "Params:"
    echo -e "\t <dest_dir>\tdestination directory or container in storage (ex. containet/dir1/), not a file name"
    echo -e "\t <src_path>\tsource file or directory"
}

# Defaults
AUTH_URL="https://auth.selcdn.ru/"
RECURSIVEMODE=""
USER=""
KEY=""
DEST_DIR=""
SRC_PATH=""
MD5CHECK="1"
QUIETMODE="0"

# Utils
CURL="`which curl`"
CURLOPTS="--http1.0 --insecure"

FILEEX=`which file`
MD5SUM=`which md5sum`
if [ -z "$MD5SUM" ]; then
    MD5SUM=`which md5`
    if [ -n "$MD5SUM" ]; then
        MD5SUM="$MD5SUM -r"
    fi
fi

# check utils
if [ -z "$CURL" ]; then
    echo "[!] To use this script you need to install util 'curl'"
    exit 1
fi
if [ -z "$FILEEX" ]; then
    echo "[!] To use this script you need to install util 'file'"
    exit 1
fi
if [ -z "$MD5SUM" ]; then
    echo "[!] To use this script you need to install util 'md5sum' or 'md5'"
    exit 1
fi


while getopts ":ra:u:k:Mq" Option; do
    case $Option in
            r ) RECURSIVEMODE="1";;
            a ) AUTH_URL="$OPTARG";;
            u ) USER="$OPTARG";;
            k ) KEY="$OPTARG";;
            M ) MD5CHECK="0";;
            q ) QUIETMODE="1";;
            * ) echo "[!] Invalid option" && usage && exit 1;;
    esac
done
shift $(($OPTIND - 1))

if [[ -z "$USER" || -z "$KEY" || -z "$1"  || -z "$2" ]]; then
    echo "[!] Missing params"
    usage
    exit 1
fi


## helper for get abspath
canonical_readlink() {
  local filename

  cd `dirname "$1"`;
  filename=`basename "$1"`;
  if [ -h $filename ]; then
    canonical_readlink `readlink "$filename"`;
  else
    echo "`pwd -P`/$filename";
  fi
}

DEST_DIR="${1%%/}/" # ensure / in end
SRC_PATH=`canonical_readlink "$2"`


## Print message
msg() {
    if [ "$QUIETMODE" == "0" ]; then
        echo "$1"
    fi
}


## Authentication request
#
# params:
# * $1 - auth url
# * $2 - user name
# * $3 - user password
#
# If authentication is successful the function sets environment variables:
# * STOR_URL - storage url (always with / in end)
# * AUTH_TOKEN - authentication token
auth() {
    local temp_file
    local url
    local user
    local key
    local resp_status

    url="$1"
    user="$2"
    key="$3"

    temp_file=`mktemp /tmp/.supload.XXXXXX`
    ${CURL} ${CURLOPTS} -H "X-Auth-User: ${user}" -H "X-Auth-Key: ${key}" "${url}" -s -D "${temp_file}" 1> /dev/null

    resp_status=`cat "${temp_file}" | head -n1 | tr -d '\r'`
    resp_status="${resp_status#* }"
    if [ "$resp_status" == "403 Forbidden" ]; then
        echo "[!] Deny access, auth failed!"
        rm -f "${temp_file}"
        exit 1
    fi

    STOR_URL=`cat "${temp_file}" | tr -d '\r' | awk -F': ' 'tolower($1) ~ /^x-storage-url/ { print $2 }'`
    AUTH_TOKEN=`cat "${temp_file}" | tr -d '\r' | awk -F': ' 'tolower($1) ~ /^x-auth-token/ { print $2 }'`

    if [[ -z "${STOR_URL}" || -z "${AUTH_TOKEN}" ]]; then
        echo "[!] Auth failed"
        cat "${temp_file}"
        rm -f "${temp_file}"
        exit 1
    fi

    STOR_URL="${STOR_URL%%/}/"

    rm -f "${temp_file}"
}


## Url quoting
#
# params:
# * $1 - input string
#
# return: quote string
url_encode() {
    local encodedurl
    encodedurl="$1";

    encodedurl=`
        echo "$encodedurl" | hexdump -v -e '1/1 "%02x\t"' -e '1/1 "%_c\n"' |
        LANG=C awk '
            $1 == "20"                    { printf("%s",   "%20"); next }
            $1 ~  /0[adAD]/               {                      next } # strip newlines
            $2 ~  /^[a-zA-Z0-9.*()\/-]$/  { printf("%s",   $2);  next } # pass through what we can
                                          { printf("%%%s", $1)        } # take hex value of everything else
    '`

    echo "${encodedurl}"
}


## Request ETAG for file from storage
#
# params:
# * $1 - file url
#
# return: etag string or nothing
head_etag() {
    local temp_file
    local url
    local etag
    local resp_status

    temp_file=`mktemp /tmp/.supload.XXXXXX`
    url="$1"

    $CURL ${CURLOPTS} -H "X-Auth-Token: ${AUTH_TOKEN}" "${url}" -s -I -D "${temp_file}" 1> /dev/null

    resp_status=`cat "${temp_file}" | head -n1 | tr -d '\r'`
    resp_status="${resp_status#* }"
    if [ "$resp_status" == "403 Forbidden" ]; then
        rm -f "${temp_file}"
        echo ""
        return 2
    fi

    etag=`cat "${temp_file}" | egrep -w -o "etag: .+" | tr -d '\r' | sed 's/etag: //g'`

    rm -f "${temp_file}"

    echo "$etag"
}


## Detect mime-type for local file
#
# params:
# * $1 - path to local file
#
# return: mime-type string or nothing
content_type() {
    local file
    file=$1

    if [ -z "$FILEEX" ]; then
        echo ""
        return
    fi

    echo "`$FILEEX -b --mime "$file" | awk -F\; '{ print $1 }'`"
}


## Check for container existence
#
# params:
# * $1 - container name or path
#
# return: "ok" if container existence or error
check_container() {
    local url
    local temp_file
    local cont
    local status
    cont="${1%%/*}"
    temp_file=`mktemp /tmp/.supload.XXXXXX`

    url="${STOR_URL}/${cont}"
    $CURL ${CURLOPTS} -H "X-Auth-Token:${AUTH_TOKEN}" "${url}" -s -I -D "${temp_file}" 1> /dev/null

    status=`cat "${temp_file}" | grep "204 No Content"`
    rm -f "${temp_file}"

    if [ -z "$status" ]; then
        echo "not exist"
    fi

    echo "ok"
}


## Upload file
#
# params:
# * $1 - destination path in stotage
# * $2 - local file path
# ret_codes:
# * 0 - successfully uploaded
# * 1 - upload failed
# * 2 - access denied
# * 3 - source file doesn't exist
# * 4 - can't calc file hash
# * 5 - file already uploaded
# * 6 - hash doesn't match
_upload() {
    local temp_file
    local dest
    local dest_url
    local dest_file_url
    local src
    local filehash
    local etag
    local cont_type
    local header_etage
    local resp_status
    local rc

    dest="$1"
    src="$2"

    dest_url="${STOR_URL}`url_encode "$dest"`"
    dest_file_url="${STOR_URL}`url_encode "$dest${src##*/}"`"

    # check for local file existence
    if [[ ! -e "$src" || -d "$src" ]]; then
        return 3
    fi

    # check for file hash
    if [ "$MD5CHECK" == "1" ]; then
        # local file hash
        filehash=`${MD5SUM} "$src" | sed 's/ .*//g'`
        if [ -z "$filehash" ]; then
            return 5
        fi

        # compare file hash
        etag=`head_etag "$dest_file_url"`
        rc=$?
        if [ $rc -eq 2 ]; then
            return 2 # denied get ETAG from HEAD request
        fi

        if [ "z${filehash}" == "z${etag}" ] ; then
            return 5
        fi
    fi

    # mime-type
    cont_type=`content_type "$src"`

    # uploading
    temp_file=`mktemp /tmp/.supload.XXXXXX`

    if [ "$MD5CHECK" == "1" ]; then
        header_etage="-H ETag:$filehash"
    fi
    $CURL ${CURLOPTS} -X PUT -H "X-Auth-Token: ${AUTH_TOKEN}" -H "Content-Type: ${cont_type:-application/octet-stream}" $header_etage "$dest_url" -g -T "$src" -s -D "$temp_file" 1> /dev/null

    resp_status=`cat "${temp_file}" | head -n1 | tr -d '\r'`
    resp_status="${resp_status#* }"
    if [ "$resp_status" == "403 Forbidden" ]; then
        rm -f "${temp_file}"
        return 2
    fi

    # get hash for uploaded file (from response)
    etag=`cat "${temp_file}" | egrep -w -o "etag: .+" | tr -d '\r' | sed 's/etag: //g'`

    if [ -z "$etag" ]; then
        #cat "${temp_file}"
        rm -f "${temp_file}"
        return 1
    fi

    if [ "$MD5CHECK" == "1" ]; then
        if [ "z$etag" != "z$filehash" ]; then
            rm -f "${temp_file}"
            return 6
        fi
    fi

    rm -f "${temp_file}"

    echo "$etag"
}


## Upload file (with attempt again if failed)
#
# params:
# * $1 - destination path in stotage
# * $2 - local file path
upload() {
    local count
    local src
    local dst

    dst="$1"
    src="$2"

    count=0
    while [ 1 ]; do
            ((++count))
            if [ $count -gt 5 ]; then
                echo "[!] Failed upload $src after $((count - 1)) attempts."
                return 1
            fi

            msg "[.] Uploading $src..."
            etag=$(_upload "$dst" "$src")
            rc=$?

            if [ $rc -eq 0 ]; then
                msg "[*] Uploaded OK! Etag: $etag"
                return
            fi

            if [ $rc -eq 1 ]; then
                msg "[.] Attempt failed, try uploading again."
                sleep "$count"
                continue
            fi

            if [ $rc -eq 2 ]; then
                msg "[.] Access denied, try reauth and uploading again."
                sleep "$count"
                continue
            fi

            if [ $rc -eq 3 ]; then
                echo "[!] Source file $src doesn't exist!"
                return 1
            fi

            if [ $rc -eq 4 ]; then
                echo "[!] Error with calculate file hash, skip uploading $src"
                return 1
            fi

            if [ $rc -eq 5 ]; then
                msg "[.] File already uploaded."
                return
            fi

            if [ $rc -eq 6 ]; then
                msg "[.] Hash doesn't match after uploading."
                sleep "$count"
                continue
            fi

            echo "[!] Unknown error, failed upload $src"
            return 1
    done
}


## Main
main() {
    local rc

    auth "${AUTH_URL}" "${USER}" "${KEY}"

    if [ "`check_container "${DEST_DIR}"`" != "ok" ]; then
        echo "[!] Container not exist"
        exit 1
    fi

    ## Single file uploading
    if [ "z${RECURSIVEMODE}" != "z1" ]; then
        upload "${DEST_DIR}" "${SRC_PATH}"
        rc=$?

        exit $rc
    fi

    ## Recursive uploading
    if [ ! -d "${SRC_PATH}" ]; then
        echo "[!] ${SRC_PATH} is not dir"
        exit 1
    fi

    find "${SRC_PATH}" -type f -print0 | while read -d $'\0' f
    do
        src=$f

        a="${f#$SRC_PATH}"
        a="${a%/*}"
        dest="${DEST_DIR}${a#/}"
        dest="${dest%%/}/"

        upload "$dest" "$src"
    done
}

main
