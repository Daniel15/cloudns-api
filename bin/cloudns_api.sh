#!/bin/bash

AWK="/usr/bin/awk"
BASENAME="/usr/bin/basename"
CAT="/usr/bin/cat"
CURL="/usr/bin/curl"
CUT="/usr/bin/cut"
DATE="/usr/bin/date"
ECHO="builtin echo"
EVAL="builtin eval"
GETOPTS="builtin getopts"
GREP="/usr/bin/grep"
JQ="/usr/bin/jq"
SED="/usr/bin/sed"
SLEEP="/usr/bin/sleep"
TEST="/usr/bin/test"
TR="/usr/bin/tr"
WC="/usr/bin/wc"

API_URL="https://api.cloudns.net/dns"
DEBUG=0
FORCE=0
JSON=0
REMOVAL_WAIT=5
SKIP_TESTS=0
THISPROG=$( ${BASENAME} $0 )

ROWS_PER_PAGE=100
SUPPORTED_RECORD_TYPES=( "A" "CNAME" "MX" "NS" "SPF" "SRV" "TXT" )

# current limitations
# - does not support sub-auth-id
# - only supports master zones
# - only supports forward zones
# - only supports creation/modification of SUPPORTED_RECORD_TYPES

function print_error {
  ${ECHO} "$( ${DATE} ): Error: $@" >&2
}

function print_usage {
  {
    ${ECHO} "Usage: ${THISPROG} [-dfhjs] command [options]"
    ${ECHO} "       -d   run in debug mode (lots of verbose messages)"
    ${ECHO} "       -f   force delrecord operations without confirmation"
    ${ECHO} "       -h   display this help message"
    ${ECHO} "       -j   return listrecords output in JSON format"
    ${ECHO} "       -s   skip testing authentication prior to attempting API operations"
    ${ECHO} ""
    ${ECHO} "   Commands:"
    ${ECHO} "       listzones  - list zones under management"
    ${ECHO} "       addzone    - add a new zone"
    ${ECHO} "       delzone    - delete an existing zone"
    ${ECHO} "       checkzone  - check that a zone is managed"
    ${ECHO} "       dumpzone   - dump a zone in BIND zonefile format"
    ${ECHO} "       zonestatus - check whether a zone is updated on all NS"
    ${ECHO} "       nsstatus   - view a breakdown of zone update status by NS"
    ${ECHO} "       addrecord  - add a new DNS record to a zone"
    ${ECHO} "       delrecord  - delete a DNS record from a zone"
    ${ECHO} "       modify     - modify an existing DNS record"
    ${ECHO} "       getsoa     - get SOA record parameters for a zone"
    ${ECHO} "       setsoa     - set SOA record parameters for a zone"
    ${ECHO} "       helper     - call a helper function directly"
    ${ECHO} "       test       - perform an authentication test"
    ${ECHO} ""
    ${ECHO} "   Environment:"
    ${ECHO} "     Ensure that the following two environment variables are exported:"
    ${ECHO} "       CLOUDNS_API_ID   - your ClouDNS API ID (auth-id)"
    ${ECHO} "       CLOUDNS_PASSWORD - your ClouDNS API password (auth-password)"   
  } >&2
}

function check_jq {
  [[ ! -x "${JQ}" ]] && {
    print_error "This program requires jq to be installed. Install it."
    exit 1
  }
}

function print_timestamp {
  ${ECHO} "$( ${DATE} ): $@"
}

function print_debug {
  (( DEBUG )) && ${ECHO} "$( ${DATE} ): DEBUG: $@"
}

function process_arguments {
  local COMMAND="$1"
  if [ -z "${COMMAND}" ]; then
    print_usage && exit 1
  fi
  case ${COMMAND} in
    "help"         ) print_usage && exit 0    ;;
    "test"         ) test_login               ;;
    "listzones"    ) list_zones               ;;
    "addzone"      ) shift
                     add_zone "$@"            ;;
    "delzone"      ) shift
                     delete_zone "$@"         ;;
    "checkzone"    ) shift
                     check_zone "$@"          ;;
    "dumpzone"     ) shift
                     dump_zone "$@"           ;;
    "zonestatus"   ) shift
                     zone_status "$@"         ;;
    "nsstatus"     ) shift
                     ns_status "$@"           ;;
    "addrecord"    ) shift
                     add_record "$@"          ;;
    "delrecord"    ) shift
                     delete_record "$@"       ;;
    "modify"       ) shift
                     modify_record "$@"       ;;
    "listrecords"  ) shift
                     list_records "$@"        ;;
    "getsoa"       ) shift
                     get_soa "$@"             ;;
    "setsoa"       ) shift
                     set_soa "$@"             ;;
    "helper"       ) shift
                     call_helper "$@"         ;;
    *              ) print_usage && exit 1    ;;
  esac
}

function check_environment_variables {
  local ERROR_COUNT=0
  local REQUIRED_VARIABLES=( CLOUDNS_API_ID CLOUDNS_PASSWORD )
  for REQUIRED_VARIABLE in ${REQUIRED_VARIABLES[@]}; do
    if $( ${EVAL} ${TEST} -z \${${REQUIRED_VARIABLE}} ); then
      print_error "Environment variable \${${REQUIRED_VARIABLE}} unset"
      (( ERROR_COUNT = ERROR_COUNT + 1 ))
    fi
  done
  if [ "${ERROR_COUNT}" -gt "0" ]; then
    exit 1
  fi
}

function set_auth_post_data {
  AUTH_POST_DATA="-d auth-id=${CLOUDNS_API_ID} -d auth-password=${CLOUDNS_PASSWORD}"
}

function test_api_url {
  local HTTP_CODE=$( ${CURL} -4qs -o /dev/null -w '%{http_code}' ${API_URL}/login.json )
  if [ "${HTTP_CODE}" != "200" ]; then
    print_error "Unable to reach ClouDNS API" && exit 1
  else
    print_debug "API availability check successful"
  fi
}

function do_login {
  local STATUS=$( ${CURL} -4qs -X POST ${AUTH_POST_DATA} "${API_URL}/login.json" | ${JQ} -r '.status' )
  case ${STATUS} in
    "Success" ) print_debug "Login successful"
                return 0 ;;
    *         ) print_debug "Login failed"
                return 1 ;;
  esac  
}

function do_tests {
  (( ! SKIP_TESTS )) && {
    test_api_url
    do_login
  } || {
    print_debug "-s passed - skipping tests"
  }
}

function check_zone {
  do_tests
  local ZONES="$@"
  if [ -z "${ZONES}" ]; then
    print_error "No zones passed to checkzone" && exit 1
  fi
  for ZONE in ${ZONES}; do
    print_debug "Checking zone [${ZONE}]"
    local POST_DATA="${AUTH_POST_DATA} -d domain-name=${ZONE}"
    local OUTPUT=$( ${CURL} -4qs -X POST ${POST_DATA} "${API_URL}/get-zone-info.json" )
    if [ $( ${ECHO} "${OUTPUT}" | ${JQ} -r '.status' ) != "Failed" ]; then
      ${ECHO} "${ZONE}:present"
    else
      ${ECHO} "${ZONE}:absent"
    fi
  done
}

function ns_status {
  do_tests
  if [ "$#" -ne "1" ]; then
    print_error "nsstatus expects exactly one argument" && exit 1
  fi
  local ZONE="$1"
  local LISTED_ZONES
  LISTED_ZONES=$( list_zones | ${GREP} -qs "^${ZONE}:" )
  if [ "$?" -ne "0" ]; then
    print_error "Zone [${ZONE}] not under management" && exit 1
  fi
  print_debug "Checking NS status for [${ZONE}]"
  local POST_DATA="${AUTH_POST_DATA} -d domain-name=${ZONE}"
  local NS_STATUS=$( ${CURL} -4qs -X POST ${POST_DATA} "${API_URL}/update-status.json" )
  local STATUS=$( ${ECHO} "${NS_STATUS}" | ${JQ} -r '.status' 2>/dev/null )
  if [ "${STATUS}" = "Failed" ]; then
    print_error "No such domain [${ZONE}]" && exit 1
  else
    ${ECHO} "${NS_STATUS}" | ${JQ} -r '.[] | .server + ":" + (.updated|tostring)'
  fi
}

function zone_status {
  do_tests
  local ZONES="$@"
  if [ -z "${ZONES}" ]; then
    print_error "No zones passed to zonestatus" && exit 1
  fi
  for ZONE in ${ZONES}; do
    print_debug "Checking zone status for [${ZONE}]"
    local POST_DATA="${AUTH_POST_DATA} -d domain-name=${ZONE}"
    local IS_UPDATED=$( ${CURL} -4qs -X POST ${POST_DATA} "${API_URL}/is-updated.json" )
    if [ "${IS_UPDATED}" = "true" ]; then
      ${ECHO} "${ZONE}:up-to-date"
    elif [ "${IS_UPDATED}" = "false" ]; then
      ${ECHO} "${ZONE}:out-of-date"
    else
      ${ECHO} "${ZONE}:not-valid"
    fi
  done
}

# we don't need to call do_tests in the get_* helper functions, as it
# will have already been called in the calling function
function get_page_count {
  local POST_DATA="${AUTH_POST_DATA} -d rows-per-page=${ROWS_PER_PAGE}"
  local PAGE_COUNT=$( ${CURL} -4qs -X POST ${POST_DATA} "${API_URL}/get-pages-count.json" )
  local STATUS=$( ${ECHO} "${PAGE_COUNT}" | ${JQ} -r '.status' 2>/dev/null )
  if [ "${STATUS}" = "Failed" ]; then
    print_error "API call to get-pages-count.json failed" && exit 1
  fi
  ${ECHO} "${PAGE_COUNT}" | ${GREP} -Eqs '^[[:digit:]]+'
  if [ "$?" -ne "0" ]; then
    print_error "Invalid response received from get-pages-count.json" && exit 1
  fi
  ${ECHO} "${PAGE_COUNT}"
}

function get_record_types {
  local POST_DATA="${AUTH_POST_DATA} -d zone-type=domain"
  local RECORD_TYPES=$( ${CURL} -4qs -X POST ${POST_DATA} "${API_URL}/get-available-record-types.json" )
  local STATUS=$( ${ECHO} "${RECORD_TYPES}" | ${JQ} -r '.status' 2>/dev/null )
  if [ "${STATUS}" = "Failed" ]; then
    print_error "API call to get-available-record-types.json failed" && exit 1
  fi
  # check for the existence of a common record type, e.g. CNAME
  local INDEX=$( ${ECHO} "${RECORD_TYPES}" | ${JQ} -r 'index("CNAME")' )
  if [ "${INDEX}" = "null" ]; then
    print_error "RECORD_TYPES array does not contain an expected record type"
    exit 1
  fi
  RECORD_TYPES=$( ${ECHO} "${RECORD_TYPES}" | ${JQ} -r '.|join(" ")' )
  ${ECHO} "${RECORD_TYPES}"
}

function get_available_ttls {
  local POST_DATA="${AUTH_POST_DATA}"
  local TTLS=$( ${CURL} -4qs -X POST ${POST_DATA} "${API_URL}/get-available-ttl.json" )
  local STATUS=$( ${ECHO} "${TTLS}" | ${JQ} -r '.status' 2>/dev/null )
  if [ "${STATUS}" = "Failed" ]; then
    print_error "API call to get-available-ttl.json failed" && exit 1
  fi
  TTLS=$( ${ECHO} "${TTLS}" | ${JQ} -r '[.[]|tostring]|join(" ")' )
  ${ECHO} "${TTLS}"
}

function has_element {
  local -n CHECK_ARRAY="$1"
  local CHECK_VALUE="$2"
  local VALUE
  for VALUE in ${CHECK_ARRAY[@]}; do
    if [ "${VALUE}" = "${CHECK_VALUE}" ]; then
      return 0
    fi
  done
  return 1
}

function list_records {
  do_tests
  if [ "$#" -eq "0" ]; then
    print_error "listrecords expects at least one argument" && exit 1
  fi
  local ZONE="$1"
  if [[ "${ZONE}" =~ ^.*=.*$ ]]; then
    print_error "[${ZONE}] looks like a key=value pair, not a zone name" && exit 1
  fi
  local LISTED_ZONES
  LISTED_ZONES=$( list_zones | ${GREP} -qs "^${ZONE}:" )
  if [ "$?" -ne "0" ]; then
    print_error "Zone [${ZONE}] not under management" && exit 1
  fi
  shift
  if [ "$#" -gt "3" ]; then
    print_error "usage: ${THISPROG} listrecords <zone> [type=<type>] [host=<host>] [showid=<true|false>]"
    exit 1
  fi
  if [ "$#" -gt "0" ]; then
    local -a VALID_KEYS=( "type" "host" "showid" )
    local KV_PAIRS="$@" ERROR_COUNT=0 SHOW_ID="false"
    local KV_PAIR
    for KV_PAIR in ${KV_PAIRS}; do
      ${ECHO} "${KV_PAIR}" | ${GREP} -Eqs '^[a-z-]+=[^=]+$'
      if [ "$?" -ne "0" ]; then
        print_error "key-value pair [${KV_PAIR}] not in correct format" && exit 1
      fi
      local KEY=$( ${ECHO} "${KV_PAIR}" | ${CUT} -d = -f 1 )
      local VALUE=$( ${ECHO} "${KV_PAIR}" | ${CUT} -d = -f 2 )
      print_debug "Checking key-value pair: ${KEY}=${VALUE}"
      if ! has_element VALID_KEYS "${KEY}"; then
        print_error "${KEY} is not a valid key"
        (( ERROR_COUNT = ERROR_COUNT + 1 ))
      fi
      case ${KEY} in
        "type"   ) local -a RECORD_TYPES=( $( get_record_types ) )
                   local TMPVAR="${VALUE^^}"
                   if ! has_element RECORD_TYPES "${TMPVAR}"; then
                     print_error "${VALUE} (${TMPVAR}) is not a valid record type"
                     exit 1
                   else
                     local RECORD_TYPE="${VALUE}"
                   fi
                   ;;
        "host"   ) local HOST_RECORD="${VALUE}"
                   ;;
        "showid" ) case ${VALUE} in
                     "true"|"false" ) SHOW_ID="${VALUE}"
                                      ;;
                     *              ) print_error "Invalid value for showid"
                                      exit 1
                                      ;;
                   esac
                   ;;
      esac
      unset KEY VALUE
    done
  fi
  [[ "${ERROR_COUNT}" -gt "0" ]] && exit 1
  local POST_DATA="${AUTH_POST_DATA} -d domain-name=${ZONE}"
  if [ -n "${RECORD_TYPE}" ]; then
    POST_DATA="${POST_DATA} -d type=${RECORD_TYPE}"
  fi
  if [ -n "${HOST_RECORD}" -a "${HOST_RECORD}" != "@" ]; then
    POST_DATA="${POST_DATA} -d host=${HOST_RECORD}"
  fi
  print_debug "Fetching records for zone [${ZONE}] with type [${RECORD_TYPE:-not set}] and host [${HOST_RECORD:-not set}]"
  local RECORD_DATA=$( ${CURL} -4qs -X POST ${POST_DATA} "${API_URL}/records.json" )
  local RESULT_LENGTH=$( ${ECHO} "${RECORD_DATA}" | ${JQ} -r '.|length' )
  if [ "${RESULT_LENGTH}" -eq "0" ]; then
    print_error "No matching records found" && exit 1
  else
    local STATUS=$( ${ECHO} "${RECORD_DATA}" | ${JQ} -r '.status' 2>/dev/null )
    if [ "${STATUS}" = "Failed" ]; then
      local STATUS_DESC=$( ${ECHO} "${RECORD_DATA}" | ${JQ} -r '.statusDescription' )
      print_error "Unable to get records for [${ZONE}]: ${STATUS_DESC}" && exit 1
    fi
    # output records in BIND format - if showid is true, then add the id as a BIND
    # style comment
    #
    # note: the CloudDNS records.json API endpoint has no way of filtering for apex
    # records, so we handle this by changing empty hosts to '@', then select-ing based
    # upon that
    if [ "${JSON}" -eq "1" ]; then
      if [ "${HOST_RECORD}" = "@" ]; then
        ${ECHO} "${RECORD_DATA}" | ${JQ} -r '.[] | select(.host == "")'
      else
        ${ECHO} "${RECORD_DATA}" | ${JQ} -r '.'
      fi
      exit 0
    fi
    if [ "${HOST_RECORD}" = "@" ]; then
      if [ "${SHOW_ID}" = "true" ]; then
        ${ECHO} "${RECORD_DATA}" | ${JQ} -r 'map(if .host == "" then . + {"host":"@"} else . end) | map(if .type == "NS" or .type == "MX" or .type == "CNAME" or .type == "SRV" then . + {"record": (.record + ".")} else .  end) | map(if .type == "TXT" or .type == "SPF" then . + {"record": ("\"" + .record + "\"")} else .  end) | .[] | select(.host == "@") | if .type == "MX" then (.host + "\t" + .ttl + "\tIN\t" + .type + "\t" + (.priority|tostring) + "\t" + .record + "\t; id=" + .id) elif .type == "SRV" then (.host + "\t" + .ttl + "\tIN\t" + .type + "\t" + (.priority|tostring) + "\t" + (.weight|tostring) + "\t" + (.port|tostring) + "\t" + .record + "\t; id=" + .id) else (.host + "\t" + .ttl + "\tIN\t" + .type + "\t" + .record + "\t; id=" + .id) end'
      else
        ${ECHO} "${RECORD_DATA}" | ${JQ} -r 'map(if .host == "" then . + {"host":"@"} else . end) | map(if .type == "NS" or .type == "MX" or .type == "CNAME" or .type == "SRV" then . + {"record": (.record + ".")} else . end) | map(if .type == "TXT" or .type == "SPF" then . + {"record": ("\"" + .record + "\"")} else . end) | .[] | select(.host == "@") | if .type == "MX" then (.host + "\t" + .ttl + "\tIN\t" + .type + "\t" + (.priority|tostring) + "\t" + .record) elif .type == "SRV" then (.host + "\t" + .ttl + "\tIN\t" + .type + "\t" + (.priority|tostring) + "\t" + (.weight|tostring) + "\t" + (.port|tostring) + "\t" + .record) else (.host + "\t" + .ttl + "\tIN\t" + .type + "\t" + .record) end'
      fi
    else
      if [ "${SHOW_ID}" = "true" ]; then
        ${ECHO} "${RECORD_DATA}" | ${JQ} -r 'map(if .host == "" then . + {"host":"@"} else . end) | map(if .type == "NS" or .type == "MX" or .type == "CNAME" or .type == "SRV" then . + {"record": (.record + ".")} else . end) | map(if .type == "TXT" or .type == "SPF" then . + {"record": ("\"" + .record + "\"")} else . end) | .[] | if .type == "MX" then (.host + "\t" + .ttl + "\tIN\t" + .type + "\t" + (.priority|tostring) + "\t" + .record + "\t; id=" + .id) elif .type == "SRV" then (.host + "\t" + .ttl + "\tIN\t" + .type + "\t" + (.priority|tostring) + "\t" + (.weight|tostring) + "\t" + (.port|tostring) + "\t" + .record + "\t; id=" + .id) else (.host + "\t" + .ttl + "\tIN\t" + .type + "\t" + .record + "\t; id=" + .id) end'
      else
        ${ECHO} "${RECORD_DATA}" | ${JQ} -r 'map(if .host == "" then . + {"host":"@"} else . end) | map(if .type == "NS" or .type == "MX" or .type == "CNAME" or .type == "SRV" then . + {"record": (.record + ".")} else . end) | map(if .type == "TXT" or .type == "SPF" then . + {"record": ("\"" + .record + "\"")} else . end) | .[] | if .type == "MX" then (.host + "\t" + .ttl + "\tIN\t" + .type + "\t" + (.priority|tostring) + "\t" + .record) elif .type == "SRV" then (.host + "\t" + .ttl + "\tIN\t" + .type + "\t" + (.priority|tostring) + "\t" + (.weight|tostring) + "\t" + (.port|tostring) + "\t" + .record) else (.host + "\t" + .ttl + "\tIN\t" + .type + "\t" + .record) end'
      fi
    fi
  fi
}

function get_soa {
  do_tests
  if [ "$#" -ne "1" ]; then
    print_error "getsoa expects exactly one argument" && exit 1
  fi
  local ZONE="$1"
  local LISTED_ZONES
  LISTED_ZONES=$( list_zones | ${GREP} -qs "^${ZONE}:" )
  if [ "$?" -ne "0" ]; then
    print_error "Zone [${ZONE}] not under management" && exit 1
  fi
  print_debug "Retrieving SOA details for [${ZONE}]"
  local POST_DATA="${AUTH_POST_DATA} -d domain-name=${ZONE}"
  local SOA_DATA=$( ${CURL} -4qs -X POST ${POST_DATA} "${API_URL}/soa-details.json" )
  local STATUS=$( ${ECHO} "${SOA_DATA}" | ${JQ} -r '.status' 2>/dev/null )
  if [ "${STATUS}" = "Failed" ]; then
    local STATUS_DESC=$( ${ECHO} "${SOA_DATA}" | ${JQ} -r '.statusDescription' )
    print_error "Unable to get SOA for [${ZONE}]: ${STATUS_DESC}" && exit 1
  fi
  ${ECHO} "${SOA_DATA}" | ${JQ} -r 'to_entries[] | .key + ":" + .value'
}

function set_soa {
  do_tests
  if [ "$#" -lt "2" ]; then
    print_error "usage: ${THISPROG} setsoa <domain> key=<value> [key=<value> ...  key=<value>]"
    exit 1
  fi
  local ZONE="$1"
  if [[ "${ZONE}" =~ ^.*=.*$ ]]; then
    print_error "[${ZONE}] looks like a key=value pair, not a zone name" && exit 1
  fi
  local LISTED_ZONES
  LISTED_ZONES=$( list_zones | ${GREP} -qs "^${ZONE}:" )
  if [ "$?" -ne "0" ]; then
    print_error "Zone [${ZONE}] not under management" && exit 1
  fi
  print_debug "Modifying SOA record for zone [${ZONE}]"
  shift
  local -a VALID_KEYS=( "primary-ns" "admin-mail" "refresh" "retry" "expire" "default-ttl" )
  local KV_PAIRS="$@" ERROR_COUNT=0
  local KV_PAIR
  for KV_PAIR in ${KV_PAIRS}; do
    ${ECHO} "${KV_PAIR}" | ${GREP} -Eqs '^[a-z-]+=[^=]+$'
    if [ "$?" -ne "0" ]; then
      print_error "key-value pair [${KV_PAIR}] not in correct format" && exit 1
    fi
    local KEY=$( ${ECHO} "${KV_PAIR}" | ${CUT} -d = -f 1 )
    local VALUE=$( ${ECHO} "${KV_PAIR}" | ${CUT} -d = -f 2 )
    print_debug "Checking key-value pair: ${KEY}=${VALUE}"
    if ! has_element VALID_KEYS "${KEY}"; then
      print_error "${KEY} is not a valid key"
      (( ERROR_COUNT = ERROR_COUNT + 1 ))
    fi
    unset KEY VALUE
  done
  unset KV_PAIR
  [[ "${ERROR_COUNT}" -gt "0" ]] && exit 1
  # modify-soa.json expects ALL parameters to be set. We will pre-populate via
  # a call to get_soa()
  local SOA_DATA=$( get_soa "${ZONE}" )
  local PRIMARY_NS=$( ${ECHO} "${SOA_DATA}" | ${AWK} -F : '$1 == "primaryNS" { print $2 }' )
  local ADMIN_MAIL=$( ${ECHO} "${SOA_DATA}" | ${AWK} -F : '$1 == "adminMail" { print $2 }' )
  local REFRESH=$( ${ECHO} "${SOA_DATA}" | ${AWK} -F : '$1 == "refresh" { print $2 }' )
  local RETRY=$( ${ECHO} "${SOA_DATA}" | ${AWK} -F : '$1 == "retry" { print $2 }' )
  local EXPIRE=$( ${ECHO} "${SOA_DATA}" | ${AWK} -F : '$1 == "expire" { print $2 }' )
  local DEFAULT_TTL=$( ${ECHO} "${SOA_DATA}" | ${AWK} -F : '$1 == "defaultTTL" { print $2 }' )
  print_debug "Initial SOA paramters loaded via get_soa():"
  print_debug "--> PRIMARY_NS: ${PRIMARY_NS}"
  print_debug "--> ADMIN_MAIL: ${ADMIN_MAIL}"
  print_debug "--> REFRESH: ${REFRESH}"
  print_debug "--> RETRY: ${RETRY}"
  print_debug "--> EXPIRE: ${EXPIRE}"
  print_debug "--> DEFAULT_TTL: ${DEFAULT_TTL}"
  local CHANGED=0
  for KV_PAIR in ${KV_PAIRS}; do
    local KEY=$( ${ECHO} "${KV_PAIR}" | ${CUT} -d = -f 1 )
    local VALUE=$( ${ECHO} "${KV_PAIR}" | ${CUT} -d = -f 2 )
    # no default required in case as we've already checked against VALID_KEYS
    case ${KEY} in
      "primary-ns"  ) validate_soa_value ns "${VALUE}"
                      if [ "$?" -ne "0" ]; then
                        print_error "Validation of primary-ns failed" && exit 1
                      else
                        if [ "${PRIMARY_NS}" = "${VALUE}" ]; then
                          print_timestamp "primary-ns value same as existing"
                        else
                          PRIMARY_NS="${VALUE}"
                          (( CHANGED = CHANGED + 1 ))
                        fi
                      fi
                      ;;
      "admin-mail"  ) validate_soa_value email "${VALUE}"
                      if [ "$?" -ne "0" ]; then
                        print_error "Validation of admin-mail failed" && exit 1
                      else
                        if [ "${ADMIN_MAIL}" = "${VALUE}" ]; then
                          print_timestamp "admin-mail value same as existing"
                        else
                          ADMIN_MAIL="${VALUE}"
                          (( CHANGED = CHANGED + 1 ))
                        fi
                      fi
                      ;;
      "refresh"     ) validate_soa_value refresh "${VALUE}"
                      if [ "$?" -ne "0" ]; then
                        print_error "Validation of refresh failed" && exit 1
                      else
                        if [ "${REFRESH}" = "${VALUE}" ]; then
                          print_timestamp "refresh value same as existing"
                        else
                          REFRESH="${VALUE}"
                          (( CHANGED = CHANGED + 1 ))
                        fi
                      fi
                      ;;
      "retry"       ) validate_soa_value retry "${VALUE}"
                      if [ "$?" -ne "0" ]; then
                        print_error "Validation of retry failed" && exit 1
                      else
                        if [ "${RETRY}" = "${VALUE}" ]; then
                          print_timestamp "retry value same as existing"
                        else
                          RETRY="${VALUE}"
                          (( CHANGED = CHANGED + 1 ))
                        fi
                      fi
                      ;;
      "expire"      ) validate_soa_value expire "${VALUE}"
                      if [ "$?" -ne "0" ]; then
                        print_error "Validation of expire failed" && exit 1
                      else
                        if [ "${EXPIRE}" = "${VALUE}" ]; then
                          print_timestamp "expire value same as existing"
                        else
                          EXPIRE="${VALUE}"
                          (( CHANGED = CHANGED + 1 ))
                        fi
                      fi
                      ;;
      "default-ttl" ) validate_soa_value ttl "${VALUE}"
                      if [ "$?" -ne "0" ]; then
                        print_error "Validation of default-ttl failed" && exit 1
                      else
                        if [ "${DEFAULT_TTL}" = "${VALUE}" ]; then
                          print_timestamp "default-ttl value same as existing"
                        else
                          DEFAULT_TTL="${VALUE}"
                          (( CHANGED = CHANGED + 1 ))
                        fi
                      fi
                      ;;
    esac
  done 
  if [ "${CHANGED}" -eq "0" ]; then
    print_timestamp "Nothing has changed - no need to modify" && exit 0
  fi
  print_debug "SOA paramters loaded after modification:"
  print_debug "--> PRIMARY_NS: ${PRIMARY_NS}"
  print_debug "--> ADMIN_MAIL: ${ADMIN_MAIL}"
  print_debug "--> REFRESH: ${REFRESH}"
  print_debug "--> RETRY: ${RETRY}"
  print_debug "--> EXPIRE: ${EXPIRE}"
  print_debug "--> DEFAULT_TTL: ${DEFAULT_TTL}"
  local POST_DATA="${AUTH_POST_DATA} -d domain-name=${ZONE}"
  POST_DATA="${POST_DATA} -d primary-ns=${PRIMARY_NS}"
  POST_DATA="${POST_DATA} -d admin-mail=${ADMIN_MAIL}"
  POST_DATA="${POST_DATA} -d refresh=${REFRESH}"
  POST_DATA="${POST_DATA} -d retry=${RETRY}"
  POST_DATA="${POST_DATA} -d expire=${EXPIRE}"
  POST_DATA="${POST_DATA} -d default-ttl=${DEFAULT_TTL}"
  local RESPONSE=$( ${CURL} -4qs -X POST ${POST_DATA} "${API_URL}/modify-soa.json" )
  local STATUS=$( ${ECHO} "${RESPONSE}" | ${JQ} -r '.status' )
  local STATUS_DESC=$( ${ECHO} "${RESPONSE}" | ${JQ} -r '.statusDescription' )
  if [ "${STATUS}" = "Failed" ]; then
    print_error "Failed to modify SOA for zone [${ZONE}]: ${STATUS_DESC}" && exit 1
  elif [ "${STATUS}" = "Success" ]; then
    print_timestamp "SOA for zone [${ZONE}] modified"
  else
    print_error "Unexpected response while modifiying SOA for zone [${ZONE}]" && exit 1
  fi
}

function check_integer {
  local VALUE="$1"
  local LOWER="$2"
  local UPPER="$3"
  ${ECHO} "${VALUE}" | ${GREP} -Eqs '^[[:digit:]]+$' || return 1
  if [ "${VALUE}" -ge "${LOWER}" -a "${VALUE}" -le "${UPPER}" ]; then
    return 0
  else
    return 1
  fi
}

function validate_soa_value {
  # see https://www.cloudns.net/wiki/article/63/ for permissible integer values
  local TYPE="$1"
  local VALUE="$2"
  case ${TYPE} in
    "ns"      ) # check for at least something.something
                ${ECHO} "${VALUE}" | ${GREP} -Eqs '^[a-z0-9-]+\.[a-z0-9-]+'
                return $? ;;
    "email"   ) # check for at least something@something
                ${ECHO} "${VALUE}" | ${GREP} -Eqs '^[^@]+@[^@]+$'
                return $? ;;
    "refresh" ) check_integer ${VALUE} 1200 43200
                return $? ;;
    "retry"   ) check_integer ${VALUE} 180 2419200
                return $? ;;
    "expire"  ) check_integer ${VALUE} 1209600 2419200
                return $? ;;
    "ttl"     ) check_integer ${VALUE} 60 2419200
                return $? ;;
    *         ) return 0  ;;
  esac
}

function dump_zone {
  do_tests
  if [ "$#" -ne "1" ]; then
    print_error "dumpzone expects exactly one argument" && exit 1
  fi
  local ZONE="$1"
  local LISTED_ZONES
  LISTED_ZONES=$( list_zones | ${GREP} -qs "^${ZONE}:" )
  if [ "$?" -ne "0" ]; then
    print_error "Zone [${ZONE}] not under management" && exit 1
  fi
  print_debug "Dumping BIND-format zone file for [${ZONE}]"
  local POST_DATA="${AUTH_POST_DATA} -d domain-name=${ZONE}"
  local ZONE_DATA=$( ${CURL} -4qs -X POST ${POST_DATA} "${API_URL}/records-export.json" )
  local STATUS=$( ${ECHO} "${ZONE_DATA}" | ${JQ} -r '.status' )
  if [ "${STATUS}" = "Success" ]; then
    ${ECHO} "${ZONE_DATA}" | ${JQ} -r '.zone'
  else
    print_error "Unable to get zone file for [${ZONE}]" && exit 1
  fi
}

function add_record {
  do_tests
  if [ "$#" -lt "5" ]; then
    print_error "usage: ${THISPROG} addrecord <zone> type=<type> host=<host> record=<record> ttl=<ttl> [key=<value> ... key=<value>]"
    exit 1
  fi
  local ZONE="$1"
  if [[ "${ZONE}" =~ ^.*=.*$ ]]; then
    print_error "[${ZONE}] looks like a key=value pair, not a zone name" && exit 1
  fi
  local LISTED_ZONES
  LISTED_ZONES=$( list_zones | ${GREP} -qs "^${ZONE}:" )
  if [ "$?" -ne "0" ]; then
    print_error "Zone [${ZONE}] not under management" && exit 1
  fi
  shift
  local -a VALID_KEYS=( "type" "host" "record" "ttl" "priority" "weight" "port" )
  local KV_PAIRS="$@" ERROR_COUNT=0
  local KV_PAIR
  for KV_PAIR in ${KV_PAIRS}; do
    ${ECHO} "${KV_PAIR}" | ${GREP} -Eqs '^[a-z-]+=.+$'
    if [ "$?" -ne "0" ]; then
      print_error "key-value pair [${KV_PAIR}] not in correct format" && exit 1
    fi
    local KEY=$( ${ECHO} "${KV_PAIR}" | ${CUT} -d = -f 1 )
    local VALUE=$( ${ECHO} "${KV_PAIR}" | ${CUT} -d = -f 2 )
    print_debug "Checking key-value pair: ${KEY}=${VALUE}"
    if ! has_element VALID_KEYS "${KEY}"; then
      print_error "${KEY} is not a valid key"
      (( ERROR_COUNT = ERROR_COUNT + 1 ))
    fi
    unset KEY VALUE
  done
  unset KV_PAIR
  local KV_PAIR RR_TYPE RR_HOST RR_RECORD RR_TTL RR_PRIORITY
  local RR_WEIGHT RR_PORT
  [[ "${ERROR_COUNT}" -gt "0" ]] && exit 1
  for KV_PAIR in ${KV_PAIRS}; do
    local KEY=$( ${ECHO} "${KV_PAIR}" | ${CUT} -d = -f 1 )
    local VALUE=$( ${ECHO} "${KV_PAIR}" | ${CUT} -d = -f 2 )
    case ${KEY} in
      "type"     ) local TMPVAR="${VALUE^^}"
                   if validate_rr_value type null "${TMPVAR}"; then
                     RR_TYPE="${TMPVAR}"
                   else
                     print_error "Unsupported record type [${TMPVAR}]"
                     exit 1
                   fi
                   ;;
      "host"     ) if validate_rr_value host null "${VALUE}"; then
                     RR_HOST="${VALUE}"
                   else
                     print_error "Incorrectly formatted host [${VALUE}]"
                     exit 1
                   fi
                   ;;
      "record"   ) # record validation happens at end of the for loop, as we
                   # need RR_TYPE to be set, and params could be passed in any
                   # order
                   RR_RECORD="${VALUE}"
                   ;;
      "ttl"      ) if validate_rr_value ttl null "${VALUE}"; then
                     RR_TTL="${VALUE}"
                   else
                     print_error "Invalid TTL [${VALUE}]"
                     exit 1
                   fi
                   ;;
      "priority" ) if validate_rr_value priority null "${VALUE}"; then
                     RR_PRIORITY="${VALUE}"
                   else
                     print_error "Invalid priority [${VALUE}]"
                     exit 1
                   fi
                   ;;
      "weight"   ) if validate_rr_value weight null "${VALUE}"; then
                     RR_WEIGHT="${VALUE}"
                   else
                     print_error "Invalid weight [${VALUE}]"
                     exit 1
                   fi
                   ;;
      "port"     ) if validate_rr_value port null "${VALUE}"; then
                     RR_PORT="${VALUE}"
                   else
                     print_error "Invalid port [${VALUE}]"
                     exit 1
                   fi
                   ;;
      *          ) print_error "${KEY} is an unknown key" && exit 1
                   ;;
    esac
  done
  unset KV_PAIR
  if [ -z "${RR_TYPE}" ]; then print_error "type=<value> not passed" && exit 1; fi
  if [ -z "${RR_HOST}" ]; then print_error "host=<value> not passed" && exit 1; fi
  if [ -z "${RR_RECORD}" ]; then print_error "record=<value> not passed" && exit 1; fi
  if [ -z "${RR_TTL}" ]; then print_error "ttl=<value> not passed" && exit 1; fi
  if [ "${RR_TYPE}" = "TXT" -o "${RR_TYPE}" = "SPF" ]; then
    # in the case of TXT or SPF records, the record data will most likely
    # contain spaces, and all kinds of other characters. As this is a humble
    # shell script, parsing that as a key=value pair would be horrendous, if
    # not impossible. So, we load the record data from a file.
    print_debug "Attempting to load record data for ${RR_TYPE} record from [${RR_RECORD}]"
    if [ ! -f "${RR_RECORD}" ]; then
      print_error "Unable to load record data from [${RR_RECORD}]" && exit 1
    else
      if [ "$( ${WC} -l ${RR_RECORD} | ${AWK} '{ print $1 }' )" -ne "1" ]; then
        print_error "Input file [${RR_RECORD}] has more than one line" && exit 1
      fi
    fi
  else
    if ! validate_rr_value record "${RR_TYPE}" "${RR_RECORD}"; then
      print_error "record validation failed" && exit 1
    fi
  fi
  if [ "${RR_TYPE}" = "MX" ]; then
    if [ -z "${RR_PRIORITY}" ]; then
      print_error "priority mandatory for MX records" && exit 1
    fi
  fi
  if [ "${RR_TYPE}" = "SRV" ]; then
    local ERROR_COUNT=0
    if [ -z "${RR_PRIORITY}" ]; then
      print_error "priority mandatory for SRV records" && exit 1
      (( ERROR_COUNT = ERROR_COUNT + 1 ))
    fi
    if [ -z "${RR_WEIGHT}" ]; then
      print_error "weight mandatory for SRV records" && exit 1
      (( ERROR_COUNT = ERROR_COUNT + 1 ))
    fi
    if [ -z "${RR_PORT}" ]; then
      print_error "port mandatory for SRV records" && exit 1
      (( ERROR_COUNT = ERROR_COUNT + 1 ))
    fi
    [[ "${ERROR_COUNT}" -gt "0" ]] && exit 1
  fi
  local POST_DATA="${AUTH_POST_DATA} -d domain-name=${ZONE}"
  POST_DATA="${POST_DATA} -d record-type=${RR_TYPE}"
  POST_DATA="${POST_DATA} -d ttl=${RR_TTL}"
  POST_DATA="${POST_DATA} -d host=${RR_HOST}"
  if [ -n "${RR_PRIORITY}" ]; then
    if [ "${RR_TYPE}" = "MX" -o "${RR_TYPE}" = "SRV" ]; then
      POST_DATA="${POST_DATA} -d priority=${RR_PRIORITY}"
    else
      print_error "priority specified for type other than MX or SRV"
      exit 1
    fi
  fi
  if [ -n "${RR_WEIGHT}" ]; then
    if [ "${RR_TYPE}" = "SRV" ]; then
      POST_DATA="${POST_DATA} -d weight=${RR_WEIGHT}"
    else
      print_error "weight specified for type other than SRV"
      exit 1
    fi
  fi
  if [ -n "${RR_PORT}" ]; then
    if [ "${RR_TYPE}" = "SRV" ]; then
      POST_DATA="${POST_DATA} -d port=${RR_PORT}"
    else
      print_error "port specified for type other than SRV"
      exit 1
    fi
  fi
  if [ "${RR_TYPE}" = "TXT" -o "${RR_TYPE}" = "SPF" ]; then
    local RESPONSE=$( ${CURL} -4qs -X POST ${POST_DATA} --data-binary @<( ${ECHO} -ne "record=\"" | ${CAT} - ${RR_RECORD} <( ${ECHO} -ne "\"" ) | ${TR} -d '\n' ) "${API_URL}/add-record.json" )
  else
    POST_DATA="${POST_DATA} -d record=${RR_RECORD}"
    local RESPONSE=$( ${CURL} -4qs -X POST ${POST_DATA} "${API_URL}/add-record.json" )
  fi
  local STATUS=$( ${ECHO} "${RESPONSE}" | ${JQ} -r '.status' )
  local STATUS_DESC=$( ${ECHO} "${RESPONSE}" | ${JQ} -r '.statusDescription' )
  if [ "${STATUS}" = "Failed" ]; then
    print_error "Failed to add record: ${STATUS_DESC}" && exit 1
  elif [ "${STATUS}" = "Success" ]; then
    local ID=$( ${ECHO} "${RESPONSE}" | ${JQ} -r '.data.id' )
    print_timestamp "Record successfully added with id [${ID}]"
  else
    print_error "Unexpected response while adding record" && exit 1
  fi 
}

function check_ipv4_address {
  local IP="$1"
  local NUM_PARTS=$( ${ECHO} "${IP}" | ${AWK} -F . '{ print NF }' )
  if [ "${NUM_PARTS}" -ne "4" ]; then
    return 1
  else
    for OCTET in $( ${ECHO} "${IP}" | ${TR} '.' ' ' ); do
      check_integer "${OCTET}" 0 255
      if [ "$?" -ne "0" ]; then
        return 1
      fi
    done
  fi
  return 0
}

function validate_rr_value {
  local CHECK_TYPE="$1"
  local RECORD_TYPE="$2"
  shift 2
  local VALUE="$@"
  case ${CHECK_TYPE} in
    "type"     ) # we need to check two things here:
                 # 1) is our record type returned by get_record_types
                 # 2) is our record type in SUPPORTED_RECORD_TYPES
                 local -a RECORD_TYPES=( $( get_record_types ) )
                 if has_element RECORD_TYPES "${VALUE}"; then
                   if has_element SUPPORTED_RECORD_TYPES "${VALUE}"; then
                     return 0
                   else
                     return 1
                   fi
                 else
                   return 1
                 fi 
                 ;;
    "host"     ) ${ECHO} "${VALUE}" | ${GREP} -Eqs '^[a-zA-Z0-9\._@-]+$'
                 return $?
                 ;;
    "ttl"      ) local -a AVAILABLE_TTLS=( $( get_available_ttls ) )
                 if has_element AVAILABLE_TTLS "${VALUE}"; then
                   return 0
                 else
                   return 1
                 fi
                 ;;
    "priority" ) check_integer "${VALUE}" 0 65535
                 return $?
                 ;;
    "weight"   ) check_integer "${VALUE}" 0 65535
                 return $?
                 ;;
    "port"     ) check_integer "${VALUE}" 0 65535
                 return $?
                 ;;
    "record"   ) case "${RECORD_TYPE}" in
                   "A"     ) check_ipv4_address "${VALUE}"
                             return $?
                             ;;
                   "CNAME" ) ${ECHO} "${VALUE}" | ${GREP} -Eqs '^[a-zA-Z0-9\.-]+$'
                             return $?
                             ;;
                   "MX"    ) ${ECHO} "${VALUE}" | ${GREP} -Eqs '^[a-zA-Z0-9\.-]+$'
                             return $?
                             ;;
                   "NS"    ) ${ECHO} "${VALUE}" | ${GREP} -Eqs '^[a-zA-Z0-9\.-]+$'
                             return $?
                             ;;
                   "SPF"   ) return 0
                             ;;
                   "SRV"   ) ${ECHO} "${VALUE}" | ${GREP} -Eqs '^[a-zA-Z0-9\.-]+$'
                             return $?
                             ;;
                   "TXT"   ) return 0
                             ;;
                   *       ) return 0
                             ;;
                 esac
                 ;;
    *          ) return 0
                 ;;
  esac
}

function delete_record {
  do_tests
  if [ "$#" -ne "2" ]; then
    print_error "usage: ${THISPROG} delrecord <zone> id=<id>"
    exit 1
  fi
  local ZONE="$1"
  if [[ "${ZONE}" =~ ^.*=.*$ ]]; then
    print_error "[${ZONE}] looks like a key=value pair, not a zone name" && exit 1
  fi
  local LISTED_ZONES
  LISTED_ZONES=$( list_zones | ${GREP} -qs "^${ZONE}:" )
  if [ "$?" -ne "0" ]; then
    print_error "Zone [${ZONE}] not under management" && exit 1
  fi
  shift
  local ID_KV="$1"
  local ID_K=$( ${ECHO} "${ID_KV}" | ${CUT} -d = -f 1 )
  local ID_V=$( ${ECHO} "${ID_KV}" | ${CUT} -d = -f 2 )
  if [ "${ID_K}" != "id" ]; then
    print_error "id=<value> key-value pair not specified" && exit 1
  fi
  if ! [[ "${ID_V}" =~ ^[0-9]+$ ]]; then
    print_error "id is not an integer" && exit 1
  fi
  local ID=${ID_V}
  unset ID_K ID_V ID_KV
  local RECORD_LIST=$( list_records ${ZONE} showid=true )
  local TARGET_RECORD 
  TARGET_RECORD=$( ${ECHO} "${RECORD_LIST}" | ${GREP} "^.*; id=${ID}$" )
  if [ "$?" -ne "0" ]; then
    print_error "No record found with id [${ID}] in zone [${ZONE}]"
    exit 1
  fi
  unset RECORD_LIST
  TARGET_RECORD=$( ${ECHO} "${TARGET_RECORD}" | ${SED} 's/; id=[0-9][0-9]*$//' | ${SED} -r 's/[[:space:]]$//' )
  print_debug "Deleting record [${TARGET_RECORD}]"
  (( ! FORCE )) && {
    local USER_RESPONSE
    ${ECHO} -n "Are you sure you want to delete record with id [${ID}]? [y|n]: "
    read USER_RESPONSE
    if [ "${USER_RESPONSE}" != "y" ]; then
      print_error "Aborting at user request" && exit 1
    fi
  }
  local POST_DATA="${AUTH_POST_DATA} -d domain-name=${ZONE} -d record-id=${ID}"
  local RESPONSE=$( ${CURL} -4qs -X POST ${POST_DATA} "${API_URL}/delete-record.json" )
  local STATUS=$( ${ECHO} "${RESPONSE}" | ${JQ} -r '.status' )
  local STATUS_DESC=$( ${ECHO} "${RESPONSE}" | ${JQ} -r '.statusDescription' )
  if [ "${STATUS}" = "Failed" ]; then
    print_error "Failed to delete record: ${STATUS_DESC}" && exit 1
  elif [ "${STATUS}" = "Success" ]; then
    print_timestamp "Record successfully deleted"
  else
    print_error "Unexpected response while deleting record" && exit 1
  fi
}

function modify_record {
  do_tests
  if [ "$#" -lt "3" ]; then
    print_error "usage: ${THISPROG} modify <zone> id=<id> key=<value> [key=<value> ... key=<value>]"
    exit 1
  fi
  local ZONE="$1"
  if [[ "${ZONE}" =~ ^.*=.*$ ]]; then
    print_error "[${ZONE}] looks like a key=value pair, not a zone name" && exit 1
  fi
  local LISTED_ZONES
  LISTED_ZONES=$( list_zones | ${GREP} -qs "^${ZONE}:" )
  if [ "$?" -ne "0" ]; then
    print_error "Zone [${ZONE}] not under management" && exit 1
  fi
  shift
  local -a VALID_KEYS=( "id" "host" "record" "ttl" "priority" "weight" "port" )
  local KV_PAIRS="$@" ERROR_COUNT=0
  local KV_PAIR
  for KV_PAIR in ${KV_PAIRS}; do
    ${ECHO} "${KV_PAIR}" | ${GREP} -Eqs '^[a-z-]+=.+$'
    if [ "$?" -ne "0" ]; then
      print_error "key-value pair [${KV_PAIR}] not in correct format" && exit 1
    fi
    local KEY=$( ${ECHO} "${KV_PAIR}" | ${CUT} -d = -f 1 )
    local VALUE=$( ${ECHO} "${KV_PAIR}" | ${CUT} -d = -f 2 )
    print_debug "Checking key-value pair: ${KEY}=${VALUE}"
    if ! has_element VALID_KEYS "${KEY}"; then
      print_error "${KEY} is not a valid key"
      (( ERROR_COUNT = ERROR_COUNT + 1 ))
    fi
    unset KEY VALUE
  done
  unset KV_PAIR
  [[ "${ERROR_COUNT}" -gt "0" ]] && exit 1
  local RR_ID RR_HOST RR_RECORD RR_TTL RR_PRIORITY RR_WEIGHT RR_PORT
  for KV_PAIR in ${KV_PAIRS}; do
    local KEY=$( ${ECHO} "${KV_PAIR}" | ${CUT} -d = -f 1 )
    local VALUE=$( ${ECHO} "${KV_PAIR}" | ${CUT} -d = -f 2 )
    case ${KEY} in
      "id"       ) if check_integer "${VALUE}" 0 100000000; then
                     RR_ID="${VALUE}"
                   else
                     print_error "id must be an integer value" && exit 1
                   fi
                   ;; 
      "host"     ) if validate_rr_value host null "${VALUE}"; then
                     RR_HOST="${VALUE}"
                   else
                     print_error "Incorrectly formatted host [${VALUE}]"
                     exit 1
                   fi
                   ;;
      "record"   ) # record validation happens at end of the for loop, as we
                   # need RR_TYPE to be set, and params could be passed in any
                   # order
                   RR_RECORD="${VALUE}"
                   ;;
      "ttl"      ) if validate_rr_value ttl null "${VALUE}"; then
                     RR_TTL="${VALUE}"
                   else
                     print_error "Invalid TTL [${VALUE}]"
                     exit 1
                   fi
                   ;;
      "priority" ) if validate_rr_value priority null "${VALUE}"; then
                     RR_PRIORITY="${VALUE}"
                   else
                     print_error "Invalid priority [${VALUE}]"
                     exit 1
                   fi
                   ;;
      "weight"   ) if validate_rr_value weight null "${VALUE}"; then
                     RR_WEIGHT="${VALUE}"
                   else
                     print_error "Invalid weight [${VALUE}]"
                     exit 1
                   fi
                   ;;
      "port"     ) if validate_rr_value port null "${VALUE}"; then
                     RR_PORT="${VALUE}"
                   else
                     print_error "Invalid port [${VALUE}]"
                     exit 1
                   fi
                   ;;
      *          ) print_error "${KEY} is an unknown key" && exit 1
                   ;;
    esac
  done
  unset KV_PAIR
  # at this point, we have a bunch of variables which may or may not have values
  # depending upon the record type being modified, and the modifications being made
  # we *do*, however, need RR_ID set, at least
  if [ -z "${RR_ID}" ]; then print_error "id=<value> not passed" && exit 1; fi
  # first, we need to try to get a record with this id, to pre-populate some 
  # variables which we may overwrite with user supplied key=value pairs, if they
  # are set. The ClouDNS API has no way of retrieving a record by id. So, we use
  # list_records ${ZONE} showid=true and sift through the output.
  local RECORD_LIST=$( list_records ${ZONE} showid=true )
  local TARGET_RECORD 
  TARGET_RECORD=$( ${ECHO} "${RECORD_LIST}" | ${GREP} "^.*; id=${RR_ID}$" )
  if [ "$?" -ne "0" ]; then
    print_error "No record found with id [${RR_ID}] in zone [${ZONE}]"
    exit 1
  fi
  unset RECORD_LIST
  local GOT_TYPE=$( ${ECHO} "${TARGET_RECORD}" | ${AWK} '{ print $4 }' )
  # preload approriate variables depending on GOT_TYPE. All RRs will have
  # host, ttl, record. MX will have priority. SRV will have priority, weight
  # and port. SPF and TXT could have all kinds of nonsense in the record, but
  # will be surrounded by double quotes. If we are modifying the record value
  # for an SPF or TXT record, we will read the new value in from a file, as we
  # do in add_record()
  local GOT_HOST GOT_TTL GOT_RECORD GOT_PRIORITY GOT_WEIGHT GOT_PORT
  if ! has_element SUPPORTED_RECORD_TYPES "${GOT_TYPE}"; then
    print_error "Trying to modify a record of type [${GOT_TYPE}] is not supported"
    exit 1
  fi
  TARGET_RECORD=$( ${ECHO} "${TARGET_RECORD}" | ${SED} 's/; id=[0-9][0-9]*$//' | ${SED} -r 's/[[:space:]]$//' )
  GOT_HOST=$( ${ECHO} "${TARGET_RECORD}" | ${AWK} '{ print $1 }' )
  GOT_TTL=$( ${ECHO} "${TARGET_RECORD}" | ${AWK} '{ print $2 }' )
  case ${GOT_TYPE} in
    "MX"        ) GOT_PRIORITY=$( ${ECHO} "${TARGET_RECORD}" | ${AWK} '{ print $5 }' )
                  GOT_RECORD=$( ${ECHO} "${TARGET_RECORD}" | ${AWK} '{ print $NF }' )
                  print_debug "got RR data: HOST=[${GOT_HOST}] TTL=[${GOT_TTL}] TYPE=[${GOT_TYPE}] PRIORITY=[${GOT_PRIORITY}] RECORD=[${GOT_RECORD}]"
                  ;;
    "SPF"|"TXT" ) GOT_RECORD=$( ${ECHO} "${TARGET_RECORD}" | ${SED} 's/^.*"\([^"]*\)"$/\1/' )
                  print_debug "got RR data: HOST=[${GOT_HOST}] TTL=[${GOT_TTL}] TYPE=[${GOT_TYPE}] RECORD=[${GOT_RECORD}]"
                  ;;
    "SRV"       ) GOT_PRIORITY=$( ${ECHO} "${TARGET_RECORD}" | ${AWK} '{ print $5 }' )
                  GOT_WEIGHT=$( ${ECHO} "${TARGET_RECORD}" | ${AWK} '{ print $6 }' )
                  GOT_PORT=$( ${ECHO} "${TARGET_RECORD}" | ${AWK} '{ print $7 }' )
                  GOT_RECORD=$( ${ECHO} "${TARGET_RECORD}" | ${AWK} '{ print $NF }' )
                  print_debug "got RR data: HOST=[${GOT_HOST}] TTL=[${GOT_TTL}] TYPE=[${GOT_TYPE}] PRIORITY=[${GOT_PRIORITY}] WEIGHT=[${GOT_WEIGHT}] PORT=[${GOT_PORT}] RECORD=[${GOT_RECORD}]"
                  ;;
    *           ) GOT_RECORD=$( ${ECHO} "${TARGET_RECORD}" | ${AWK} '{ print $NF }' )
                  print_debug "got RR data: HOST=[${GOT_HOST}] TTL=[${GOT_TTL}] TYPE=[${GOT_TYPE}] RECORD=[${GOT_RECORD}]"
                  ;;
  esac
  # so, we now have our required variables set, pre-populated from the existing record.
  # now, if we are modifying an SPF or TXT record's record field, load in the value from
  # the specified file
  case ${GOT_TYPE} in
    "SPF"|"TXT" ) if [ ! -f "${RR_RECORD}" ]; then
                    print_error "Unable to load record data from [${RR_RECORD}]" && exit 1
                  else
                    if [ "$( ${WC} -l ${RR_RECORD} | ${AWK} '{ print $1 }' )" -ne "1" ]; then
                      print_error "Input file [${RR_RECORD}] has more than one line" && exit 1
                    else
                      RR_RECORD="$( ${CAT} ${RR_RECORD} )"
                    fi
                  fi
                  ;;
  esac
  local CHANGED=0
  [[ -n "${RR_HOST}" ]] && {
    [[ "${RR_HOST}" != "${GOT_HOST}" ]] && {
      GOT_HOST="${RR_HOST}"
      (( CHANGED = CHANGED + 1 ))
    } || {
      print_timestamp "host value same as existing"
    }
  }
  [[ -n "${RR_TTL}" ]] && {
    [[ "${RR_TTL}" != "${GOT_TTL}" ]] && {
      GOT_TTL="${RR_TTL}"
      (( CHANGED = CHANGED + 1 ))
    } || {
      print_timestamp "ttl value same as existing"
    }
  }
  [[ -n "${RR_RECORD}" ]] && {
    [[ "${RR_RECORD}" != "${GOT_RECORD}" ]] && {
      GOT_RECORD="${RR_RECORD}"
      (( CHANGED = CHANGED + 1 ))
    } || {
      print_timestamp "record value same as existing"
    }
  }
  [[ -n "${RR_PRIORITY}" ]] && {
    [[ "${RR_PRIORITY}" != "${GOT_PRIORITY}" ]] && {
      GOT_PRIORITY="${RR_PRIORITY}"
      (( CHANGED = CHANGED + 1 ))
    } || {
      print_timestamp "priority value same as existing"
    }
  }
  [[ -n "${RR_WEIGHT}" ]] && {
    [[ "${RR_WEIGHT}" != "${GOT_WEIGHT}" ]] && {
      GOT_WEIGHT="${RR_WEIGHT}"
      (( CHANGED = CHANGED + 1 ))
    } || {
      print_timestamp "weight value same as existing"
    }
  }
  [[ -n "${RR_PORT}" ]] && {
    [[ "${RR_PORT}" != "${GOT_PORT}" ]] && {
      GOT_PORT="${RR_PORT}"
      (( CHANGED = CHANGED + 1 ))
    } || {
      print_timestamp "port value same as existing"
    }
  }
  [[ "${CHANGED}" -eq "0" ]] && {
    print_timestamp "Nothing has changed - no need to modify" && exit 0
  }
  local POST_DATA="${AUTH_POST_DATA} -d domain-name=${ZONE}"
  POST_DATA="${POST_DATA} -d record-id=${RR_ID}"
  POST_DATA="${POST_DATA} -d host=${GOT_HOST}"
  POST_DATA="${POST_DATA} -d ttl=${GOT_TTL}"
  if [ -n "${RR_PRIORITY}" ]; then
    if [ "${GOT_TYPE}" != "MX" -a "${GOT_TYPE}" != "SRV" ]; then
      print_error "priority specified for type other than MX or SRV"
      exit 1
    fi
  fi
  if [ -n "${RR_WEIGHT}" ]; then
    if [ "${GOT_TYPE}" != "SRV" ]; then
      print_error "weight specified for type other than SRV"
      exit 1
    fi
  fi
  if [ -n "${RR_PORT}" ]; then
    if [ "${GOT_TYPE}" != "SRV" ]; then
      print_error "port specified for type other than SRV"
      exit 1
    fi
  fi
  if [ "${GOT_TYPE}" = "MX" -o "${GOT_TYPE}" = "SRV" ]; then
    POST_DATA="${POST_DATA} -d priority=${GOT_PRIORITY}"
  fi
  if [ "${GOT_TYPE}" = "SRV" ]; then
    POST_DATA="${POST_DATA} -d weight=${GOT_WEIGHT} -d port=${GOT_PORT}"
  fi
  if [ "${GOT_TYPE}" = "TXT" -o "${GOT_TYPE}" = "SPF" ]; then
    local RESPONSE=$( ${CURL} -4qs -X POST ${POST_DATA} --data-binary @<( ${ECHO} -ne "record=\"${GOT_RECORD}\"" ) "${API_URL}/mod-record.json" )
  else
    POST_DATA="${POST_DATA} -d record=${GOT_RECORD}"
    local RESPONSE=$( ${CURL} -4qs -X POST ${POST_DATA} "${API_URL}/mod-record.json" )
  fi
  local STATUS=$( ${ECHO} "${RESPONSE}" | ${JQ} -r '.status' )
  local STATUS_DESC=$( ${ECHO} "${RESPONSE}" | ${JQ} -r '.statusDescription' )
  if [ "${STATUS}" = "Failed" ]; then
    print_error "Failed to modify record: ${STATUS_DESC}" && exit 1
  elif [ "${STATUS}" = "Success" ]; then
    print_timestamp "Record successfully modified"
  else
    print_error "Unexpected response while modifying record" && exit 1
  fi
}

function add_zone {
  do_tests
  if [ "$#" -ne "1" ]; then
    print_error "addzone expects exactly one argument" && exit 1
  fi
  local ZONE="$1"
  local ZONE_TYPE="master" # we only support master zones
  print_debug "Adding new ${ZONE_TYPE} zone for [${ZONE}]"
  local POST_DATA="${AUTH_POST_DATA} -d zone-type=${ZONE_TYPE} -d domain-name=${ZONE}"
  local RESPONSE=$( ${CURL} -4qs -X POST ${POST_DATA} "${API_URL}/register.json" )
  local STATUS=$( ${ECHO} "${RESPONSE}" | ${JQ} -r '.status' )
  local STATUS_DESC=$( ${ECHO} "${RESPONSE}" | ${JQ} -r '.statusDescription' )
  if [ "${STATUS}" = "Failed" ]; then
    print_error "Failed to add zone [${ZONE}]: ${STATUS_DESC}" && exit 1
  elif [ "${STATUS}" = "Success" ]; then
    print_timestamp "New zone [${ZONE}] added"
  else
    print_error "Unexpected response while adding zone [${ZONE}]" && exit 1
  fi
}

function delete_zone {
  do_tests
  if [ "$#" -ne "1" ]; then
    print_error "delzone expects exactly one argument" && exit 1
  fi
  local ZONE="$1"
  local LISTED_ZONES
  LISTED_ZONES=$( list_zones | ${GREP} -qs "^${ZONE}:" )
  if [ "$?" -ne "0" ]; then
    print_error "Zone [${ZONE}] not under management" && exit 1
  fi
  print_debug "Deleting zone [${ZONE}]"
  ${ECHO} "Are you sure you want to delete zone [${ZONE}]?"
  ${ECHO} -n "You must type I-AM-SURE, exactly: "
  local RESPONSE=""
  builtin read RESPONSE
  if [ "${RESPONSE}" != "I-AM-SURE" ]; then
    print_error "Aborting removal of zone [${ZONE}]" && exit 1
  fi
  ${ECHO} "Okay. Waiting ${REMOVAL_WAIT}s prior to removal. CTRL-C now if unsure!"
  ${SLEEP} ${REMOVAL_WAIT}
  local POST_DATA="${AUTH_POST_DATA} -d domain-name=${ZONE}"
  local RESPONSE=$( ${CURL} -4qs -X POST ${POST_DATA} "${API_URL}/delete.json" )
  local STATUS=$( ${ECHO} "${RESPONSE}" | ${JQ} -r '.status' )
  local STATUS_DESC=$( ${ECHO} "${RESPONSE}" | ${JQ} -r '.statusDescription' )
  if [ "${STATUS}" = "Failed" ]; then
    print_error "Unable to delete zone [${ZONE}]: ${STATUS_DESC}" && exit 1
  elif [ "${STATUS}" = "Success" ]; then
    print_timestamp "Zone [${ZONE}] deleted"
  else
    print_error "Unexpected response while deleting zone [${ZONE}]" && exit 1
  fi
}

function list_zones {
  do_tests
  local PAGE_COUNT=$( get_page_count )
  local COUNTER=0
  local POST_DATA="${AUTH_POST_DATA} -d page=0 -d rows-per-page=${ROWS_PER_PAGE}"
  while [ "${COUNTER}" -lt "${PAGE_COUNT}" ]; do
    print_debug "Processing listzones page=$(( ${COUNTER} + 1 )) with rows-per-page=${ROWS_PER_PAGE}"
    POST_DATA=$( ${ECHO} "${POST_DATA}" |\
                 ${SED} "s/^\(.*-d page=\)[0-9][0-9]*\( .*\)$/\1$(( ${COUNTER} + 1 ))\2/" )
    local OUTPUT=$( ${CURL} -4qs -X POST ${POST_DATA} "${API_URL}/list-zones.json" | ${JQ} -r . )
    ${ECHO} "${OUTPUT}" | ${JQ} -r '.[] | .name + ":" + .type'
    (( COUNTER = COUNTER + 1 ))
  done
}

function call_helper {
  do_tests
  if [ "$#" -ne "1" ]; then
    print_error "helper expects exactly one argument" && exit 1
  fi
  local HELPER_FUNCTION="$1"
  print_debug "Calling helper function ${HELPER_FUNCTION}()"
  case ${HELPER_FUNCTION} in
    "get_available_ttls" ) get_available_ttls ;;
    "get_record_types"   ) get_record_types   ;;
    "get_page_count"     ) get_page_count     ;;
    *                    ) print_error "No such helper function ${HELPER_FUNCTION}"
                           exit 1             ;;
  esac
}

function test_login {
  # don't check SKIP_TESTS here as this is the "test" command
  test_api_url
  do_login
  if [ "$?" -eq "0" ]; then
    print_timestamp "Login test successful"
  else
    print_error "Login test failed"
    exit 1
  fi
}

while ${GETOPTS} ":dfhjs" OPTION; do
  case ${OPTION} in
    "d") DEBUG=1               ;;
    "f") FORCE=1               ;;
    "h") print_usage && exit 0 ;;
    "j") JSON=1                ;;
    "s") SKIP_TESTS=1          ;;
    *  ) print_usage && exit 1 ;;
  esac
done

shift $(( ${OPTIND} - 1 ))

if [ "$#" -eq "0" ]; then
  print_usage && exit 1
fi

check_jq
check_environment_variables
set_auth_post_data
process_arguments "$@"

exit 0
