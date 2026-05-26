#!/bin/bash
#
# Monitor plugin for checking PureStorage FlashArray / FlashBlade via REST API v2
#
# Author:
#   Felix Longardt <monitoring@longardt.com>
#
# Version history:
# 2026-05-26 Felix Longardt <monitoring@longardt.com>
# Release: 2.8.0
#   -eNIPerf: add interface line-speed from /network-interfaces; calculate RX/TX
#             utilisation as % of line speed; --warn-ni-bw (default 80%) and
#             --crit-ni-bw (default 90%) thresholds; perfdata includes
#             warn/crit/max in bytes/sec per interface
#   -eNIPerf: add --warn-ni-errors (default 1) / --crit-ni-errors (default 10)
#             thresholds for errors/sec per interface
#   Replace all unicode -> arrows with ASCII ->
#   -ePatch: extract version and upgrade_hops from catalog items directly;
#            show upgrade path only when patch is not installed/not_applicable;
#            remove redundant /software-versions call (versions in catalog)
#   -eSW: show upgrade path only when software item is not in ok state
#
# 2026-05-23 Felix Longardt <monitoring@longardt.com>
# Release: 2.7.0
#   Add syslog-servers check (-eSyslog): /syslog-servers — URI presence check with strict/non-strict mode
#   --syslog-server <uri[,uri]>: WARNING if any expected URI is missing (subset check)
#   --syslog-servers-strict: require exact match of the full configured URI list
#
# 2026-05-23 Felix Longardt <monitoring@longardt.com>
# Release: 2.6.0
#   Add software patches check (-ePatch): /software-patches/catalog + /software-versions (verbose)
#   Add software/upgrade check (-eSW): /software + /software-check (verbose)
#   Both: null/empty response -> OK (not mandatory); status mapped to warn/crit per documented table
#   Patches: installed/not_applicable -> OK; download_failed/failed -> CRIT; all others -> WARN
#   Software: installed/new -> OK; download_failed/failed/aborting/abort/canceled/partially_installed -> CRIT; others -> WARN
#
# 2026-05-23 Felix Longardt <monitoring@longardt.com>
# Release: 2.5.0
#   Add offloads check (-eOff): /offloads — status, space, protocol detail per target
#   Null/empty response -> OK (offloads not mandatory)
#   connected/scanning -> OK; connecting/disconnecting -> WARN; not connected -> CRIT
#   Protocol detail: NFS address:mountpoint, S3 uri/bucket, Azure account/container, GCS bucket
#
# 2026-05-23 Felix Longardt <monitoring@longardt.com>
# Release: 2.4.0
#   Network: add /network-interfaces/performance (-eNIPerf)
#     Per-interface RX/TX bandwidth, packet rates, error rates; ETH and FC support
#   Network: add /network-interfaces/port-details (-eNIPort)
#     Optical transceiver health: rx/tx power, temperature, tx bias, voltage
#     tx_fault=true -> CRIT; status alarm -> CRIT; status warn -> WARN
#   Network: add /network-interfaces/neighbors (-eNINbr)
#     LLDP neighbor discovery: local port -> switch name + switch port (verbose)
#   Fix snapshot transfer empty Progress/Transferred/Written values
#     Replace parallel mapfile calls with single jq->awk TSV pipeline (guaranteed field alignment)
#
# 2026-05-22 Felix Longardt <monitoring@longardt.com>
# Release: 2.3.0
#   Volumes: add /volume-snapshots and /volume-snapshots/transfer checks
#   Volumes: add -wVol/-cVol thresholds (physical % of provisioned, default 80/90)
#   Volumes: add --blacklist-volumes and --select-volumes filters
#   Volumes: per-volume threshold checks always run (not only in verbose)
#   Volumes: combined space+perf+latency per-volume detail line
#   Volumes: fix count (use .items|length instead of .total_item_count)
#   Volumes: --perfdata flag shows performance summary without --verbose
#   Subscriptions: treat null/error response as OK (no additional license)
#   Add --perfdata flag for showing current performance data in output
#
# 2026-05-21 Felix Longardt <monitoring@longardt.com>
# Release: 2.2.0
#   Add -eM / --enable-metrics: collect metrics catalog via /metrics
#   and latest values via /metrics/history; emit all as perfdata
#
# 2026-05-21 Felix Longardt <monitoring@longardt.com>
# Release: 2.1.0
#   Fix cert expiry parsing for epoch-ms timestamps
#   Fix pod mediator "unknown" treated as WARNING (only DISCONNECTED warns)
#   Fix ConnPath/ReplicaLink "unknown" source/destination display
#   Suppress Rev field when not returned by array
#   Add file-systems/users/performance to -eP check
#
# 2026-05-20 Felix Longardt <monitoring@longardt.com>
# Release: 2.0.0
#   Switch to direct FlashArray/FlashBlade REST API v2 (no Pure1 cloud)
#   Auth via API token or username/password — no RSA key file, no openssl required
#   Use --insecure for self-signed array certificates
#
# 2026-05-19 Felix Longardt <monitoring@longardt.com>
# Release: 1.3.0
#   Add replication (-eRep), connectors (-eConn), object store (-eOS)
#
# 2026-05-19 Felix Longardt <monitoring@longardt.com>
# Release: 1.2.0
#   Add quota (-eQ), network interface (-eNI), FS/bucket performance
#   Add --disable-X flags; default all-enabled
#
# 2026-05-19 Felix Longardt <monitoring@longardt.com>
# Release: 1.1.0
#   Add directory (-eDi) and bucket (-eBu) checks
#
# 2026-05-18 Felix Longardt <monitoring@longardt.com>
# Release: 1.0.0
#   Initial release


## VARIABLES
PROGNAME="${0##*/}"
PROGPATH="${0%/*}"
REVISION="2.8.0"
JQ="$(which jq)"
CURL="$(which curl)"
AWK="$(which awk)"

# REST API v2 performance field names
PERF_READ_IOPS="reads_per_sec"
PERF_WRITE_IOPS="writes_per_sec"
PERF_MIRROR_IOPS="mirrored_writes_per_sec"
PERF_READ_BW="input_per_sec"
PERF_WRITE_BW="output_per_sec"
PERF_MIRROR_BW="mirrored_input_per_sec"
PERF_READ_LAT="usec_per_read_op"
PERF_WRITE_LAT="usec_per_write_op"
PERF_MIRROR_LAT="usec_per_mirrored_write_op"
PERF_QUEUE="queue_depth"
PERF_LOAD="load_metric"


exit_unknown() {
	echo "Unknown parameter: ${1}"
	print_usage
	exit 4
}

# Return 0 if every comma-separated token in $1 appears in $2 (also comma-separated)
_servers_subset() {
	local IFS=','
	local exp cfg found
	for exp in $1; do
		found=0
		for cfg in $2; do
			[[ "${cfg}" == "${exp}" ]] && found=1 && break
		done
		[[ "${found}" -eq 0 ]] && return 1
	done
	return 0
}


## FUNCTIONS
print_usage() {
	echo "Usage: ${PROGNAME} [-h] [-V] -H <host> { -a <api_token> | -U <user> -P <pass> } [-opts] [-w <warn>] [-c <crit>]"
}

print_revision() {
	echo "${1} - v${2}"
}

print_help() {
	print_revision "${PROGNAME}" "${REVISION}"
	echo ""
	print_usage
cat << EOM


 This plugin monitors PureStorage FlashArray and FlashBlade appliances via the
 direct REST API v2 (https://<host>/api/<version>/).

 Connects directly to the array - no Pure1 cloud account required.
 Uses HTTPS with --insecure to accept self-signed array certificates.
 Authentication via API token or username/password.

Options:
 -h, --help
    Print detailed help screen
 -V, --version
    Print version information

 -H, --host <hostname|IP>
    Hostname or IP address of the FlashArray or FlashBlade
 -a, --api-token <token>
    API token (generated per user in array GUI: Settings > Users > API tokens)
 -U, --username <username>
    Username for login-based authentication
 -P, --password <password>
    Password for login-based authentication
 -T, --token <x_auth_token>
    Pre-obtained x-auth-token session token — skips login (testing / CI)

 --api-version <version>
    REST API version to use, e.g. 2.34 (default: auto-detect latest 2.x)

 -N, --array-name <name>
    Expected array name — exits UNKNOWN if connected array does not match
 --ntp-server <server[,server,...]>
    Expected NTP server(s), comma-separated — WARNING if any expected server is missing
    (subset check: extra configured servers are allowed)
 --ntp-servers-strict
    Make --ntp-server an exact match (no extra servers allowed)
 --timezone <tz>
    Expected timezone string (e.g. Europe/Berlin) — WARNING if array TZ differs
 --dns-server <server[,server,...]>
    Expected DNS nameserver(s), comma-separated — WARNING if any expected server is missing
    (subset check: extra configured servers are allowed)
 --dns-servers-strict
    Make --dns-server an exact match (no extra servers allowed)
 --syslog-server <uri[,uri,...]>
    Expected syslog server URI(s), comma-separated — WARNING if any expected URI is missing
    (subset check: extra configured servers are allowed)
 --syslog-servers-strict
    Make --syslog-server an exact match (no extra servers allowed)

 Enable flags (opt-in — if any -eX flag is given, only those checks run):
 -eAr, --enable-arrays
    Array info: name, OS, Purity version, revision
 -eS,  --enable-space
    Space / capacity utilization (thresholds: -w / -c)
 -eH,  --enable-hardware
    Hardware component health with temperature
 -eConn, --enable-connectors
    Hardware connector / port health (FC, iSCSI, NVMe-oF, Ethernet ports)
 -eCTRL, --enable-controllers
    Controller status and mode (primary/secondary/ready)
 -eD,  --enable-drives
    Drive health
 -eBl, --enable-blades
    FlashBlade blade health and raw capacity
 -eP,  --enable-performance
    I/O performance: array + file-system + bucket (IOPS, BW, latency, mirror)
 -eVol, --enable-volumes
    Volume space and per-volume I/O performance (FlashArray)
 -eSnap, --enable-snapshots
    Volume snapshots: count, space, DR, per-snapshot detail (FlashArray)
 -eSnapXfer, --enable-snapshot-transfers
    Volume snapshot transfers: active transfers, progress, data written (FlashArray)
 -eFS, --enable-filesystems
    FlashBlade file-system space / writable state (thresholds: -w / -c)
 -eDi, --enable-directories
    FlashBlade directory space / quota (thresholds: -w / -c)
 -eBu, --enable-buckets
    FlashBlade S3 bucket space and object count
 -eOS, --enable-object-store
    FlashBlade S3 object store account space and object count
 -eQ,  --enable-quotas
    FlashBlade user/group quota check (thresholds: -w / -c)
 -eNI, --enable-network
    Network interface status and port details (FC/iSCSI/NVMe-oF)
 -eNIPerf, --enable-ni-performance
    Per-interface RX/TX bandwidth, packet rates, and error rates (perfdata)
 -eNIPort, --enable-ni-port-details
    Optical transceiver health: rx/tx power, temperature, tx bias, voltage (warn/alarm thresholds)
 -eNINbr, --enable-ni-neighbors
    LLDP neighbor discovery: show connected switch ports per interface (verbose)
 -eOff, --enable-offloads
    Offload targets (NFS/S3/Azure/GCS): status, space usage, protocol detail
 -ePatch, --enable-patches
    Software patch catalog: installed/available/failed state per patch (verbose: current versions)
 -eSW, --enable-software
    Software/upgrade status: in-progress or failed upgrades (verbose: upgrade plan + pre-check results)
 -eDNS, --enable-dns
    DNS configuration check
 -eSyslog, --enable-syslog
    Syslog server configuration check (optional: --syslog-server for URI verification)
 -eRep, --enable-replication
    Replication health: pods, array connections, replica-link lag
 -eCert, --enable-certs
    Certificate expiry check
 -eAl, --enable-alerts
    Open alerts
 -eSub, --enable-subscriptions
    Subscription status and expiry check
 -eM,  --enable-metrics
    Collect available metrics via /metrics + /metrics/history (perfdata only)
 -A,   --enable-all
    Enable all available checks (default when no flags given)

 Disable flags (opt-out — suppress individual modules from the default set):
 --disable-arrays        --disable-space         --disable-hardware
 --disable-connectors    --disable-controllers   --disable-drives        --disable-blades
 --disable-performance   --disable-volumes
 --disable-filesystems   --disable-directories   --disable-buckets       --disable-object-store
 --disable-quotas        --disable-network       --disable-dns           --disable-replication
 --disable-certs         --disable-alerts        --disable-subscriptions --disable-license
 --disable-metrics       --disable-snapshots     --disable-snapshot-transfers
 --disable-ni-performance  --disable-ni-port-details  --disable-ni-neighbors
 --disable-offloads         --disable-patches       --disable-software
 --disable-syslog

 -w,  --warning  <integer>
    WARNING threshold for space/quota/directory in % (default: 80)
 -c,  --critical <integer>
    CRITICAL threshold for space/quota/directory in % (default: 90)
 --warn-temp <integer>
    WARNING threshold for component temperature in °C (default: 65)
 --crit-temp <integer>
    CRITICAL threshold for component temperature in °C (default: 75)
 --warn-cert <integer>
    WARNING threshold for certificate expiry in days (default: 30)
 --crit-cert <integer>
    CRITICAL threshold for certificate expiry in days (default: 15)
 --warn-sub <integer>
    WARNING threshold for subscription expiry in days (default: 30)
 --crit-sub <integer>
    CRITICAL threshold for subscription expiry in days (default: 15)

 -wIO <iops>
    WARNING threshold for total array IOPS (default: none)
 -cIO <iops>
    CRITICAL threshold for total array IOPS (default: none)
 -wBW <MB/s>
    WARNING threshold for array bandwidth in MB/s (read or write peak, default: none)
 -cBW <MB/s>
    CRITICAL threshold for array bandwidth in MB/s (default: none)
 -wLat <ms>
    WARNING threshold for array read/write latency in ms (default: none)
 -cLat <ms>
    CRITICAL threshold for array read/write latency in ms (default: none)
 -wVol <%>
    WARNING threshold: volume physical usage as %% of provisioned (default: 80)
 -cVol <%>
    CRITICAL threshold: volume physical usage as %% of provisioned (default: 90)

 --blacklist-alarmcode <list>
    Comma-separated list of alert codes to ignore entirely (e.g. 111,112,113)
 --blacklist-volumes <list>
    Comma-separated list of volume names to skip in per-volume checks (e.g. vol1,vol2)
 --select-volumes <list>
    Comma-separated list of volume names to check exclusively (e.g. vol1,vol2)
 --blacklist-nics <list>
    Comma-separated list of NIC names to skip entirely (e.g. eth88,eth89)
 --warn-ni-bw <pct>
    WARNING threshold for per-interface RX or TX utilisation in %% of line speed
    (default: 80)
 --crit-ni-bw <pct>
    CRITICAL threshold for per-interface RX or TX utilisation in %% of line speed
    (default: 90)
 --warn-ni-errors <n>
    WARNING threshold for per-interface errors/sec (default: 1)
 --crit-ni-errors <n>
    CRITICAL threshold for per-interface errors/sec (default: 10)
 -u,  --bw-unit  <unit>
    Bandwidth display unit: auto | B | KB | MB | GB (default: auto)
 --perfdata
    Show current performance data in output (e.g. --enable-volumes --perfdata)
 --no-perfdata
    Suppress the perfdata section entirely (no | output)
 -s,  --silent
    Show only problem lines (suppress OK detail)
 -v,  --verbose
    Print section headers and extra detail
 -d,  --debug
    Enable bash debug output (set -x)

Example: ${PROGNAME} -H 10.0.0.100 -a fad28db0-xxxx-yyyy-zzzz -A -w 80 -c 90
         ${PROGNAME} -H myarray.example.com -U monitor -P secret --disable-drives -v
         ${PROGNAME} -H 10.0.0.100 -T abc123def456 -eAr -eAl


EOM
}


## BEGIN
# Grab command line arguments
while [[ -n "${1}" ]]; do
	case "${1}" in
	-h|--help)
		print_help
		exit 0
		;;
	-V|--version)
		print_revision "${PROGNAME}" "${REVISION}"
		exit 0
		;;
	-H|--host)
		shift
		array_host="${1}"
		;;
	-a|--api-token)
		shift
		api_token="${1}"
		;;
	-U|--username)
		shift
		api_user="${1}"
		;;
	-P|--password)
		shift
		api_pass="${1}"
		;;
	-T|--token)
		shift
		x_auth_token="${1}"
		;;
	--api-version)
		shift
		api_version="${1}"
		;;
	-N|--array-name)
		shift
		array_filter="${1}"
		;;
	--ntp-server)
		shift
		check_ntp="${1}"
		;;
	--ntp-servers-strict)
		ntp_strict=1
		;;
	--timezone)
		shift
		check_tz="${1}"
		;;
	--dns-server)
		shift
		check_dns="${1}"
		;;
	--dns-servers-strict)
		dns_strict=1
		;;
	--syslog-server)
		shift
		check_syslog="${1}"
		;;
	--syslog-servers-strict)
		syslog_strict=1
		;;
	-eAr|--enable-arrays)
		enable_arrays=1
		;;
	-eS|--enable-space)
		enable_space=1
		;;
	-eH|--enable-hardware)
		enable_hardware=1
		;;
	-eConn|--enable-connectors)
		enable_conn=1
		;;
	-eCTRL|--enable-controllers)
		enable_ctrl=1
		;;
	-eD|--enable-drives)
		enable_drives=1
		;;
	-eBl|--enable-blades)
		enable_blades=1
		;;
	-eP|--enable-performance)
		enable_perf=1
		;;
	-eVol|--enable-volumes)
		enable_vol=1
		;;
	-eSnap|--enable-snapshots)
		enable_snaps=1
		;;
	-eSnapXfer|--enable-snapshot-transfers)
		enable_snaps_xfer=1
		;;
	-eFS|--enable-filesystems)
		enable_fs=1
		;;
	-eDi|--enable-directories)
		enable_dirs=1
		;;
	-eBu|--enable-buckets)
		enable_buckets=1
		;;
	-eOS|--enable-object-store)
		enable_os=1
		;;
	-eQ|--enable-quotas)
		enable_quotas=1
		;;
	-eNI|--enable-network)
		enable_network=1
		;;
	-eDNS|--enable-dns)
		enable_dns=1
		;;
	-eSyslog|--enable-syslog)
		enable_syslog=1
		;;
	-eRep|--enable-replication)
		enable_repl=1
		;;
	-eCert|--enable-certs)
		enable_certs=1
		;;
	-eAl|--enable-alerts)
		enable_alerts=1
		;;
	-eSub|--enable-subscriptions)
		enable_subs=1
		;;
	-eM|--enable-metrics)
		enable_metrics=1
		;;
	-A|--enable-all)
		enable_all=1
		;;
	--disable-arrays)
		disable_arrays=1
		;;
	--disable-space)
		disable_space=1
		;;
	--disable-hardware)
		disable_hardware=1
		;;
	--disable-connectors)
		disable_conn=1
		;;
	--disable-controllers)
		disable_ctrl=1
		;;
	--disable-drives)
		disable_drives=1
		;;
	--disable-blades)
		disable_blades=1
		;;
	--disable-performance)
		disable_perf=1
		;;
	--disable-volumes)
		disable_vol=1
		;;
	--disable-snapshots)
		disable_snaps=1
		;;
	--disable-snapshot-transfers)
		disable_snaps_xfer=1
		;;
	--disable-filesystems)
		disable_fs=1
		;;
	--disable-directories)
		disable_dirs=1
		;;
	--disable-buckets)
		disable_buckets=1
		;;
	--disable-object-store)
		disable_os=1
		;;
	--disable-quotas)
		disable_quotas=1
		;;
	--disable-network)
		disable_network=1
		;;
	--disable-dns)
		disable_dns=1
		;;
	--disable-syslog)
		disable_syslog=1
		;;
	--disable-replication)
		disable_repl=1
		;;
	--disable-certs)
		disable_certs=1
		;;
	--disable-alerts)
		disable_alerts=1
		;;
	--disable-subscriptions|--disable-license)
		disable_subs=1
		;;
	--disable-metrics)
		disable_metrics=1
		;;
	--no-perfdata)
		no_perfdata=1
		;;
	-w|--warning)
		shift
		warning="${1//%}"
		[[ "${warning}" =~ [0-9].* ]] || exit_unknown "${1}"
		;;
	-c|--critical)
		shift
		critical="${1//%}"
		[[ "${critical}" =~ [0-9].* ]] || exit_unknown "${1}"
		;;
	--warn-temp)
		shift
		warn_temp="${1}"
		[[ "${warn_temp}" =~ [0-9].* ]] || exit_unknown "${1}"
		;;
	--crit-temp)
		shift
		crit_temp="${1}"
		[[ "${crit_temp}" =~ [0-9].* ]] || exit_unknown "${1}"
		;;
	--warn-cert)
		shift
		warn_cert="${1}"
		[[ "${warn_cert}" =~ [0-9].* ]] || exit_unknown "${1}"
		;;
	--crit-cert)
		shift
		crit_cert="${1}"
		[[ "${crit_cert}" =~ [0-9].* ]] || exit_unknown "${1}"
		;;
	--warn-sub)
		shift
		warn_sub="${1}"
		[[ "${warn_sub}" =~ [0-9].* ]] || exit_unknown "${1}"
		;;
	--crit-sub)
		shift
		crit_sub="${1}"
		[[ "${crit_sub}" =~ [0-9].* ]] || exit_unknown "${1}"
		;;
	-wIO)
		shift
		warn_iops="${1}"
		[[ "${warn_iops}" =~ ^[0-9]+$ ]] || exit_unknown "${1}"
		;;
	-cIO)
		shift
		crit_iops="${1}"
		[[ "${crit_iops}" =~ ^[0-9]+$ ]] || exit_unknown "${1}"
		;;
	-wBW)
		shift
		warn_bw_mbps="${1}"
		[[ "${warn_bw_mbps}" =~ ^[0-9] ]] || exit_unknown "${1}"
		;;
	-cBW)
		shift
		crit_bw_mbps="${1}"
		[[ "${crit_bw_mbps}" =~ ^[0-9] ]] || exit_unknown "${1}"
		;;
	-wLat)
		shift
		warn_lat_ms="${1}"
		[[ "${warn_lat_ms}" =~ ^[0-9] ]] || exit_unknown "${1}"
		;;
	-cLat)
		shift
		crit_lat_ms="${1}"
		[[ "${crit_lat_ms}" =~ ^[0-9] ]] || exit_unknown "${1}"
		;;
	-wVol)
		shift
		warn_vol="${1}"
		[[ "${warn_vol}" =~ ^[0-9] ]] || exit_unknown "${1}"
		;;
	-cVol)
		shift
		crit_vol="${1}"
		[[ "${crit_vol}" =~ ^[0-9] ]] || exit_unknown "${1}"
		;;
	--blacklist-volumes)
		shift
		vol_blacklist="${1}"
		;;
	--select-volumes)
		shift
		vol_select="${1}"
		;;
	--blacklist-alarmcode)
		shift
		al_blacklist="${1}"
		;;
	--blacklist-nics)
		shift
		ni_blacklist="${1}"
		;;
	--warn-ni-bw)
		shift
		warn_ni_bw="${1}"
		[[ "${warn_ni_bw}" =~ ^[0-9]+$ ]] || exit_unknown "--warn-ni-bw requires an integer"
		;;
	--crit-ni-bw)
		shift
		crit_ni_bw="${1}"
		[[ "${crit_ni_bw}" =~ ^[0-9]+$ ]] || exit_unknown "--crit-ni-bw requires an integer"
		;;
	--warn-ni-errors)
		shift
		warn_ni_errors="${1}"
		[[ "${warn_ni_errors}" =~ ^[0-9]+$ ]] || exit_unknown "--warn-ni-errors requires an integer"
		;;
	--crit-ni-errors)
		shift
		crit_ni_errors="${1}"
		[[ "${crit_ni_errors}" =~ ^[0-9]+$ ]] || exit_unknown "--crit-ni-errors requires an integer"
		;;
	-eNIPerf|--enable-ni-performance)
		enable_ni_perf=1
		;;
	-eNIPort|--enable-ni-port-details)
		enable_ni_port=1
		;;
	-eNINbr|--enable-ni-neighbors)
		enable_ni_nbr=1
		;;
	--disable-ni-performance)
		disable_ni_perf=1
		;;
	--disable-ni-port-details)
		disable_ni_port=1
		;;
	--disable-ni-neighbors)
		disable_ni_nbr=1
		;;
	-eOff|--enable-offloads)
		enable_off=1
		;;
	--disable-offloads)
		disable_off=1
		;;
	-ePatch|--enable-patches)
		enable_patch=1
		;;
	--disable-patches)
		disable_patch=1
		;;
	-eSW|--enable-software)
		enable_sw=1
		;;
	--disable-software)
		disable_sw=1
		;;
	-u|--bw-unit)
		shift
		bw_unit="${1^^}"
		;;
	-s|--silent)
		silent=1
		;;
	--perfdata)
		show_perfdata=1
		;;
	-v|--verbose)
		verbose=1
		;;
	-d|--debug)
		debug=1
		;;
	*)
		exit_unknown "${1}"
		;;
	esac
	shift
done

# Check mandatory parameters and dependencies
[[ -z "${JQ}" ]]   && { echo "${PROGNAME}: jq is required — please install it";   exit 4; }
[[ -z "${CURL}" ]] && { echo "${PROGNAME}: curl is required — please install it"; exit 4; }
[[ -z "${AWK}" ]]  && { echo "${PROGNAME}: awk is required — please install it";  exit 4; }
[[ -z "${array_host}" ]] && exit_unknown "Array hostname or IP (-H) is required!"
[[ -z "${x_auth_token}" && -z "${api_token}" && ( -z "${api_user}" || -z "${api_pass}" ) ]] && \
	exit_unknown "Authentication required: -a <api_token>  OR  -U <user> -P <pass>  OR  -T <token>"

# If no explicit enable flags -> enable all (opt-out mode via --disable-X)
[[
-z "${enable_arrays}" &&
-z "${enable_space}" &&
-z "${enable_hardware}" &&
-z "${enable_conn}" &&
-z "${enable_ctrl}" &&
-z "${enable_drives}" &&
-z "${enable_blades}" &&
-z "${enable_perf}" &&
-z "${enable_vol}" &&
-z "${enable_snaps}" &&
-z "${enable_snaps_xfer}" &&
-z "${enable_fs}" &&
-z "${enable_dirs}" &&
-z "${enable_buckets}" &&
-z "${enable_os}" &&
-z "${enable_quotas}" &&
-z "${enable_network}" &&
-z "${enable_dns}" &&
-z "${enable_syslog}" &&
-z "${enable_repl}" &&
-z "${enable_certs}" &&
-z "${enable_alerts}" &&
-z "${enable_subs}" &&
-z "${enable_metrics}" &&
-z "${enable_ni_perf}" &&
-z "${enable_ni_port}" &&
-z "${enable_ni_nbr}" &&
-z "${enable_off}" &&
-z "${enable_patch}" &&
-z "${enable_sw}" &&
-z "${enable_all}"
]] && enable_all=1

# Defaults
[[ -z "${warning}" ]]   && warning=80
[[ -z "${critical}" ]]  && critical=90
[[ -z "${warn_temp}" ]] && warn_temp=65
[[ -z "${crit_temp}" ]] && crit_temp=75
[[ -z "${warn_cert}" ]] && warn_cert=30
[[ -z "${crit_cert}" ]] && crit_cert=15
[[ -z "${warn_sub}" ]]  && warn_sub=30
[[ -z "${crit_sub}" ]]  && crit_sub=15
[[ -z "${warn_vol}" ]]   && warn_vol=80
[[ -z "${crit_vol}" ]]   && crit_vol=90
[[ -z "${warn_ni_bw}" ]]     && warn_ni_bw=80
[[ -z "${crit_ni_bw}" ]]     && crit_ni_bw=90
[[ -z "${warn_ni_errors}" ]] && warn_ni_errors=1
[[ -z "${crit_ni_errors}" ]] && crit_ni_errors=10
[[ -z "${bw_unit}" ]]    && bw_unit="auto"

# Status labels
status_ok="[OK]"
status_warn="[WARNING]"
status_crit="[CRITICAL]"
status_unkn="[UNKNOWN]"

# Curl option blocks — --insecure for self-signed array certificates
CURL_OPTS_GET="--insecure -X GET --silent --max-time 30"
CURL_OPTS_POST="--insecure -X POST --silent --max-time 30"
CURL_OPTS_JSON="Content-Type: application/json"

pure_output=""
pure_problem_output=""
pure_perf=""

if [[ -n "${debug}" ]]; then
	echo "Debugging mode ON." 1>&2
	set -x
fi

# ---------------------------------------------------------------------------
# Auto-detect API versions (latest 2.x and 1.x from single request)
# ---------------------------------------------------------------------------
if [[ -z "${api_version}" ]]; then
	_ver_resp=`${CURL} --insecure --silent --max-time 10 "https://${array_host}/api/api_version"`
	api_version=`echo "${_ver_resp}" | "${JQ}" --unbuffered -r \
		'[.version[] | select(startswith("2."))] | last // "2.x"' 2>/dev/null`
	[[ -z "${api_version}" || "${api_version}" == "null" ]] && api_version="2.x"
	_v1_ver=`echo "${_ver_resp}" | "${JQ}" --unbuffered -r \
		'[.version[] | select(startswith("1."))] | last // "1.latest"' 2>/dev/null`
	[[ -z "${_v1_ver}" || "${_v1_ver}" == "null" ]] && _v1_ver="1.latest"
fi

ARRAY_API="https://${array_host}/api/${api_version}"
api_cmd_get="${CURL} ${CURL_OPTS_GET} ${ARRAY_API}"

# ---------------------------------------------------------------------------
# Authentication — API token or username/password
# ---------------------------------------------------------------------------
if [[ -z "${x_auth_token}" ]]; then
	if [[ -n "${api_user}" && -n "${api_pass}" ]]; then
		# Exchange username/password for an API token via v1 endpoint
		api_token=`${CURL} --insecure --silent --max-time 30 -X POST \
			"https://${array_host}/api/${_v1_ver}/auth/apitoken" \
			-H "Content-Type: application/json" \
			-d "{\"username\":\"${api_user}\",\"password\":\"${api_pass}\"}" | \
			"${JQ}" --unbuffered -r '.api_token // empty' 2>/dev/null`
		if [[ -z "${api_token}" ]]; then
			echo "${status_unkn} - Login to ${array_host} failed — could not retrieve API token for user '${api_user}'"
			exit 4
		fi
	fi

	x_auth_token=`${CURL} --insecure --silent --max-time 30 -X POST \
		"${ARRAY_API}/login" \
		-H "api-token: ${api_token}" \
		-i | "${AWK}" 'tolower($0) ~ /^x-auth-token:/ {sub(/^[^:]*:[[:space:]]*/,""); gsub(/\r/,""); print; exit}'`

	if [[ -z "${x_auth_token}" ]]; then
		echo "${status_unkn} - Login to ${array_host} failed — check host, credentials and API version"
		exit 4
	fi
fi

CURL_OPTS_AUTH="x-auth-token: ${x_auth_token}"

# ---------------------------------------------------------------------------
# Fetch array info (shared by all checks, provides name label)
# ---------------------------------------------------------------------------
arrays_buffer=`${api_cmd_get}/arrays \
	-H "${CURL_OPTS_AUTH}" -H "${CURL_OPTS_JSON}"`

if [[ -z "${arrays_buffer}" || "${arrays_buffer}" =~ '"errors"' ]]; then
	echo "${status_unkn} - Failed to retrieve array info from ${array_host}"
	exit 4
fi

array_name=`echo "${arrays_buffer}" | "${JQ}" --unbuffered -r '.items[0].name // "unknown"' 2>/dev/null`

# Optional: validate array name matches expected
if [[ -n "${array_filter}" && "${array_name}" != "${array_filter}" ]]; then
	echo "${status_unkn} - Connected array name '${array_name}' does not match expected '${array_filter}'"
	exit 4
fi

# ---------------------------------------------------------------------------
# Array Info Check
# ---------------------------------------------------------------------------
if [[ ( -n "${enable_arrays}" || -n "${enable_all}" ) && -z "${disable_arrays}" ]]; then
	if [[ -n "${verbose}" ]]; then
		pure_output+="Array Info:\n---------------------------------------\n"
	fi

	_ar_os=`echo "${arrays_buffer}" | "${JQ}" --unbuffered -r '.items[0].os // "n/a"'`
	_ar_ver=`echo "${arrays_buffer}" | "${JQ}" --unbuffered -r '.items[0].version // "n/a"'`
	_ar_rev=`echo "${arrays_buffer}" | "${JQ}" --unbuffered -r '.items[0].revision // "n/a"'`
	_ar_ntp=`echo "${arrays_buffer}" | "${JQ}" --unbuffered -r '(.items[0].ntp_servers // []) | join(",")' 2>/dev/null`
	_ar_tz=`echo "${arrays_buffer}" | "${JQ}" --unbuffered -r '.items[0].time_zone // "n/a"'`

	_rev_s=""
	[[ "${_ar_rev}" != "n/a" && -n "${_ar_rev}" ]] && _rev_s=" | Rev: ${_ar_rev}"
	pure_output+="${status_ok} - Array: ${array_name} | OS: ${_ar_os} ${_ar_ver}${_rev_s}\n"
	pure_perf+=" ${array_name}_online=1"

	if [[ -n "${check_ntp}" ]]; then
		_ntp_ok=0
		if [[ -n "${ntp_strict}" ]]; then
			[[ "${_ar_ntp}" == "${check_ntp}" ]] && _ntp_ok=1
		else
			_servers_subset "${check_ntp}" "${_ar_ntp}" && _ntp_ok=1
		fi
		if [[ "${_ntp_ok}" -eq 1 ]]; then
			if [[ -n "${verbose}" ]]; then
				pure_output+="${status_ok} - Array ${array_name}: NTP servers OK (${_ar_ntp})\n"
			fi
		else
			_ntp_mode_s=""
			[[ -n "${ntp_strict}" ]] && _ntp_mode_s=" (strict)"
			pure_output+="${status_warn} - Array ${array_name}: NTP mismatch${_ntp_mode_s} — expected: ${check_ntp} | configured: ${_ar_ntp:-none}\n"
			pure_problem_output+="${status_warn} - Array ${array_name}: NTP mismatch${_ntp_mode_s} — expected: ${check_ntp} | configured: ${_ar_ntp:-none}\n"
		fi
	elif [[ -n "${verbose}" ]]; then
		pure_output+="${status_ok} - Array ${array_name}: NTP servers: ${_ar_ntp:-none}\n"
	fi

	if [[ -n "${check_tz}" ]]; then
		_tz_list_buf=`${api_cmd_get}/arrays/supported-time-zones \
			-H "${CURL_OPTS_AUTH}" -H "${CURL_OPTS_JSON}"`
		_tz_valid=""
		if [[ -n "${_tz_list_buf}" && ! "${_tz_list_buf}" =~ '"errors"' ]]; then
			_tz_valid=`echo "${_tz_list_buf}" | "${JQ}" --unbuffered -r \
				--arg tz "${check_tz}" '(.items // [])[] | select(.name == $tz) | .name' 2>/dev/null`
		fi
		if [[ -n "${_tz_list_buf}" && ! "${_tz_list_buf}" =~ '"errors"' && -z "${_tz_valid}" ]]; then
			pure_output+="${status_unkn} - Array ${array_name}: '${check_tz}' is not a supported timezone\n"
			pure_problem_output+="${status_unkn} - Array ${array_name}: '${check_tz}' is not a supported timezone\n"
		elif [[ "${_ar_tz}" == "${check_tz}" ]]; then
			if [[ -n "${verbose}" ]]; then
				pure_output+="${status_ok} - Array ${array_name}: Timezone OK (${_ar_tz})\n"
			fi
		else
			pure_output+="${status_warn} - Array ${array_name}: Timezone mismatch — expected: ${check_tz} | configured: ${_ar_tz}\n"
			pure_problem_output+="${status_warn} - Array ${array_name}: Timezone mismatch — expected: ${check_tz} | configured: ${_ar_tz}\n"
		fi
	elif [[ -n "${verbose}" ]]; then
		pure_output+="${status_ok} - Array ${array_name}: Timezone: ${_ar_tz}\n"
	fi

	if [[ -n "${verbose}" ]]; then
		pure_output+="---------------------------------------\n\n"
	fi
fi

# ---------------------------------------------------------------------------
# Space / Capacity Check
# ---------------------------------------------------------------------------
if [[ ( -n "${enable_space}" || -n "${enable_all}" ) && -z "${disable_space}" ]]; then
	if [[ -n "${verbose}" ]]; then
		pure_output+="Space / Capacity:\n---------------------------------------\n"
	fi

	_cap=`echo "${arrays_buffer}" | "${JQ}" --unbuffered -r '.items[0].space.capacity // 0' 2>/dev/null`
	_used=`echo "${arrays_buffer}" | "${JQ}" --unbuffered -r '.items[0].space.total_physical // 0' 2>/dev/null`
	_prov=`echo "${arrays_buffer}" | "${JQ}" --unbuffered -r '.items[0].space.total_provisioned // 0' 2>/dev/null`
	_dr=`echo "${arrays_buffer}" | "${JQ}" --unbuffered -r '.items[0].space.data_reduction // 1' 2>/dev/null`
	_snap=`echo "${arrays_buffer}" | "${JQ}" --unbuffered -r '.items[0].space.snapshots // 0' 2>/dev/null`
	_unique=`echo "${arrays_buffer}" | "${JQ}" --unbuffered -r '.items[0].space.unique // 0' 2>/dev/null`
	_virtual=`echo "${arrays_buffer}" | "${JQ}" --unbuffered -r '.items[0].space.virtual // 0' 2>/dev/null`
	_parity=`echo "${arrays_buffer}" | "${JQ}" --unbuffered -r '.items[0].parity // 0' 2>/dev/null`

	if [[ "${_cap}" == "0" || "${_cap}" == "null" ]]; then
		_space_buf=`${api_cmd_get}/arrays/space -H "${CURL_OPTS_AUTH}" -H "${CURL_OPTS_JSON}"`
		_cap=`echo "${_space_buf}" | "${JQ}" --unbuffered -r '.items[0].capacity // 0' 2>/dev/null`
		_used=`echo "${_space_buf}" | "${JQ}" --unbuffered -r '.items[0].space.total_physical // 0' 2>/dev/null`
		_prov=`echo "${_space_buf}" | "${JQ}" --unbuffered -r '.items[0].total_provisioned // 0' 2>/dev/null`
		_dr=`echo "${_space_buf}" | "${JQ}" --unbuffered -r '.items[0].space.data_reduction // 1' 2>/dev/null`
		_snap=`echo "${_space_buf}" | "${JQ}" --unbuffered -r '.items[0].space.snapshots // 0' 2>/dev/null`
		_unique=`echo "${_space_buf}" | "${JQ}" --unbuffered -r '.items[0].space.unique // 0' 2>/dev/null`
		_virtual=`echo "${_space_buf}" | "${JQ}" --unbuffered -r '.items[0].space.virtual // 0' 2>/dev/null`
		_parity=`echo "${_space_buf}" | "${JQ}" --unbuffered -r '.items[0].parity // 0' 2>/dev/null`
	fi

	if [[ "${_cap}" == "0" || "${_cap}" == "null" ]]; then
		pure_output+="${status_unkn} - ${array_name}: No capacity data returned\n"
		pure_problem_output+="${status_unkn} - ${array_name}: No capacity data returned\n"
	else
		_pct=`echo "${_used} ${_cap}" | "${AWK}" '{printf "%.2f",$1*100/$2}'`
		_pct_int=`echo "${_pct}" | "${AWK}" -F. '{print $1+0}'`
		_cap_h=`echo "${_cap}" | "${AWK}" '{
			if      ($1>=1099511627776) printf "%.2f TiB",$1/1099511627776
			else if ($1>=1073741824)    printf "%.2f GiB",$1/1073741824
			else if ($1>=1048576)       printf "%.2f MiB",$1/1048576
			else                        printf "%d B",$1}'`
		_used_h=`echo "${_used}" | "${AWK}" '{
			if      ($1>=1099511627776) printf "%.2f TiB",$1/1099511627776
			else if ($1>=1073741824)    printf "%.2f GiB",$1/1073741824
			else if ($1>=1048576)       printf "%.2f MiB",$1/1048576
			else                        printf "%d B",$1}'`
		_prov_h=`echo "${_prov}" | "${AWK}" '{
			if      ($1>=1099511627776) printf "%.2f TiB",$1/1099511627776
			else if ($1>=1073741824)    printf "%.2f GiB",$1/1073741824
			else if ($1>=1048576)       printf "%.2f MiB",$1/1048576
			else                        printf "%d B",$1}'`
		_dr_s=`echo "${_dr}" | "${AWK}" '{printf "%.1f",$1}'`
		_snap_h=`echo "${_snap}" | "${AWK}" '{
			if      ($1>=1099511627776) printf "%.2f TiB",$1/1099511627776
			else if ($1>=1073741824)    printf "%.2f GiB",$1/1073741824
			else if ($1>=1048576)       printf "%.2f MiB",$1/1048576
			else                        printf "%d B",$1}'`
		_parity_s=`echo "${_parity}" | "${AWK}" '{printf "%.4f",$1}'`
		_warn_b=`echo "${_cap} ${warning}"  | "${AWK}" '{printf "%d",$1*$2/100}'`
		_crit_b=`echo "${_cap} ${critical}" | "${AWK}" '{printf "%d",$1*$2/100}'`

		if [[ "${_pct_int}" -ge "${critical}" ]]; then
			pure_output+="${status_crit} - ${array_name}: ${_used_h} of ${_cap_h} used (${_pct}%) | Provisioned: ${_prov_h} | DR: ${_dr_s}:1 | Snap: ${_snap_h}\n"
			pure_problem_output+="${status_crit} - Space ${array_name}: ${_used_h} of ${_cap_h} used (${_pct}%)\n"
		elif [[ "${_pct_int}" -ge "${warning}" ]]; then
			pure_output+="${status_warn} - ${array_name}: ${_used_h} of ${_cap_h} used (${_pct}%) | Provisioned: ${_prov_h} | DR: ${_dr_s}:1 | Snap: ${_snap_h}\n"
			pure_problem_output+="${status_warn} - Space ${array_name}: ${_used_h} of ${_cap_h} used (${_pct}%)\n"
		else
			pure_output+="${status_ok} - ${array_name}: ${_used_h} of ${_cap_h} used (${_pct}%) | Provisioned: ${_prov_h} | DR: ${_dr_s}:1 | Snap: ${_snap_h}\n"
		fi

		pure_perf+=" ${array_name}_space_used=${_used}B;${_warn_b};${_crit_b};0;${_cap}"
		pure_perf+=" ${array_name}_space_pct=${_pct}%;${warning};${critical};0;100"
		pure_perf+=" ${array_name}_space_prov=${_prov}B"
		pure_perf+=" ${array_name}_space_snap=${_snap}B"
		pure_perf+=" ${array_name}_space_unique=${_unique}B"
		pure_perf+=" ${array_name}_space_virtual=${_virtual}B"
		pure_perf+=" ${array_name}_space_parity=${_parity_s}"
		pure_perf+=" ${array_name}_data_reduction=${_dr_s}"
	fi

	if [[ -n "${verbose}" ]]; then
		pure_output+="---------------------------------------\n\n"
	fi
fi

# ---------------------------------------------------------------------------
# Hardware Component Health Check
# ---------------------------------------------------------------------------
if [[ ( -n "${enable_hardware}" || -n "${enable_all}" ) && -z "${disable_hardware}" ]]; then
	hw_buffer=`${api_cmd_get}/hardware \
		-H "${CURL_OPTS_AUTH}" -H "${CURL_OPTS_JSON}"`

	if [[ -n "${verbose}" ]]; then
		pure_output+="Hardware:\n---------------------------------------\n"
	fi

	declare -a hw_comp hw_status hw_temp hw_type

	hw_comp=(  `echo "${hw_buffer}" | "${JQ}" --unbuffered -r '.items[].name'                  2>/dev/null | "${AWK}" 1 ORS=' '`)
	hw_status=(`echo "${hw_buffer}" | "${JQ}" --unbuffered -r '.items[].status // "unknown"'  2>/dev/null | "${AWK}" 1 ORS=' '`)
	hw_temp=(  `echo "${hw_buffer}" | "${JQ}" --unbuffered -r '.items[].temperature // "null"' 2>/dev/null | "${AWK}" 1 ORS=' '`)
	hw_type=(  `echo "${hw_buffer}" | "${JQ}" --unbuffered -r '.items[].type // "unknown"'    2>/dev/null | "${AWK}" 1 ORS=' '`)

	for count in "${!hw_comp[@]}"; do
		_stat="${hw_status[count]}"
		_temp="${hw_temp[count]}"
		_lbl="${array_name}_${hw_comp[count]}"

		if [[ "${_stat}" == "critical" || "${_stat}" == "unhealthy" ]]; then
			pure_output+="${status_crit} - Hardware ${array_name}: ${hw_comp[count]} (${hw_type[count]}) ${_stat}\n"
			pure_problem_output+="${status_crit} - Hardware ${array_name}: ${hw_comp[count]} (${hw_type[count]}) ${_stat}\n"
		elif [[ "${_stat}" == "identifying" || "${_stat}" == "unrecognized" ]]; then
			pure_output+="${status_warn} - Hardware ${array_name}: ${hw_comp[count]} (${hw_type[count]}) ${_stat}\n"
			pure_problem_output+="${status_warn} - Hardware ${array_name}: ${hw_comp[count]} (${hw_type[count]}) ${_stat}\n"
		elif [[ "${_stat}" == "unknown" ]]; then
			pure_output+="${status_unkn} - Hardware ${array_name}: ${hw_comp[count]} (${hw_type[count]}) unknown\n"
			pure_problem_output+="${status_unkn} - Hardware ${array_name}: ${hw_comp[count]} (${hw_type[count]}) unknown\n"
		elif [[ "${_stat}" == "healthy" || "${_stat}" == "ok" || "${_stat}" == "unclaimed" || "${_stat}" == "unused" || "${_stat}" == "not_installed" ]]; then
			if [[ -n "${verbose}" ]]; then
				pure_output+="${status_ok} - Hardware ${array_name}: ${hw_comp[count]} (${hw_type[count]}) ${_stat}\n"
			fi
		else
			pure_output+="${status_unkn} - Hardware ${array_name}: ${hw_comp[count]} (${hw_type[count]}) status '${_stat}' unrecognized\n"
			pure_problem_output+="${status_unkn} - Hardware ${array_name}: ${hw_comp[count]} (${hw_type[count]}) status '${_stat}' unrecognized\n"
		fi

		if [[ "${_temp}" != "null" && "${_temp}" != "" ]]; then
			_temp_int=`echo "${_temp}" | "${AWK}" '{printf "%d",$1}'`
			if [[ "${_temp_int}" -ge "${crit_temp}" ]]; then
				pure_output+="${status_crit} - Hardware ${array_name}: ${hw_comp[count]} temperature ${_temp}°C (>= ${crit_temp}°C)\n"
				pure_problem_output+="${status_crit} - Hardware ${array_name}: ${hw_comp[count]} temperature ${_temp}°C (>= ${crit_temp}°C)\n"
			elif [[ "${_temp_int}" -ge "${warn_temp}" ]]; then
				pure_output+="${status_warn} - Hardware ${array_name}: ${hw_comp[count]} temperature ${_temp}°C (>= ${warn_temp}°C)\n"
				pure_problem_output+="${status_warn} - Hardware ${array_name}: ${hw_comp[count]} temperature ${_temp}°C (>= ${warn_temp}°C)\n"
			fi
			_safe_lbl=`echo "${_lbl}" | tr '.-/' '_'`
			pure_perf+=" hw_temp_${_safe_lbl}=${_temp};${warn_temp};${crit_temp}"
		fi
	done

	_hw_total=`echo "${hw_buffer}" | "${JQ}" --unbuffered '.items | length'`
	_hw_crit=`echo "${hw_buffer}" | "${JQ}" --unbuffered '[.items[] | select(.status == "critical" or .status == "unhealthy")] | length' 2>/dev/null`
	_hw_warn=`echo "${hw_buffer}" | "${JQ}" --unbuffered '[.items[] | select(.status == "identifying" or .status == "unrecognized")] | length' 2>/dev/null`
	_hw_unkn=`echo "${hw_buffer}" | "${JQ}" --unbuffered '[.items[] | select(.status != null and (.status | IN("healthy","ok","unclaimed","unused","not_installed","critical","unhealthy","identifying","unrecognized","unknown") | not))] | length' 2>/dev/null`

	if [[ "${_hw_crit}" -eq 0 && "${_hw_warn}" -eq 0 && "${_hw_unkn}" -eq 0 && -z "${verbose}" ]]; then
		pure_output+="${status_ok} - Hardware: All ${_hw_total} components OK\n"
	fi

	pure_perf+=" hw_total=${_hw_total} hw_critical=${_hw_crit} hw_warning=${_hw_warn} hw_unknown=${_hw_unkn}"

	if [[ -n "${verbose}" ]]; then
		pure_output+="---------------------------------------\n\n"
	fi

	unset hw_comp hw_status hw_temp hw_type
fi

# ---------------------------------------------------------------------------
# Hardware Connectors Check (/hardware-connectors)
# ---------------------------------------------------------------------------
if [[ ( -n "${enable_conn}" || -n "${enable_all}" ) && -z "${disable_conn}" ]]; then
	cn_buffer=`${api_cmd_get}/hardware-connectors \
		-H "${CURL_OPTS_AUTH}" -H "${CURL_OPTS_JSON}"`

	declare -a cn_name cn_conn_type cn_xcvr cn_lane_speed cn_port_count

	cn_name=(       `echo "${cn_buffer}" | "${JQ}" --unbuffered -r '.items[].name'                        2>/dev/null | "${AWK}" 1 ORS=' '`)
	cn_conn_type=(  `echo "${cn_buffer}" | "${JQ}" --unbuffered -r '.items[].connector_type // "unknown"' 2>/dev/null | "${AWK}" 1 ORS=' '`)
	cn_xcvr=(       `echo "${cn_buffer}" | "${JQ}" --unbuffered -r '.items[].transceiver_type // ""'      2>/dev/null | "${AWK}" 1 ORS=' '`)
	cn_lane_speed=( `echo "${cn_buffer}" | "${JQ}" --unbuffered -r '.items[].lane_speed // 0'             2>/dev/null | "${AWK}" 1 ORS=' '`)
	cn_port_count=( `echo "${cn_buffer}" | "${JQ}" --unbuffered -r '.items[].port_count // 0'             2>/dev/null | "${AWK}" 1 ORS=' '`)

	_cn_total=0
	_cn_unkn=0
	_cn_section=""

	for count in "${!cn_name[@]}"; do
		(( _cn_total++ ))
		_xcvr="${cn_xcvr[count]}"
		_ctype="${cn_conn_type[count]}"
		_spd_h=`echo "${cn_lane_speed[count]}" | "${AWK}" '{if($1>0) printf "%.0f Gbit/s",$1/1000000000; else print "n/a"}'`
		_safe_cn=`echo "${array_name}_${cn_name[count]}" | tr '.-/ ' '____'`

		if [[ -z "${_xcvr}" || "${_xcvr}" == "null" ]]; then
			if [[ -n "${verbose}" ]]; then
				_cn_section+="${status_ok} - Connector ${array_name}: ${cn_name[count]} (${_ctype}) Unused\n"
			fi
		elif [[ "${_xcvr}" == "Unknown" ]]; then
			_cn_section+="${status_unkn} - Connector ${array_name}: ${cn_name[count]} (${_ctype}) transceiver Unknown\n"
			pure_problem_output+="${status_unkn} - Connector ${array_name}: ${cn_name[count]} (${_ctype}) transceiver Unknown\n"
			(( _cn_unkn++ ))
		else
			if [[ -n "${verbose}" ]]; then
				_cn_section+="${status_ok} - Connector ${array_name}: ${cn_name[count]} (${_ctype}) ${_xcvr} | ${_spd_h} | ports: ${cn_port_count[count]}\n"
			fi
		fi

		pure_perf+=" conn_${_safe_cn}_ports=${cn_port_count[count]}"
	done

	if [[ "${_cn_total}" -gt 0 ]]; then
		if [[ "${_cn_unkn}" -eq 0 && -z "${verbose}" ]]; then
			pure_output+="${status_ok} - Connectors: All ${_cn_total} connector(s) OK\n"
		elif [[ -n "${_cn_section}" ]]; then
			if [[ -n "${verbose}" ]]; then
				pure_output+="Hardware Connectors:\n---------------------------------------\n"
			fi
			pure_output+="${_cn_section}"
			if [[ -n "${verbose}" ]]; then
				pure_output+="---------------------------------------\n\n"
			fi
		fi
		pure_perf+=" connectors_total=${_cn_total} connectors_unknown=${_cn_unkn}"
	fi

	unset cn_name cn_conn_type cn_xcvr cn_lane_speed cn_port_count
fi

# ---------------------------------------------------------------------------
# Controllers Check
# ---------------------------------------------------------------------------
if [[ ( -n "${enable_ctrl}" || -n "${enable_all}" ) && -z "${disable_ctrl}" ]]; then
	ctrl_buffer=`${api_cmd_get}/controllers \
		-H "${CURL_OPTS_AUTH}" -H "${CURL_OPTS_JSON}"`

	if [[ -n "${verbose}" ]]; then
		pure_output+="Controllers:\n---------------------------------------\n"
	fi

	declare -a ct_name ct_status ct_mode ct_model ct_version

	ct_name=(   `echo "${ctrl_buffer}" | "${JQ}" --unbuffered -r '.items[].name'             2>/dev/null | "${AWK}" 1 ORS=' '`)
	ct_status=( `echo "${ctrl_buffer}" | "${JQ}" --unbuffered -r '.items[].status // "unknown"' 2>/dev/null | "${AWK}" 1 ORS=' '`)
	ct_mode=(   `echo "${ctrl_buffer}" | "${JQ}" --unbuffered -r '.items[].mode // ""'       2>/dev/null | "${AWK}" 1 ORS=' '`)
	ct_model=(  `echo "${ctrl_buffer}" | "${JQ}" --unbuffered -r '.items[].model // "n/a"'   2>/dev/null | "${AWK}" 1 ORS=' '`)
	ct_version=(`echo "${ctrl_buffer}" | "${JQ}" --unbuffered -r '.items[].version // "n/a"' 2>/dev/null | "${AWK}" 1 ORS=' '`)

	_ct_total=0
	_ct_crit=0
	_ct_warn=0
	_ct_unkn=0

	for count in "${!ct_name[@]}"; do
		(( _ct_total++ ))
		_ctst="${ct_status[count]}"
		_ctmode="${ct_mode[count]}"
		_safe_ct=`echo "${array_name}_${ct_name[count]}" | tr '.-/ ' '____'`
		_ct_info="${ct_name[count]} | model: ${ct_model[count]} | version: ${ct_version[count]}"

		# evaluate status
		_ct_state_flag=0   # 0=ok, 1=warn, 2=crit, 3=unkn
		case "${_ctst}" in
		ready)    _ct_state_flag=0 ;;
		updating) _ct_state_flag=1 ;;
		unknown)  _ct_state_flag=3 ;;
		*)        _ct_state_flag=2 ;;
		esac

		# evaluate mode (overrides to warn/crit if worse)
		case "${_ctmode}" in
		primary|secondary) ;;
		"")
			[[ "${_ct_state_flag}" -lt 1 ]] && _ct_state_flag=1
			;;
		offline)
			[[ "${_ct_state_flag}" -lt 2 ]] && _ct_state_flag=2
			;;
		esac

		_ct_mode_s=""
		[[ -n "${_ctmode}" ]] && _ct_mode_s=" | mode: ${_ctmode}"

		case "${_ct_state_flag}" in
		0)
			(( _ct_total > 0 )) || true
			if [[ -n "${verbose}" ]]; then
				pure_output+="${status_ok} - Controller ${array_name}: ${_ct_info}${_ct_mode_s} | status: ${_ctst}\n"
			fi
			;;
		1)
			pure_output+="${status_warn} - Controller ${array_name}: ${_ct_info}${_ct_mode_s} | status: ${_ctst^^}\n"
			pure_problem_output+="${status_warn} - Controller ${array_name}: ${_ct_info}${_ct_mode_s} | status: ${_ctst^^}\n"
			(( _ct_warn++ ))
			;;
		2)
			pure_output+="${status_crit} - Controller ${array_name}: ${_ct_info}${_ct_mode_s} | status: ${_ctst^^}\n"
			pure_problem_output+="${status_crit} - Controller ${array_name}: ${_ct_info}${_ct_mode_s} | status: ${_ctst^^}\n"
			(( _ct_crit++ ))
			;;
		3)
			pure_output+="${status_unkn} - Controller ${array_name}: ${_ct_info}${_ct_mode_s} | status: unknown\n"
			pure_problem_output+="${status_unkn} - Controller ${array_name}: ${_ct_info}${_ct_mode_s} | status: unknown\n"
			(( _ct_unkn++ ))
			;;
		esac

		pure_perf+=" ctrl_${_safe_ct}_ready=`[[ "${_ctst}" == "ready" ]] && echo 1 || echo 0`"
	done

	if [[ "${_ct_crit}" -eq 0 && "${_ct_warn}" -eq 0 && "${_ct_unkn}" -eq 0 && -z "${verbose}" ]]; then
		pure_output+="${status_ok} - Controllers: ${_ct_total}/${_ct_total} ready\n"
	fi

	pure_perf+=" controllers_total=${_ct_total} controllers_crit=${_ct_crit} controllers_warn=${_ct_warn}"

	if [[ -n "${verbose}" ]]; then
		pure_output+="---------------------------------------\n\n"
	fi

	unset ct_name ct_status ct_mode ct_model ct_version
fi

# ---------------------------------------------------------------------------
# Drive Health Check
# ---------------------------------------------------------------------------
if [[ ( -n "${enable_drives}" || -n "${enable_all}" ) && -z "${disable_drives}" ]]; then
	drives_buffer=`${api_cmd_get}/drives \
		-H "${CURL_OPTS_AUTH}" -H "${CURL_OPTS_JSON}"`

	if [[ -n "${verbose}" ]]; then
		pure_output+="Drives:\n---------------------------------------\n"
	fi

	declare -a dr_name dr_status dr_type

	dr_name=(  `echo "${drives_buffer}" | "${JQ}" --unbuffered -r '.items[].name'           2>/dev/null | "${AWK}" 1 ORS=' '`)
	dr_status=(`echo "${drives_buffer}" | "${JQ}" --unbuffered -r '.items[].status // "ok"' 2>/dev/null | "${AWK}" 1 ORS=' '`)
	dr_type=(  `echo "${drives_buffer}" | "${JQ}" --unbuffered -r '.items[].type // "SSD"'  2>/dev/null | "${AWK}" 1 ORS=' '`)

	_dr_total=0
	_dr_healthy=0
	_dr_warn=0
	_dr_crit=0
	_dr_unkn=0

	for count in "${!dr_name[@]}"; do
		(( _dr_total++ ))
		_dstat="${dr_status[count]}"
		_dlabel="${dr_name[count]} (${dr_type[count]})"

		case "${_dstat}" in
		failed|missing|unhealthy)
			pure_output+="${status_crit} - Drive ${array_name}: ${_dlabel} ${_dstat^^}\n"
			pure_problem_output+="${status_crit} - Drive ${array_name}: ${_dlabel} ${_dstat^^}\n"
			(( _dr_crit++ ))
			;;
		identifying|recovering|unadmitted|updating)
			pure_output+="${status_warn} - Drive ${array_name}: ${_dlabel} ${_dstat^^}\n"
			pure_problem_output+="${status_warn} - Drive ${array_name}: ${_dlabel} ${_dstat^^}\n"
			(( _dr_warn++ ))
			;;
		empty|healthy|unused)
			(( _dr_healthy++ ))
			if [[ -n "${verbose}" ]]; then
				pure_output+="${status_ok} - Drive ${array_name}: ${_dlabel} ${_dstat}\n"
			fi
			;;
		*)
			pure_output+="${status_unkn} - Drive ${array_name}: ${_dlabel} unrecognized status: ${_dstat}\n"
			pure_problem_output+="${status_unkn} - Drive ${array_name}: ${_dlabel} unrecognized status: ${_dstat}\n"
			(( _dr_unkn++ ))
			;;
		esac
	done

	if [[ "${_dr_crit}" -eq 0 && "${_dr_warn}" -eq 0 && "${_dr_unkn}" -eq 0 && -z "${verbose}" ]]; then
		pure_output+="${status_ok} - Drives: ${_dr_healthy}/${_dr_total} drives healthy\n"
	fi

	pure_perf+=" drives_total=${_dr_total} drives_healthy=${_dr_healthy} drives_failed=${_dr_crit} drives_warning=${_dr_warn} drives_unknown=${_dr_unkn}"

	if [[ -n "${verbose}" ]]; then
		pure_output+="---------------------------------------\n\n"
	fi

	unset dr_name dr_status dr_type
fi

# ---------------------------------------------------------------------------
# Blades Check (FlashBlade)
# ---------------------------------------------------------------------------
if [[ ( -n "${enable_blades}" || -n "${enable_all}" ) && -z "${disable_blades}" ]]; then
	bl_buffer=`${api_cmd_get}/blades \
		-H "${CURL_OPTS_AUTH}" -H "${CURL_OPTS_JSON}"`

	if [[ -n "${verbose}" ]]; then
		pure_output+="Blades:\n---------------------------------------\n"
	fi

	declare -a bl_name bl_status bl_cap bl_progress bl_details

	bl_name=(    `echo "${bl_buffer}" | "${JQ}" --unbuffered -r '(.items // [])[] | .name'                2>/dev/null | "${AWK}" 1 ORS=' '`)
	bl_status=(  `echo "${bl_buffer}" | "${JQ}" --unbuffered -r '(.items // [])[] | .status // "unknown"' 2>/dev/null | "${AWK}" 1 ORS=' '`)
	bl_cap=(     `echo "${bl_buffer}" | "${JQ}" --unbuffered -r '(.items // [])[] | .raw_capacity // 0'   2>/dev/null | "${AWK}" 1 ORS=' '`)
	bl_progress=(`echo "${bl_buffer}" | "${JQ}" --unbuffered -r '(.items // [])[] | .progress // 0'       2>/dev/null | "${AWK}" 1 ORS=' '`)
	while IFS= read -r line; do bl_details+=("${line}"); done < \
		<(echo "${bl_buffer}" | "${JQ}" --unbuffered -r '(.items // [])[] | .details // ""' 2>/dev/null)

	_bl_total=0
	_bl_crit=0
	_bl_warn=0
	_bl_unkn=0

	for count in "${!bl_name[@]}"; do
		(( _bl_total++ ))
		_blst="${bl_status[count]}"
		_bldet="${bl_details[count]}"
		_blprog="${bl_progress[count]}"
		_blcap="${bl_cap[count]}"
		_safe_bl=`echo "${array_name}_${bl_name[count]}" | tr '.-/ ' '____'`
		_det_s=""
		[[ -n "${_bldet}" ]] && _det_s=" | ${_bldet}"
		_prog_s=""
		if [[ "${_blprog}" != "0" && "${_blprog}" != "null" && "${_blprog}" != "" ]]; then
			_blprog_pct=`echo "${_blprog}" | "${AWK}" '{printf "%.1f",$1*100}'`
			_prog_s=" | Progress: ${_blprog_pct}%"
		fi
		_cap_h=`echo "${_blcap}" | "${AWK}" '{
			if      ($1>=1099511627776) printf "%.2f TiB",$1/1099511627776
			else if ($1>=1073741824)    printf "%.2f GiB",$1/1073741824
			else if ($1>=1048576)       printf "%.2f MiB",$1/1048576
			else                        printf "%d B",$1}'`

		if [[ "${_blst}" == "critical" || "${_blst}" == "unhealthy" ]]; then
			pure_output+="${status_crit} - Blade ${array_name}: ${bl_name[count]} ${_blst}${_det_s}\n"
			pure_problem_output+="${status_crit} - Blade ${array_name}: ${bl_name[count]} ${_blst}${_det_s}\n"
			(( _bl_crit++ ))
		elif [[ "${_blst}" == "evacuating" || "${_blst}" == "evacuated" ]]; then
			pure_output+="${status_warn} - Blade ${array_name}: ${bl_name[count]} ${_blst}${_prog_s}${_det_s}\n"
			pure_problem_output+="${status_warn} - Blade ${array_name}: ${bl_name[count]} ${_blst}${_prog_s}${_det_s}\n"
			(( _bl_warn++ ))
		elif [[ "${_blst}" == "unknown" ]]; then
			pure_output+="${status_unkn} - Blade ${array_name}: ${bl_name[count]} unknown${_det_s}\n"
			pure_problem_output+="${status_unkn} - Blade ${array_name}: ${bl_name[count]} unknown${_det_s}\n"
			(( _bl_unkn++ ))
		elif [[ "${_blst}" == "healthy" || "${_blst}" == "identifying" || "${_blst}" == "unused" ]]; then
			if [[ -n "${verbose}" ]]; then
				pure_output+="${status_ok} - Blade ${array_name}: ${bl_name[count]} ${_blst} | ${_cap_h}\n"
			fi
		else
			pure_output+="${status_unkn} - Blade ${array_name}: ${bl_name[count]} status '${_blst}' unrecognized${_det_s}\n"
			pure_problem_output+="${status_unkn} - Blade ${array_name}: ${bl_name[count]} status '${_blst}' unrecognized${_det_s}\n"
			(( _bl_unkn++ ))
		fi

		pure_perf+=" blade_${_safe_bl}_cap=${_blcap}B"
		pure_perf+=" blade_${_safe_bl}_healthy=`[[ "${_blst}" == "healthy" ]] && echo 1 || echo 0`"
	done

	_bl_total_cap=`echo "${bl_buffer}" | "${JQ}" --unbuffered -r '.total.raw_capacity // 0' 2>/dev/null`

	if [[ "${_bl_total}" -eq 0 && -n "${verbose}" ]]; then
		pure_output+="${status_ok} - Blades: None found\n"
	elif [[ "${_bl_crit}" -eq 0 && "${_bl_warn}" -eq 0 && "${_bl_unkn}" -eq 0 && -z "${verbose}" ]]; then
		pure_output+="${status_ok} - Blades: All ${_bl_total} blade(s) OK\n"
	fi

	pure_perf+=" blades_total=${_bl_total} blades_critical=${_bl_crit} blades_warning=${_bl_warn} blades_unknown=${_bl_unkn}"
	[[ "${_bl_total_cap}" != "0" ]] && pure_perf+=" blades_raw_capacity=${_bl_total_cap}B"

	if [[ -n "${verbose}" ]]; then
		pure_output+="---------------------------------------\n\n"
	fi

	unset bl_name bl_status bl_cap bl_progress bl_details
fi

# ---------------------------------------------------------------------------
# I/O Performance Check  (arrays/performance + file-systems/performance + buckets/performance)
# ---------------------------------------------------------------------------
if [[ ( -n "${enable_perf}" || -n "${enable_all}" ) && -z "${disable_perf}" ]]; then
	if [[ -n "${verbose}" ]]; then
		pure_output+="I/O Performance:\n---------------------------------------\n"
	fi

	_fmt_bandwidth() {
		echo "${1}" | "${AWK}" -v unit="${bw_unit}" '{
			if      (unit == "GB")       printf "%.2f GB",  $1/1073741824
			else if (unit == "MB")       printf "%.2f MB",  $1/1048576
			else if (unit == "KB")       printf "%.2f KB",  $1/1024
			else if (unit == "B")        printf "%.2f B",   $1
			else if ($1>=1073741824)     printf "%.2f GiB", $1/1073741824
			else if ($1>=1048576)        printf "%.2f MiB", $1/1048576
			else if ($1>=1024)           printf "%.2f KiB", $1/1024
			else                         printf "%d B",     $1}'
	}

	_perf_bandwidth() {
		echo "${1}" | "${AWK}" -v unit="${bw_unit}" '{
			if      (unit == "GB") printf "%.3fGB",  $1/1073741824
			else if (unit == "MB") printf "%.3fMB",  $1/1048576
			else if (unit == "KB") printf "%.3fKB",  $1/1024
			else if (unit == "B")  printf "%dB",     $1
			else if ($1>=1073741824) printf "%.3fGB", $1/1073741824
			else                   printf "%.3fMB",  $1/1048576}'
	}

	# Convert a MB/s threshold value to the perfdata bandwidth unit
	_perf_bw_threshold() {
		[[ -z "${1}" ]] && return
		echo "${1}" | "${AWK}" -v unit="${bw_unit}" '{
			if      (unit == "GB") printf "%.3f", $1/1024
			else if (unit == "KB") printf "%.0f", $1*1024
			else if (unit == "B")  printf "%.0f", $1*1048576
			else                   printf "%.3f", $1}'
	}

	# Array-level performance
	perf_arr_buffer=`${api_cmd_get}/arrays/performance \
		-H "${CURL_OPTS_AUTH}" -H "${CURL_OPTS_JSON}"`

	if [[ -n "${perf_arr_buffer}" && ! "${perf_arr_buffer}" =~ '"errors"' ]]; then
		_r_iops=`echo "${perf_arr_buffer}" | "${JQ}" --unbuffered -r ".items[0].${PERF_READ_IOPS} // 0"`
		_w_iops=`echo "${perf_arr_buffer}" | "${JQ}" --unbuffered -r ".items[0].${PERF_WRITE_IOPS} // 0"`
		_mw_iops=`echo "${perf_arr_buffer}" | "${JQ}" --unbuffered -r ".items[0].${PERF_MIRROR_IOPS} // 0"`
		_r_bandwidth=`echo "${perf_arr_buffer}" | "${JQ}" --unbuffered -r ".items[0].${PERF_READ_BW} // 0"`
		_w_bandwidth=`echo "${perf_arr_buffer}" | "${JQ}" --unbuffered -r ".items[0].${PERF_WRITE_BW} // 0"`
		_mw_bandwidth=`echo "${perf_arr_buffer}" | "${JQ}" --unbuffered -r ".items[0].${PERF_MIRROR_BW} // 0"`
		_r_lat=`echo "${perf_arr_buffer}" | "${JQ}" --unbuffered -r ".items[0].${PERF_READ_LAT} // 0"`
		_w_lat=`echo "${perf_arr_buffer}" | "${JQ}" --unbuffered -r ".items[0].${PERF_WRITE_LAT} // 0"`
		_mw_lat=`echo "${perf_arr_buffer}" | "${JQ}" --unbuffered -r ".items[0].${PERF_MIRROR_LAT} // 0"`
		_queue=`echo "${perf_arr_buffer}" | "${JQ}" --unbuffered -r ".items[0].${PERF_QUEUE} // 0"`
		_load=`echo "${perf_arr_buffer}" | "${JQ}" --unbuffered -r ".items[0].${PERF_LOAD} // 0"`

		_total_iops=`echo "${_r_iops} ${_w_iops}" | "${AWK}" '{print $1+$2}'`
		_r_bandwidth_h=`_fmt_bandwidth "${_r_bandwidth}"`
		_w_bandwidth_h=`_fmt_bandwidth "${_w_bandwidth}"`
		_mw_bandwidth_h=`_fmt_bandwidth "${_mw_bandwidth}"`
		_r_lat_ms=`echo "${_r_lat}"   | "${AWK}" '{printf "%.3f ms",$1/1000}'`
		_w_lat_ms=`echo "${_w_lat}"   | "${AWK}" '{printf "%.3f ms",$1/1000}'`
		_mw_lat_ms=`echo "${_mw_lat}" | "${AWK}" '{printf "%.3f ms",$1/1000}'`
		_load_s=`echo "${_load}" | "${AWK}" '{printf "%.1f",$1}'`

		# threshold evaluation — IOPS
		_perf_state="${status_ok}"
		if [[ -n "${crit_iops}" ]] && (( _total_iops > crit_iops )); then
			_perf_state="${status_crit}"
			pure_output+="${status_crit} - Performance ${array_name}: Total IOPS ${_total_iops} exceeds critical threshold ${crit_iops}\n"
			pure_problem_output+="${status_crit} - Performance ${array_name}: Total IOPS ${_total_iops} > ${crit_iops}\n"
		elif [[ -n "${warn_iops}" ]] && (( _total_iops > warn_iops )); then
			[[ "${_perf_state}" == "${status_ok}" ]] && _perf_state="${status_warn}"
			pure_output+="${status_warn} - Performance ${array_name}: Total IOPS ${_total_iops} exceeds warning threshold ${warn_iops}\n"
			pure_problem_output+="${status_warn} - Performance ${array_name}: Total IOPS ${_total_iops} > ${warn_iops}\n"
		fi

		# threshold evaluation — Bandwidth (compare peak of read/write in MB/s)
		_r_bw_mbps=`echo "${_r_bandwidth}" | "${AWK}" '{printf "%.3f",$1/1048576}'`
		_w_bw_mbps=`echo "${_w_bandwidth}" | "${AWK}" '{printf "%.3f",$1/1048576}'`
		_peak_bw_mbps=`echo "${_r_bw_mbps} ${_w_bw_mbps}" | "${AWK}" '{print ($1>$2)?$1:$2}'`
		if [[ -n "${crit_bw_mbps}" ]] && "${AWK}" "BEGIN{exit !(${_peak_bw_mbps}+0 > ${crit_bw_mbps}+0)}"; then
			_perf_state="${status_crit}"
			pure_output+="${status_crit} - Performance ${array_name}: Bandwidth ${_peak_bw_mbps} MB/s exceeds critical threshold ${crit_bw_mbps} MB/s\n"
			pure_problem_output+="${status_crit} - Performance ${array_name}: BW ${_peak_bw_mbps} MB/s > ${crit_bw_mbps} MB/s\n"
		elif [[ -n "${warn_bw_mbps}" ]] && "${AWK}" "BEGIN{exit !(${_peak_bw_mbps}+0 > ${warn_bw_mbps}+0)}"; then
			[[ "${_perf_state}" == "${status_ok}" ]] && _perf_state="${status_warn}"
			pure_output+="${status_warn} - Performance ${array_name}: Bandwidth ${_peak_bw_mbps} MB/s exceeds warning threshold ${warn_bw_mbps} MB/s\n"
			pure_problem_output+="${status_warn} - Performance ${array_name}: BW ${_peak_bw_mbps} MB/s > ${warn_bw_mbps} MB/s\n"
		fi

		# threshold evaluation — Latency (compare peak of read/write in ms)
		_r_lat_ms_val=`echo "${_r_lat}" | "${AWK}" '{printf "%.3f",$1/1000}'`
		_w_lat_ms_val=`echo "${_w_lat}" | "${AWK}" '{printf "%.3f",$1/1000}'`
		_peak_lat_ms=`echo "${_r_lat_ms_val} ${_w_lat_ms_val}" | "${AWK}" '{print ($1>$2)?$1:$2}'`
		if [[ -n "${crit_lat_ms}" ]] && "${AWK}" "BEGIN{exit !(${_peak_lat_ms}+0 > ${crit_lat_ms}+0)}"; then
			_perf_state="${status_crit}"
			pure_output+="${status_crit} - Performance ${array_name}: Latency ${_peak_lat_ms} ms exceeds critical threshold ${crit_lat_ms} ms\n"
			pure_problem_output+="${status_crit} - Performance ${array_name}: Latency ${_peak_lat_ms} ms > ${crit_lat_ms} ms\n"
		elif [[ -n "${warn_lat_ms}" ]] && "${AWK}" "BEGIN{exit !(${_peak_lat_ms}+0 > ${warn_lat_ms}+0)}"; then
			[[ "${_perf_state}" == "${status_ok}" ]] && _perf_state="${status_warn}"
			pure_output+="${status_warn} - Performance ${array_name}: Latency ${_peak_lat_ms} ms exceeds warning threshold ${warn_lat_ms} ms\n"
			pure_problem_output+="${status_warn} - Performance ${array_name}: Latency ${_peak_lat_ms} ms > ${warn_lat_ms} ms\n"
		fi

		pure_output+="${_perf_state} - Performance ${array_name}: IOPS: ${_total_iops} (R:${_r_iops} W:${_w_iops})"
		pure_output+=" Bandwidth: R:${_r_bandwidth_h}/s W:${_w_bandwidth_h}/s"
		pure_output+=" Latency: R:${_r_lat_ms} W:${_w_lat_ms}"
		pure_output+=" Queue: ${_queue} Load: ${_load_s}%\n"

		_mw_active=`echo "${_mw_iops}" | "${AWK}" '{print ($1>0)?1:0}'`
		if [[ "${_mw_active}" == "1" ]]; then
			pure_output+="${status_ok} - Performance ${array_name} (mirror write): IOPS: ${_mw_iops}"
			pure_output+=" Bandwidth: ${_mw_bandwidth_h}/s Latency: ${_mw_lat_ms}\n"
		fi

		# build warn/crit strings for perfdata (in the selected bandwidth unit)
		_pw="${warn_iops:-}"
		_pc="${crit_iops:-}"
		_pbw_w="`_perf_bw_threshold "${warn_bw_mbps}"`"
		_pbw_c="`_perf_bw_threshold "${crit_bw_mbps}"`"
		_plat_w=`[[ -n "${warn_lat_ms}" ]] && echo "${warn_lat_ms}" | "${AWK}" '{printf "%.0f",$1*1000}' || echo ""`
		_plat_c=`[[ -n "${crit_lat_ms}" ]] && echo "${crit_lat_ms}" | "${AWK}" '{printf "%.0f",$1*1000}' || echo ""`

		pure_perf+=" ${array_name}_read_iops=${_r_iops}"
		pure_perf+=" ${array_name}_write_iops=${_w_iops}"
		pure_perf+=" ${array_name}_total_iops=${_total_iops};${_pw};${_pc};0;"
		pure_perf+=" ${array_name}_read_bandwidth=`_perf_bandwidth "${_r_bandwidth}"`;${_pbw_w};${_pbw_c};0;"
		pure_perf+=" ${array_name}_write_bandwidth=`_perf_bandwidth "${_w_bandwidth}"`;${_pbw_w};${_pbw_c};0;"
		pure_perf+=" ${array_name}_mirror_write_iops=${_mw_iops}"
		pure_perf+=" ${array_name}_mirror_write_bandwidth=`_perf_bandwidth "${_mw_bandwidth}"`"
		pure_perf+=" ${array_name}_read_latency=${_r_lat}us;${_plat_w};${_plat_c};0;"
		pure_perf+=" ${array_name}_write_latency=${_w_lat}us;${_plat_w};${_plat_c};0;"
		pure_perf+=" ${array_name}_mirror_write_latency=${_mw_lat}us"
		pure_perf+=" ${array_name}_queue_depth=${_queue}"
		pure_perf+=" ${array_name}_load=${_load_s}%"
		# FlashBlade-style fields from same endpoint (0 on FlashArray)
		_fb_r_bandwidth=`echo "${perf_arr_buffer}" | "${JQ}" --unbuffered -r ".items[0].read_bytes_per_sec // 0"`
		_fb_w_bandwidth=`echo "${perf_arr_buffer}" | "${JQ}" --unbuffered -r ".items[0].write_bytes_per_sec // 0"`
		_fb_others=`echo "${perf_arr_buffer}" | "${JQ}" --unbuffered -r ".items[0].others_per_sec // 0"`
		_fb_bytes_op=`echo "${perf_arr_buffer}" | "${JQ}" --unbuffered -r ".items[0].bytes_per_op // 0"`
		_fb_bytes_read=`echo "${perf_arr_buffer}" | "${JQ}" --unbuffered -r ".items[0].bytes_per_read // 0"`
		_fb_bytes_write=`echo "${perf_arr_buffer}" | "${JQ}" --unbuffered -r ".items[0].bytes_per_write // 0"`
		_fb_lat_other=`echo "${perf_arr_buffer}" | "${JQ}" --unbuffered -r ".items[0].usec_per_other_op // 0"`
		pure_perf+=" ${array_name}_read_bandwidth_fb=`_perf_bandwidth "${_fb_r_bandwidth}"`"
		pure_perf+=" ${array_name}_write_bandwidth_fb=`_perf_bandwidth "${_fb_w_bandwidth}"`"
		pure_perf+=" ${array_name}_others_per_sec=${_fb_others}"
		pure_perf+=" ${array_name}_bytes_per_op=${_fb_bytes_op}"
		pure_perf+=" ${array_name}_bytes_per_read=${_fb_bytes_read}"
		pure_perf+=" ${array_name}_bytes_per_write=${_fb_bytes_write}"
		pure_perf+=" ${array_name}_lat_other=${_fb_lat_other}us"
	fi

	# Replication performance (per remote array)
	perf_repl_perf_buffer=`${api_cmd_get}/arrays/performance/replication \
		-H "${CURL_OPTS_AUTH}" -H "${CURL_OPTS_JSON}"`

	if [[ -n "${perf_repl_perf_buffer}" && ! "${perf_repl_perf_buffer}" =~ '"errors"' ]]; then
		declare -a rp_remote

		rp_remote=(`echo "${perf_repl_perf_buffer}" | "${JQ}" --unbuffered -r \
			'(.items // [])[] | .remote.name // .id // "unknown"' 2>/dev/null | "${AWK}" 1 ORS=' '`)

		for count in "${!rp_remote[@]}"; do
			_rp_tx=`echo "${perf_repl_perf_buffer}" | "${JQ}" --unbuffered -r \
				".items[${count}].periodic.transmitted_bytes_per_sec // 0"`
			_rp_rx=`echo "${perf_repl_perf_buffer}" | "${JQ}" --unbuffered -r \
				".items[${count}].periodic.received_bytes_per_sec // 0"`
			_safe_rp=`echo "${array_name}_${rp_remote[count]}" | tr '.-/ ' '____'`
			_rp_tx_h=`_fmt_bandwidth "${_rp_tx}"`
			_rp_rx_h=`_fmt_bandwidth "${_rp_rx}"`
			if [[ -n "${verbose}" ]]; then
				pure_output+="${status_ok} - Repl Perf ${array_name} -> ${rp_remote[count]}: TX:${_rp_tx_h}/s RX:${_rp_rx_h}/s\n"
			fi
			pure_perf+=" repl_perf_${_safe_rp}_tx=`_perf_bandwidth "${_rp_tx}"`"
			pure_perf+=" repl_perf_${_safe_rp}_rx=`_perf_bandwidth "${_rp_rx}"`"
		done

		unset rp_remote
	fi

	# File-system performance (FlashBlade)
	perf_fs_buffer=`${api_cmd_get}/file-systems/performance \
		-H "${CURL_OPTS_AUTH}" -H "${CURL_OPTS_JSON}"`

	if [[ -n "${perf_fs_buffer}" && ! "${perf_fs_buffer}" =~ '"errors"' ]]; then
		declare -a fsp_name

		fsp_name=(`echo "${perf_fs_buffer}" | "${JQ}" --unbuffered -r '(.items // [])[] | .name' 2>/dev/null | "${AWK}" 1 ORS=' '`)

		for count in "${!fsp_name[@]}"; do
			_frname="${fsp_name[count]}"
			_safe_fn=`echo "${_frname}" | tr '.-/ ' '____'`

			_fs_reads=`echo "${perf_fs_buffer}" | "${JQ}" --unbuffered -r ".items[${count}].reads_per_sec // 0"`
			_fs_writes=`echo "${perf_fs_buffer}" | "${JQ}" --unbuffered -r ".items[${count}].writes_per_sec // 0"`
			_fs_others=`echo "${perf_fs_buffer}" | "${JQ}" --unbuffered -r ".items[${count}].others_per_sec // 0"`
			_fs_r_bandwidth=`echo "${perf_fs_buffer}" | "${JQ}" --unbuffered -r ".items[${count}].read_bytes_per_sec // 0"`
			_fs_w_bandwidth=`echo "${perf_fs_buffer}" | "${JQ}" --unbuffered -r ".items[${count}].write_bytes_per_sec // 0"`
			_fs_bytes_op=`echo "${perf_fs_buffer}" | "${JQ}" --unbuffered -r ".items[${count}].bytes_per_op // 0"`
			_fs_bytes_rd=`echo "${perf_fs_buffer}" | "${JQ}" --unbuffered -r ".items[${count}].bytes_per_read // 0"`
			_fs_bytes_wr=`echo "${perf_fs_buffer}" | "${JQ}" --unbuffered -r ".items[${count}].bytes_per_write // 0"`
			_fs_lat_rd=`echo "${perf_fs_buffer}" | "${JQ}" --unbuffered -r ".items[${count}].usec_per_read_op // 0"`
			_fs_lat_wr=`echo "${perf_fs_buffer}" | "${JQ}" --unbuffered -r ".items[${count}].usec_per_write_op // 0"`
			_fs_lat_other=`echo "${perf_fs_buffer}" | "${JQ}" --unbuffered -r ".items[${count}].usec_per_other_op // 0"`
			_fs_total_iops=`echo "${_fs_reads} ${_fs_writes}" | "${AWK}" '{print $1+$2}'`
			_fs_r_bandwidth_h=`_fmt_bandwidth "${_fs_r_bandwidth}"`
			_fs_w_bandwidth_h=`_fmt_bandwidth "${_fs_w_bandwidth}"`
			_fs_lat_rd_ms=`echo "${_fs_lat_rd}" | "${AWK}" '{printf "%.3f ms",$1/1000}'`
			_fs_lat_wr_ms=`echo "${_fs_lat_wr}" | "${AWK}" '{printf "%.3f ms",$1/1000}'`

			if [[ -n "${verbose}" ]]; then
				pure_output+="${status_ok} - FS Perf ${_frname}: IOPS: ${_fs_total_iops} (R:${_fs_reads} W:${_fs_writes} Other:${_fs_others}/s)"
				pure_output+=" | BW: R:${_fs_r_bandwidth_h}/s W:${_fs_w_bandwidth_h}/s"
				pure_output+=" | Latency: R:${_fs_lat_rd_ms} W:${_fs_lat_wr_ms}\n"
			fi

			pure_perf+=" fs_perf_${_safe_fn}_reads=${_fs_reads}"
			pure_perf+=" fs_perf_${_safe_fn}_writes=${_fs_writes}"
			pure_perf+=" fs_perf_${_safe_fn}_others=${_fs_others}"
			pure_perf+=" fs_perf_${_safe_fn}_total_iops=${_fs_total_iops}"
			pure_perf+=" fs_perf_${_safe_fn}_read_bandwidth=`_perf_bandwidth "${_fs_r_bandwidth}"`"
			pure_perf+=" fs_perf_${_safe_fn}_write_bandwidth=`_perf_bandwidth "${_fs_w_bandwidth}"`"
			pure_perf+=" fs_perf_${_safe_fn}_bytes_per_op=${_fs_bytes_op}"
			pure_perf+=" fs_perf_${_safe_fn}_bytes_per_read=${_fs_bytes_rd}"
			pure_perf+=" fs_perf_${_safe_fn}_bytes_per_write=${_fs_bytes_wr}"
			pure_perf+=" fs_perf_${_safe_fn}_lat_read=${_fs_lat_rd}us"
			pure_perf+=" fs_perf_${_safe_fn}_lat_write=${_fs_lat_wr}us"
			pure_perf+=" fs_perf_${_safe_fn}_lat_other=${_fs_lat_other}us"
		done

		_fsp_tot_reads=`echo "${perf_fs_buffer}" | "${JQ}" --unbuffered -r '.total[0].reads_per_sec // 0' 2>/dev/null`
		_fsp_tot_writes=`echo "${perf_fs_buffer}" | "${JQ}" --unbuffered -r '.total[0].writes_per_sec // 0' 2>/dev/null`
		_fsp_tot_others=`echo "${perf_fs_buffer}" | "${JQ}" --unbuffered -r '.total[0].others_per_sec // 0' 2>/dev/null`
		_fsp_tot_r_bandwidth=`echo "${perf_fs_buffer}" | "${JQ}" --unbuffered -r '.total[0].read_bytes_per_sec // 0' 2>/dev/null`
		_fsp_tot_w_bandwidth=`echo "${perf_fs_buffer}" | "${JQ}" --unbuffered -r '.total[0].write_bytes_per_sec // 0' 2>/dev/null`
		_fsp_tot_bytes_op=`echo "${perf_fs_buffer}" | "${JQ}" --unbuffered -r '.total[0].bytes_per_op // 0' 2>/dev/null`
		_fsp_tot_bytes_rd=`echo "${perf_fs_buffer}" | "${JQ}" --unbuffered -r '.total[0].bytes_per_read // 0' 2>/dev/null`
		_fsp_tot_bytes_wr=`echo "${perf_fs_buffer}" | "${JQ}" --unbuffered -r '.total[0].bytes_per_write // 0' 2>/dev/null`
		_fsp_tot_lat_rd=`echo "${perf_fs_buffer}" | "${JQ}" --unbuffered -r '.total[0].usec_per_read_op // 0' 2>/dev/null`
		_fsp_tot_lat_wr=`echo "${perf_fs_buffer}" | "${JQ}" --unbuffered -r '.total[0].usec_per_write_op // 0' 2>/dev/null`
		_fsp_tot_lat_other=`echo "${perf_fs_buffer}" | "${JQ}" --unbuffered -r '.total[0].usec_per_other_op // 0' 2>/dev/null`
		pure_perf+=" fs_perf_total_reads=${_fsp_tot_reads}"
		pure_perf+=" fs_perf_total_writes=${_fsp_tot_writes}"
		pure_perf+=" fs_perf_total_others=${_fsp_tot_others}"
		pure_perf+=" fs_perf_total_read_bandwidth=`_perf_bandwidth "${_fsp_tot_r_bandwidth}"`"
		pure_perf+=" fs_perf_total_write_bandwidth=`_perf_bandwidth "${_fsp_tot_w_bandwidth}"`"
		pure_perf+=" fs_perf_total_bytes_per_op=${_fsp_tot_bytes_op}"
		pure_perf+=" fs_perf_total_bytes_per_read=${_fsp_tot_bytes_rd}"
		pure_perf+=" fs_perf_total_bytes_per_write=${_fsp_tot_bytes_wr}"
		pure_perf+=" fs_perf_total_lat_read=${_fsp_tot_lat_rd}us"
		pure_perf+=" fs_perf_total_lat_write=${_fsp_tot_lat_wr}us"
		pure_perf+=" fs_perf_total_lat_other=${_fsp_tot_lat_other}us"

		unset fsp_name
	fi

	# File-system group performance (FlashBlade)
	perf_fsg_buffer=`${api_cmd_get}/file-systems/groups/performance \
		-H "${CURL_OPTS_AUTH}" -H "${CURL_OPTS_JSON}"`

	if [[ -n "${perf_fsg_buffer}" && ! "${perf_fsg_buffer}" =~ '"errors"' ]]; then
		declare -a fsg_fs_name fsg_grp_name

		fsg_fs_name=( `echo "${perf_fsg_buffer}" | "${JQ}" --unbuffered -r \
			'(.items // [])[] | .file_system.name // "unknown"'                               2>/dev/null | "${AWK}" 1 ORS=' '`)
		fsg_grp_name=(`echo "${perf_fsg_buffer}" | "${JQ}" --unbuffered -r \
			'(.items // [])[] | .group.name // (.group.id | tostring) // "unknown"'            2>/dev/null | "${AWK}" 1 ORS=' '`)

		for count in "${!fsg_fs_name[@]}"; do
			_fsgfs="${fsg_fs_name[count]}"
			_fsggrp="${fsg_grp_name[count]}"
			_safe_fsg=`echo "${_fsgfs}_${_fsggrp}" | tr '.-/ ' '____'`

			_fsg_reads=`echo "${perf_fsg_buffer}" | "${JQ}" --unbuffered -r ".items[${count}].reads_per_sec // 0"`
			_fsg_writes=`echo "${perf_fsg_buffer}" | "${JQ}" --unbuffered -r ".items[${count}].writes_per_sec // 0"`
			_fsg_others=`echo "${perf_fsg_buffer}" | "${JQ}" --unbuffered -r ".items[${count}].others_per_sec // 0"`
			_fsg_r_bandwidth=`echo "${perf_fsg_buffer}" | "${JQ}" --unbuffered -r ".items[${count}].read_bytes_per_sec // 0"`
			_fsg_w_bandwidth=`echo "${perf_fsg_buffer}" | "${JQ}" --unbuffered -r ".items[${count}].write_bytes_per_sec // 0"`
			_fsg_bytes_op=`echo "${perf_fsg_buffer}" | "${JQ}" --unbuffered -r ".items[${count}].bytes_per_op // 0"`
			_fsg_bytes_rd=`echo "${perf_fsg_buffer}" | "${JQ}" --unbuffered -r ".items[${count}].bytes_per_read // 0"`
			_fsg_bytes_wr=`echo "${perf_fsg_buffer}" | "${JQ}" --unbuffered -r ".items[${count}].bytes_per_write // 0"`
			_fsg_lat_rd=`echo "${perf_fsg_buffer}" | "${JQ}" --unbuffered -r ".items[${count}].usec_per_read_op // 0"`
			_fsg_lat_wr=`echo "${perf_fsg_buffer}" | "${JQ}" --unbuffered -r ".items[${count}].usec_per_write_op // 0"`
			_fsg_lat_other=`echo "${perf_fsg_buffer}" | "${JQ}" --unbuffered -r ".items[${count}].usec_per_other_op // 0"`
			_fsg_total_iops=`echo "${_fsg_reads} ${_fsg_writes}" | "${AWK}" '{print $1+$2}'`
			_fsg_r_bandwidth_h=`_fmt_bandwidth "${_fsg_r_bandwidth}"`
			_fsg_w_bandwidth_h=`_fmt_bandwidth "${_fsg_w_bandwidth}"`
			_fsg_lat_rd_ms=`echo "${_fsg_lat_rd}" | "${AWK}" '{printf "%.3f ms",$1/1000}'`
			_fsg_lat_wr_ms=`echo "${_fsg_lat_wr}" | "${AWK}" '{printf "%.3f ms",$1/1000}'`

			if [[ -n "${verbose}" ]]; then
				pure_output+="${status_ok} - FS Group Perf ${array_name}/${_fsgfs}/${_fsggrp}: IOPS: ${_fsg_total_iops} (R:${_fsg_reads} W:${_fsg_writes} Other:${_fsg_others}/s)"
				pure_output+=" | BW: R:${_fsg_r_bandwidth_h}/s W:${_fsg_w_bandwidth_h}/s"
				pure_output+=" | Latency: R:${_fsg_lat_rd_ms} W:${_fsg_lat_wr_ms}\n"
			fi

			pure_perf+=" fs_group_${_safe_fsg}_reads=${_fsg_reads}"
			pure_perf+=" fs_group_${_safe_fsg}_writes=${_fsg_writes}"
			pure_perf+=" fs_group_${_safe_fsg}_others=${_fsg_others}"
			pure_perf+=" fs_group_${_safe_fsg}_total_iops=${_fsg_total_iops}"
			pure_perf+=" fs_group_${_safe_fsg}_read_bandwidth=`_perf_bandwidth "${_fsg_r_bandwidth}"`"
			pure_perf+=" fs_group_${_safe_fsg}_write_bandwidth=`_perf_bandwidth "${_fsg_w_bandwidth}"`"
			pure_perf+=" fs_group_${_safe_fsg}_bytes_per_op=${_fsg_bytes_op}"
			pure_perf+=" fs_group_${_safe_fsg}_bytes_per_read=${_fsg_bytes_rd}"
			pure_perf+=" fs_group_${_safe_fsg}_bytes_per_write=${_fsg_bytes_wr}"
			pure_perf+=" fs_group_${_safe_fsg}_lat_read=${_fsg_lat_rd}us"
			pure_perf+=" fs_group_${_safe_fsg}_lat_write=${_fsg_lat_wr}us"
			pure_perf+=" fs_group_${_safe_fsg}_lat_other=${_fsg_lat_other}us"
		done

		_fsg_tot_reads=`echo "${perf_fsg_buffer}" | "${JQ}" --unbuffered -r '.total[0].reads_per_sec // 0' 2>/dev/null`
		_fsg_tot_writes=`echo "${perf_fsg_buffer}" | "${JQ}" --unbuffered -r '.total[0].writes_per_sec // 0' 2>/dev/null`
		_fsg_tot_others=`echo "${perf_fsg_buffer}" | "${JQ}" --unbuffered -r '.total[0].others_per_sec // 0' 2>/dev/null`
		_fsg_tot_r_bandwidth=`echo "${perf_fsg_buffer}" | "${JQ}" --unbuffered -r '.total[0].read_bytes_per_sec // 0' 2>/dev/null`
		_fsg_tot_w_bandwidth=`echo "${perf_fsg_buffer}" | "${JQ}" --unbuffered -r '.total[0].write_bytes_per_sec // 0' 2>/dev/null`
		_fsg_tot_bytes_op=`echo "${perf_fsg_buffer}" | "${JQ}" --unbuffered -r '.total[0].bytes_per_op // 0' 2>/dev/null`
		_fsg_tot_bytes_rd=`echo "${perf_fsg_buffer}" | "${JQ}" --unbuffered -r '.total[0].bytes_per_read // 0' 2>/dev/null`
		_fsg_tot_bytes_wr=`echo "${perf_fsg_buffer}" | "${JQ}" --unbuffered -r '.total[0].bytes_per_write // 0' 2>/dev/null`
		_fsg_tot_lat_rd=`echo "${perf_fsg_buffer}" | "${JQ}" --unbuffered -r '.total[0].usec_per_read_op // 0' 2>/dev/null`
		_fsg_tot_lat_wr=`echo "${perf_fsg_buffer}" | "${JQ}" --unbuffered -r '.total[0].usec_per_write_op // 0' 2>/dev/null`
		_fsg_tot_lat_other=`echo "${perf_fsg_buffer}" | "${JQ}" --unbuffered -r '.total[0].usec_per_other_op // 0' 2>/dev/null`
		pure_perf+=" fs_group_total_reads=${_fsg_tot_reads}"
		pure_perf+=" fs_group_total_writes=${_fsg_tot_writes}"
		pure_perf+=" fs_group_total_others=${_fsg_tot_others}"
		pure_perf+=" fs_group_total_read_bandwidth=`_perf_bandwidth "${_fsg_tot_r_bandwidth}"`"
		pure_perf+=" fs_group_total_write_bandwidth=`_perf_bandwidth "${_fsg_tot_w_bandwidth}"`"
		pure_perf+=" fs_group_total_bytes_per_op=${_fsg_tot_bytes_op}"
		pure_perf+=" fs_group_total_bytes_per_read=${_fsg_tot_bytes_rd}"
		pure_perf+=" fs_group_total_bytes_per_write=${_fsg_tot_bytes_wr}"
		pure_perf+=" fs_group_total_lat_read=${_fsg_tot_lat_rd}us"
		pure_perf+=" fs_group_total_lat_write=${_fsg_tot_lat_wr}us"
		pure_perf+=" fs_group_total_lat_other=${_fsg_tot_lat_other}us"

		unset fsg_fs_name fsg_grp_name
	fi

	# File-system user performance (FlashBlade)
	perf_fsu_buffer=`${api_cmd_get}/file-systems/users/performance \
		-H "${CURL_OPTS_AUTH}" -H "${CURL_OPTS_JSON}"`

	if [[ -n "${perf_fsu_buffer}" && ! "${perf_fsu_buffer}" =~ '"errors"' ]]; then
		declare -a fsu_fs_name fsu_user_name

		fsu_fs_name=( `echo "${perf_fsu_buffer}" | "${JQ}" --unbuffered -r \
			'(.items // [])[] | .file_system.name // "unknown"'  2>/dev/null | "${AWK}" 1 ORS=' '`)
		fsu_user_name=(`echo "${perf_fsu_buffer}" | "${JQ}" --unbuffered -r \
			'(.items // [])[] | .user.name // (.user.id | tostring) // "unknown"' 2>/dev/null | "${AWK}" 1 ORS=' '`)

		for count in "${!fsu_fs_name[@]}"; do
			_fsufs="${fsu_fs_name[count]}"
			_fsuuser="${fsu_user_name[count]}"
			_safe_fsu=`echo "${_fsufs}_${_fsuuser}" | tr '.-/ ' '____'`

			_fsu_reads=`echo "${perf_fsu_buffer}" | "${JQ}" --unbuffered -r ".items[${count}].reads_per_sec // 0"`
			_fsu_writes=`echo "${perf_fsu_buffer}" | "${JQ}" --unbuffered -r ".items[${count}].writes_per_sec // 0"`
			_fsu_others=`echo "${perf_fsu_buffer}" | "${JQ}" --unbuffered -r ".items[${count}].others_per_sec // 0"`
			_fsu_r_bandwidth=`echo "${perf_fsu_buffer}" | "${JQ}" --unbuffered -r ".items[${count}].read_bytes_per_sec // 0"`
			_fsu_w_bandwidth=`echo "${perf_fsu_buffer}" | "${JQ}" --unbuffered -r ".items[${count}].write_bytes_per_sec // 0"`
			_fsu_bytes_op=`echo "${perf_fsu_buffer}" | "${JQ}" --unbuffered -r ".items[${count}].bytes_per_op // 0"`
			_fsu_bytes_rd=`echo "${perf_fsu_buffer}" | "${JQ}" --unbuffered -r ".items[${count}].bytes_per_read // 0"`
			_fsu_bytes_wr=`echo "${perf_fsu_buffer}" | "${JQ}" --unbuffered -r ".items[${count}].bytes_per_write // 0"`
			_fsu_lat_rd=`echo "${perf_fsu_buffer}" | "${JQ}" --unbuffered -r ".items[${count}].usec_per_read_op // 0"`
			_fsu_lat_wr=`echo "${perf_fsu_buffer}" | "${JQ}" --unbuffered -r ".items[${count}].usec_per_write_op // 0"`
			_fsu_lat_other=`echo "${perf_fsu_buffer}" | "${JQ}" --unbuffered -r ".items[${count}].usec_per_other_op // 0"`
			_fsu_total_iops=`echo "${_fsu_reads} ${_fsu_writes}" | "${AWK}" '{print $1+$2}'`
			_fsu_r_bandwidth_h=`_fmt_bandwidth "${_fsu_r_bandwidth}"`
			_fsu_w_bandwidth_h=`_fmt_bandwidth "${_fsu_w_bandwidth}"`
			_fsu_lat_rd_ms=`echo "${_fsu_lat_rd}" | "${AWK}" '{printf "%.3f ms",$1/1000}'`
			_fsu_lat_wr_ms=`echo "${_fsu_lat_wr}" | "${AWK}" '{printf "%.3f ms",$1/1000}'`

			if [[ -n "${verbose}" ]]; then
				pure_output+="${status_ok} - FS User Perf ${array_name}/${_fsufs}/${_fsuuser}: IOPS: ${_fsu_total_iops} (R:${_fsu_reads} W:${_fsu_writes} Other:${_fsu_others}/s)"
				pure_output+=" | BW: R:${_fsu_r_bandwidth_h}/s W:${_fsu_w_bandwidth_h}/s"
				pure_output+=" | Latency: R:${_fsu_lat_rd_ms} W:${_fsu_lat_wr_ms}\n"
			fi

			pure_perf+=" fs_user_${_safe_fsu}_reads=${_fsu_reads}"
			pure_perf+=" fs_user_${_safe_fsu}_writes=${_fsu_writes}"
			pure_perf+=" fs_user_${_safe_fsu}_others=${_fsu_others}"
			pure_perf+=" fs_user_${_safe_fsu}_total_iops=${_fsu_total_iops}"
			pure_perf+=" fs_user_${_safe_fsu}_read_bandwidth=`_perf_bandwidth "${_fsu_r_bandwidth}"`"
			pure_perf+=" fs_user_${_safe_fsu}_write_bandwidth=`_perf_bandwidth "${_fsu_w_bandwidth}"`"
			pure_perf+=" fs_user_${_safe_fsu}_bytes_per_op=${_fsu_bytes_op}"
			pure_perf+=" fs_user_${_safe_fsu}_bytes_per_read=${_fsu_bytes_rd}"
			pure_perf+=" fs_user_${_safe_fsu}_bytes_per_write=${_fsu_bytes_wr}"
			pure_perf+=" fs_user_${_safe_fsu}_lat_read=${_fsu_lat_rd}us"
			pure_perf+=" fs_user_${_safe_fsu}_lat_write=${_fsu_lat_wr}us"
			pure_perf+=" fs_user_${_safe_fsu}_lat_other=${_fsu_lat_other}us"
		done

		_fsu_tot_reads=`echo "${perf_fsu_buffer}" | "${JQ}" --unbuffered -r '.total[0].reads_per_sec // 0' 2>/dev/null`
		_fsu_tot_writes=`echo "${perf_fsu_buffer}" | "${JQ}" --unbuffered -r '.total[0].writes_per_sec // 0' 2>/dev/null`
		_fsu_tot_others=`echo "${perf_fsu_buffer}" | "${JQ}" --unbuffered -r '.total[0].others_per_sec // 0' 2>/dev/null`
		_fsu_tot_r_bandwidth=`echo "${perf_fsu_buffer}" | "${JQ}" --unbuffered -r '.total[0].read_bytes_per_sec // 0' 2>/dev/null`
		_fsu_tot_w_bandwidth=`echo "${perf_fsu_buffer}" | "${JQ}" --unbuffered -r '.total[0].write_bytes_per_sec // 0' 2>/dev/null`
		_fsu_tot_bytes_op=`echo "${perf_fsu_buffer}" | "${JQ}" --unbuffered -r '.total[0].bytes_per_op // 0' 2>/dev/null`
		_fsu_tot_bytes_rd=`echo "${perf_fsu_buffer}" | "${JQ}" --unbuffered -r '.total[0].bytes_per_read // 0' 2>/dev/null`
		_fsu_tot_bytes_wr=`echo "${perf_fsu_buffer}" | "${JQ}" --unbuffered -r '.total[0].bytes_per_write // 0' 2>/dev/null`
		_fsu_tot_lat_rd=`echo "${perf_fsu_buffer}" | "${JQ}" --unbuffered -r '.total[0].usec_per_read_op // 0' 2>/dev/null`
		_fsu_tot_lat_wr=`echo "${perf_fsu_buffer}" | "${JQ}" --unbuffered -r '.total[0].usec_per_write_op // 0' 2>/dev/null`
		_fsu_tot_lat_other=`echo "${perf_fsu_buffer}" | "${JQ}" --unbuffered -r '.total[0].usec_per_other_op // 0' 2>/dev/null`
		pure_perf+=" fs_user_total_reads=${_fsu_tot_reads}"
		pure_perf+=" fs_user_total_writes=${_fsu_tot_writes}"
		pure_perf+=" fs_user_total_others=${_fsu_tot_others}"
		pure_perf+=" fs_user_total_read_bandwidth=`_perf_bandwidth "${_fsu_tot_r_bandwidth}"`"
		pure_perf+=" fs_user_total_write_bandwidth=`_perf_bandwidth "${_fsu_tot_w_bandwidth}"`"
		pure_perf+=" fs_user_total_bytes_per_op=${_fsu_tot_bytes_op}"
		pure_perf+=" fs_user_total_bytes_per_read=${_fsu_tot_bytes_rd}"
		pure_perf+=" fs_user_total_bytes_per_write=${_fsu_tot_bytes_wr}"
		pure_perf+=" fs_user_total_lat_read=${_fsu_tot_lat_rd}us"
		pure_perf+=" fs_user_total_lat_write=${_fsu_tot_lat_wr}us"
		pure_perf+=" fs_user_total_lat_other=${_fsu_tot_lat_other}us"

		unset fsu_fs_name fsu_user_name
	fi

	# Bucket-level performance (FlashBlade S3)
	perf_bu_buffer=`${api_cmd_get}/buckets/performance \
		-H "${CURL_OPTS_AUTH}" -H "${CURL_OPTS_JSON}"`

	if [[ -n "${perf_bu_buffer}" && ! "${perf_bu_buffer}" =~ '"errors"' ]]; then
		declare -a bup_name

		bup_name=(`echo "${perf_bu_buffer}" | "${JQ}" --unbuffered -r '(.items // [])[] | .name' 2>/dev/null | "${AWK}" 1 ORS=' '`)

		for count in "${!bup_name[@]}"; do
			_brname="${bup_name[count]}"
			_safe_bn=`echo "${_brname}" | tr '.-/ ' '____'`

			_bu_r_iops=`echo "${perf_bu_buffer}" | "${JQ}" --unbuffered -r ".items[${count}].reads_per_sec // 0"`
			_bu_w_iops=`echo "${perf_bu_buffer}" | "${JQ}" --unbuffered -r ".items[${count}].writes_per_sec // 0"`
			_bu_r_bandwidth=`echo "${perf_bu_buffer}" | "${JQ}" --unbuffered -r ".items[${count}].input_per_sec // 0"`
			_bu_w_bandwidth=`echo "${perf_bu_buffer}" | "${JQ}" --unbuffered -r ".items[${count}].output_per_sec // 0"`
			_bu_r_lat=`echo "${perf_bu_buffer}" | "${JQ}" --unbuffered -r ".items[${count}].usec_per_read_op // 0"`
			_bu_w_lat=`echo "${perf_bu_buffer}" | "${JQ}" --unbuffered -r ".items[${count}].usec_per_write_op // 0"`

			_bu_total_iops=`echo "${_bu_r_iops} ${_bu_w_iops}" | "${AWK}" '{print $1+$2}'`
			_bu_r_bandwidth_h=`_fmt_bandwidth "${_bu_r_bandwidth}"`
			_bu_w_bandwidth_h=`_fmt_bandwidth "${_bu_w_bandwidth}"`
			_bu_r_lat_ms=`echo "${_bu_r_lat}" | "${AWK}" '{printf "%.3f ms",$1/1000}'`
			_bu_w_lat_ms=`echo "${_bu_w_lat}" | "${AWK}" '{printf "%.3f ms",$1/1000}'`

			if [[ -n "${verbose}" ]]; then
				pure_output+="${status_ok} - Bucket Perf ${_brname}: IOPS: ${_bu_total_iops} (R:${_bu_r_iops} W:${_bu_w_iops})"
				pure_output+=" | BW: R:${_bu_r_bandwidth_h}/s W:${_bu_w_bandwidth_h}/s"
				pure_output+=" | Latency: R:${_bu_r_lat_ms} W:${_bu_w_lat_ms}\n"
			fi

			pure_perf+=" bucket_${_safe_bn}_read_iops=${_bu_r_iops}"
			pure_perf+=" bucket_${_safe_bn}_write_iops=${_bu_w_iops}"
			pure_perf+=" bucket_${_safe_bn}_total_iops=${_bu_total_iops}"
			pure_perf+=" bucket_${_safe_bn}_read_bandwidth=`_perf_bandwidth "${_bu_r_bandwidth}"`"
			pure_perf+=" bucket_${_safe_bn}_write_bandwidth=`_perf_bandwidth "${_bu_w_bandwidth}"`"
			pure_perf+=" bucket_${_safe_bn}_read_latency=${_bu_r_lat}us"
			pure_perf+=" bucket_${_safe_bn}_write_latency=${_bu_w_lat}us"
		done

		unset bup_name
	fi

	# Per-bucket S3-specific performance (FlashBlade)
	perf_bus3_buffer=`${api_cmd_get}/buckets/s3-specific-performance \
		-H "${CURL_OPTS_AUTH}" -H "${CURL_OPTS_JSON}"`

	if [[ -n "${perf_bus3_buffer}" && ! "${perf_bus3_buffer}" =~ '"errors"' ]]; then
		declare -a bus3_name

		bus3_name=(`echo "${perf_bus3_buffer}" | "${JQ}" --unbuffered -r '(.items // [])[] | .name' 2>/dev/null | "${AWK}" 1 ORS=' '`)

		for count in "${!bus3_name[@]}"; do
			_bsname="${bus3_name[count]}"
			_safe_bs=`echo "${_bsname}" | tr '.-/ ' '____'`

			_bs_rd_obj=`echo "${perf_bus3_buffer}" | "${JQ}" --unbuffered -r ".items[${count}].read_objects_per_sec // 0"`
			_bs_wr_obj=`echo "${perf_bus3_buffer}" | "${JQ}" --unbuffered -r ".items[${count}].write_objects_per_sec // 0"`
			_bs_rd_bkt=`echo "${perf_bus3_buffer}" | "${JQ}" --unbuffered -r ".items[${count}].read_buckets_per_sec // 0"`
			_bs_wr_bkt=`echo "${perf_bus3_buffer}" | "${JQ}" --unbuffered -r ".items[${count}].write_buckets_per_sec // 0"`
			_bs_others=`echo "${perf_bus3_buffer}" | "${JQ}" --unbuffered -r ".items[${count}].others_per_sec // 0"`
			_bs_lat_rd_obj=`echo "${perf_bus3_buffer}" | "${JQ}" --unbuffered -r ".items[${count}].usec_per_read_object_op // 0"`
			_bs_lat_wr_obj=`echo "${perf_bus3_buffer}" | "${JQ}" --unbuffered -r ".items[${count}].usec_per_write_object_op // 0"`
			_bs_lat_rd_bkt=`echo "${perf_bus3_buffer}" | "${JQ}" --unbuffered -r ".items[${count}].usec_per_read_bucket_op // 0"`
			_bs_lat_wr_bkt=`echo "${perf_bus3_buffer}" | "${JQ}" --unbuffered -r ".items[${count}].usec_per_write_bucket_op // 0"`
			_bs_lat_other=`echo "${perf_bus3_buffer}" | "${JQ}" --unbuffered -r ".items[${count}].usec_per_other_op // 0"`
			_bs_lat_rd_ms=`echo "${_bs_lat_rd_obj}" | "${AWK}" '{printf "%.3f ms",$1/1000}'`
			_bs_lat_wr_ms=`echo "${_bs_lat_wr_obj}" | "${AWK}" '{printf "%.3f ms",$1/1000}'`

			if [[ -n "${verbose}" ]]; then
				pure_output+="${status_ok} - S3 Bucket Perf ${_bsname}: ReadObj:${_bs_rd_obj}/s WriteObj:${_bs_wr_obj}/s"
				pure_output+=" | ReadBkt:${_bs_rd_bkt}/s WriteBkt:${_bs_wr_bkt}/s | Other:${_bs_others}/s"
				pure_output+=" | Latency Obj: R:${_bs_lat_rd_ms} W:${_bs_lat_wr_ms}\n"
			fi

			pure_perf+=" bucket_s3_${_safe_bs}_read_objects=${_bs_rd_obj}"
			pure_perf+=" bucket_s3_${_safe_bs}_write_objects=${_bs_wr_obj}"
			pure_perf+=" bucket_s3_${_safe_bs}_read_buckets=${_bs_rd_bkt}"
			pure_perf+=" bucket_s3_${_safe_bs}_write_buckets=${_bs_wr_bkt}"
			pure_perf+=" bucket_s3_${_safe_bs}_others=${_bs_others}"
			pure_perf+=" bucket_s3_${_safe_bs}_lat_read_object=${_bs_lat_rd_obj}us"
			pure_perf+=" bucket_s3_${_safe_bs}_lat_write_object=${_bs_lat_wr_obj}us"
			pure_perf+=" bucket_s3_${_safe_bs}_lat_read_bucket=${_bs_lat_rd_bkt}us"
			pure_perf+=" bucket_s3_${_safe_bs}_lat_write_bucket=${_bs_lat_wr_bkt}us"
			pure_perf+=" bucket_s3_${_safe_bs}_lat_other=${_bs_lat_other}us"
		done

		_bs_tot_rd_obj=`echo "${perf_bus3_buffer}" | "${JQ}" --unbuffered -r '.total[0].read_objects_per_sec // 0' 2>/dev/null`
		_bs_tot_wr_obj=`echo "${perf_bus3_buffer}" | "${JQ}" --unbuffered -r '.total[0].write_objects_per_sec // 0' 2>/dev/null`
		_bs_tot_rd_bkt=`echo "${perf_bus3_buffer}" | "${JQ}" --unbuffered -r '.total[0].read_buckets_per_sec // 0' 2>/dev/null`
		_bs_tot_wr_bkt=`echo "${perf_bus3_buffer}" | "${JQ}" --unbuffered -r '.total[0].write_buckets_per_sec // 0' 2>/dev/null`
		_bs_tot_others=`echo "${perf_bus3_buffer}" | "${JQ}" --unbuffered -r '.total[0].others_per_sec // 0' 2>/dev/null`
		_bs_tot_lat_rd_obj=`echo "${perf_bus3_buffer}" | "${JQ}" --unbuffered -r '.total[0].usec_per_read_object_op // 0' 2>/dev/null`
		_bs_tot_lat_wr_obj=`echo "${perf_bus3_buffer}" | "${JQ}" --unbuffered -r '.total[0].usec_per_write_object_op // 0' 2>/dev/null`
		_bs_tot_lat_rd_bkt=`echo "${perf_bus3_buffer}" | "${JQ}" --unbuffered -r '.total[0].usec_per_read_bucket_op // 0' 2>/dev/null`
		_bs_tot_lat_wr_bkt=`echo "${perf_bus3_buffer}" | "${JQ}" --unbuffered -r '.total[0].usec_per_write_bucket_op // 0' 2>/dev/null`
		_bs_tot_lat_other=`echo "${perf_bus3_buffer}" | "${JQ}" --unbuffered -r '.total[0].usec_per_other_op // 0' 2>/dev/null`

		pure_perf+=" bucket_s3_total_read_objects=${_bs_tot_rd_obj}"
		pure_perf+=" bucket_s3_total_write_objects=${_bs_tot_wr_obj}"
		pure_perf+=" bucket_s3_total_read_buckets=${_bs_tot_rd_bkt}"
		pure_perf+=" bucket_s3_total_write_buckets=${_bs_tot_wr_bkt}"
		pure_perf+=" bucket_s3_total_others=${_bs_tot_others}"
		pure_perf+=" bucket_s3_total_lat_read_object=${_bs_tot_lat_rd_obj}us"
		pure_perf+=" bucket_s3_total_lat_write_object=${_bs_tot_lat_wr_obj}us"
		pure_perf+=" bucket_s3_total_lat_read_bucket=${_bs_tot_lat_rd_bkt}us"
		pure_perf+=" bucket_s3_total_lat_write_bucket=${_bs_tot_lat_wr_bkt}us"
		pure_perf+=" bucket_s3_total_lat_other=${_bs_tot_lat_other}us"

		unset bus3_name
	fi

	# HTTP-specific performance (FlashBlade)
	perf_http_buffer=`${api_cmd_get}/arrays/http-specific-performance \
		-H "${CURL_OPTS_AUTH}" -H "${CURL_OPTS_JSON}"`

	if [[ -n "${perf_http_buffer}" && ! "${perf_http_buffer}" =~ '"errors"' ]]; then
		_http_cnt=`echo "${perf_http_buffer}" | "${JQ}" --unbuffered -r '(.items // []) | length' 2>/dev/null`
		if [[ "${_http_cnt}" -gt 0 ]]; then
			_http_rd_files=`echo "${perf_http_buffer}" | "${JQ}" --unbuffered -r '.items[0].read_files_per_sec // 0'`
			_http_wr_files=`echo "${perf_http_buffer}" | "${JQ}" --unbuffered -r '.items[0].write_files_per_sec // 0'`
			_http_rd_dirs=`echo "${perf_http_buffer}" | "${JQ}" --unbuffered -r '.items[0].read_dirs_per_sec // 0'`
			_http_wr_dirs=`echo "${perf_http_buffer}" | "${JQ}" --unbuffered -r '.items[0].write_dirs_per_sec // 0'`
			_http_others=`echo "${perf_http_buffer}" | "${JQ}" --unbuffered -r '.items[0].others_per_sec // 0'`
			_http_lat_rd_file=`echo "${perf_http_buffer}" | "${JQ}" --unbuffered -r '.items[0].usec_per_read_file_op // 0'`
			_http_lat_wr_file=`echo "${perf_http_buffer}" | "${JQ}" --unbuffered -r '.items[0].usec_per_write_file_op // 0'`
			_http_lat_rd_dir=`echo "${perf_http_buffer}" | "${JQ}" --unbuffered -r '.items[0].usec_per_read_dir_op // 0'`
			_http_lat_wr_dir=`echo "${perf_http_buffer}" | "${JQ}" --unbuffered -r '.items[0].usec_per_write_dir_op // 0'`
			_http_lat_other=`echo "${perf_http_buffer}" | "${JQ}" --unbuffered -r '.items[0].usec_per_other_op // 0'`
			_http_lat_rd_ms=`echo "${_http_lat_rd_file}" | "${AWK}" '{printf "%.3f ms",$1/1000}'`
			_http_lat_wr_ms=`echo "${_http_lat_wr_file}" | "${AWK}" '{printf "%.3f ms",$1/1000}'`
			if [[ -n "${verbose}" ]]; then
				pure_output+="${status_ok} - HTTP Perf ${array_name}: ReadFiles:${_http_rd_files}/s WriteFiles:${_http_wr_files}/s"
				pure_output+=" | ReadDirs:${_http_rd_dirs}/s WriteDirs:${_http_wr_dirs}/s | Other:${_http_others}/s"
				pure_output+=" | Latency File: R:${_http_lat_rd_ms} W:${_http_lat_wr_ms}\n"
			fi
			pure_perf+=" ${array_name}_http_read_files=${_http_rd_files}"
			pure_perf+=" ${array_name}_http_write_files=${_http_wr_files}"
			pure_perf+=" ${array_name}_http_read_dirs=${_http_rd_dirs}"
			pure_perf+=" ${array_name}_http_write_dirs=${_http_wr_dirs}"
			pure_perf+=" ${array_name}_http_others=${_http_others}"
			pure_perf+=" ${array_name}_http_lat_read_file=${_http_lat_rd_file}us"
			pure_perf+=" ${array_name}_http_lat_write_file=${_http_lat_wr_file}us"
			pure_perf+=" ${array_name}_http_lat_read_dir=${_http_lat_rd_dir}us"
			pure_perf+=" ${array_name}_http_lat_write_dir=${_http_lat_wr_dir}us"
			pure_perf+=" ${array_name}_http_lat_other=${_http_lat_other}us"
		fi
	fi

	# NFS-specific performance (FlashBlade)
	perf_nfs_buffer=`${api_cmd_get}/arrays/nfs-specific-performance \
		-H "${CURL_OPTS_AUTH}" -H "${CURL_OPTS_JSON}"`

	if [[ -n "${perf_nfs_buffer}" && ! "${perf_nfs_buffer}" =~ '"errors"' ]]; then
		_nfs_cnt=`echo "${perf_nfs_buffer}" | "${JQ}" --unbuffered -r '(.items // []) | length' 2>/dev/null`
		if [[ "${_nfs_cnt}" -gt 0 ]]; then
			_nfs_reads=`echo "${perf_nfs_buffer}" | "${JQ}" --unbuffered -r '.items[0].reads_per_sec // 0'`
			_nfs_writes=`echo "${perf_nfs_buffer}" | "${JQ}" --unbuffered -r '.items[0].writes_per_sec // 0'`
			_nfs_creates=`echo "${perf_nfs_buffer}" | "${JQ}" --unbuffered -r '.items[0].creates_per_sec // 0'`
			_nfs_removes=`echo "${perf_nfs_buffer}" | "${JQ}" --unbuffered -r '.items[0].removes_per_sec // 0'`
			_nfs_renames=`echo "${perf_nfs_buffer}" | "${JQ}" --unbuffered -r '.items[0].renames_per_sec // 0'`
			_nfs_mkdirs=`echo "${perf_nfs_buffer}" | "${JQ}" --unbuffered -r '.items[0].mkdirs_per_sec // 0'`
			_nfs_rmdirs=`echo "${perf_nfs_buffer}" | "${JQ}" --unbuffered -r '.items[0].rmdirs_per_sec // 0'`
			_nfs_getattrs=`echo "${perf_nfs_buffer}" | "${JQ}" --unbuffered -r '.items[0].getattrs_per_sec // 0'`
			_nfs_setattrs=`echo "${perf_nfs_buffer}" | "${JQ}" --unbuffered -r '.items[0].setattrs_per_sec // 0'`
			_nfs_lookups=`echo "${perf_nfs_buffer}" | "${JQ}" --unbuffered -r '.items[0].lookups_per_sec // 0'`
			_nfs_accesses=`echo "${perf_nfs_buffer}" | "${JQ}" --unbuffered -r '.items[0].accesses_per_sec // 0'`
			_nfs_readdirs=`echo "${perf_nfs_buffer}" | "${JQ}" --unbuffered -r '.items[0].readdirs_per_sec // 0'`
			_nfs_readlinks=`echo "${perf_nfs_buffer}" | "${JQ}" --unbuffered -r '.items[0].readlinks_per_sec // 0'`
			_nfs_symlinks=`echo "${perf_nfs_buffer}" | "${JQ}" --unbuffered -r '.items[0].symlinks_per_sec // 0'`
			_nfs_links=`echo "${perf_nfs_buffer}" | "${JQ}" --unbuffered -r '.items[0].links_per_sec // 0'`
			_nfs_rdirplus=`echo "${perf_nfs_buffer}" | "${JQ}" --unbuffered -r '.items[0].readdirpluses_per_sec // 0'`
			_nfs_fsinfos=`echo "${perf_nfs_buffer}" | "${JQ}" --unbuffered -r '.items[0].fsinfos_per_sec // 0'`
			_nfs_fsstats=`echo "${perf_nfs_buffer}" | "${JQ}" --unbuffered -r '.items[0].fsstats_per_sec // 0'`
			_nfs_pathconfs=`echo "${perf_nfs_buffer}" | "${JQ}" --unbuffered -r '.items[0].pathconfs_per_sec // 0'`
			_nfs_agg_fmeta_rd=`echo "${perf_nfs_buffer}" | "${JQ}" --unbuffered -r '.items[0].aggregate_file_metadata_reads_per_sec // 0'`
			_nfs_agg_fmeta_cr=`echo "${perf_nfs_buffer}" | "${JQ}" --unbuffered -r '.items[0].aggregate_file_metadata_creates_per_sec // 0'`
			_nfs_agg_fmeta_mo=`echo "${perf_nfs_buffer}" | "${JQ}" --unbuffered -r '.items[0].aggregate_file_metadata_modifies_per_sec // 0'`
			_nfs_agg_smeta_rd=`echo "${perf_nfs_buffer}" | "${JQ}" --unbuffered -r '.items[0].aggregate_share_metadata_reads_per_sec // 0'`
			_nfs_agg_other=`echo "${perf_nfs_buffer}" | "${JQ}" --unbuffered -r '.items[0].aggregate_other_per_sec // 0'`
			_nfs_lat_read=`echo "${perf_nfs_buffer}" | "${JQ}" --unbuffered -r '.items[0].usec_per_read_op // 0'`
			_nfs_lat_write=`echo "${perf_nfs_buffer}" | "${JQ}" --unbuffered -r '.items[0].usec_per_write_op // 0'`
			_nfs_lat_create=`echo "${perf_nfs_buffer}" | "${JQ}" --unbuffered -r '.items[0].usec_per_create_op // 0'`
			_nfs_lat_remove=`echo "${perf_nfs_buffer}" | "${JQ}" --unbuffered -r '.items[0].usec_per_remove_op // 0'`
			_nfs_lat_rename=`echo "${perf_nfs_buffer}" | "${JQ}" --unbuffered -r '.items[0].usec_per_rename_op // 0'`
			_nfs_lat_mkdir=`echo "${perf_nfs_buffer}" | "${JQ}" --unbuffered -r '.items[0].usec_per_mkdir_op // 0'`
			_nfs_lat_rmdir=`echo "${perf_nfs_buffer}" | "${JQ}" --unbuffered -r '.items[0].usec_per_rmdir_op // 0'`
			_nfs_lat_getattr=`echo "${perf_nfs_buffer}" | "${JQ}" --unbuffered -r '.items[0].usec_per_getattr_op // 0'`
			_nfs_lat_setattr=`echo "${perf_nfs_buffer}" | "${JQ}" --unbuffered -r '.items[0].usec_per_setattr_op // 0'`
			_nfs_lat_lookup=`echo "${perf_nfs_buffer}" | "${JQ}" --unbuffered -r '.items[0].usec_per_lookup_op // 0'`
			_nfs_lat_access=`echo "${perf_nfs_buffer}" | "${JQ}" --unbuffered -r '.items[0].usec_per_access_op // 0'`
			_nfs_lat_readdir=`echo "${perf_nfs_buffer}" | "${JQ}" --unbuffered -r '.items[0].usec_per_readdir_op // 0'`
			_nfs_lat_readlink=`echo "${perf_nfs_buffer}" | "${JQ}" --unbuffered -r '.items[0].usec_per_readlink_op // 0'`
			_nfs_lat_symlink=`echo "${perf_nfs_buffer}" | "${JQ}" --unbuffered -r '.items[0].usec_per_symlink_op // 0'`
			_nfs_lat_link=`echo "${perf_nfs_buffer}" | "${JQ}" --unbuffered -r '.items[0].usec_per_link_op // 0'`
			_nfs_lat_rdirplus=`echo "${perf_nfs_buffer}" | "${JQ}" --unbuffered -r '.items[0].usec_per_readdirplus_op // 0'`
			_nfs_lat_fsinfo=`echo "${perf_nfs_buffer}" | "${JQ}" --unbuffered -r '.items[0].usec_per_fsinfo_op // 0'`
			_nfs_lat_fsstat=`echo "${perf_nfs_buffer}" | "${JQ}" --unbuffered -r '.items[0].usec_per_fsstat_op // 0'`
			_nfs_lat_pathconf=`echo "${perf_nfs_buffer}" | "${JQ}" --unbuffered -r '.items[0].usec_per_pathconf_op // 0'`
			_nfs_lat_read_ms=`echo "${_nfs_lat_read}" | "${AWK}" '{printf "%.3f ms",$1/1000}'`
			_nfs_lat_write_ms=`echo "${_nfs_lat_write}" | "${AWK}" '{printf "%.3f ms",$1/1000}'`
			if [[ -n "${verbose}" ]]; then
				pure_output+="${status_ok} - NFS Perf ${array_name}: R:${_nfs_reads}/s W:${_nfs_writes}/s"
				pure_output+=" | Creates:${_nfs_creates}/s Removes:${_nfs_removes}/s Renames:${_nfs_renames}/s"
				pure_output+=" | Getattr:${_nfs_getattrs}/s Lookup:${_nfs_lookups}/s Access:${_nfs_accesses}/s"
				pure_output+=" | Latency: R:${_nfs_lat_read_ms} W:${_nfs_lat_write_ms}\n"
			fi
			pure_perf+=" ${array_name}_nfs_reads=${_nfs_reads}"
			pure_perf+=" ${array_name}_nfs_writes=${_nfs_writes}"
			pure_perf+=" ${array_name}_nfs_creates=${_nfs_creates}"
			pure_perf+=" ${array_name}_nfs_removes=${_nfs_removes}"
			pure_perf+=" ${array_name}_nfs_renames=${_nfs_renames}"
			pure_perf+=" ${array_name}_nfs_mkdirs=${_nfs_mkdirs}"
			pure_perf+=" ${array_name}_nfs_rmdirs=${_nfs_rmdirs}"
			pure_perf+=" ${array_name}_nfs_getattrs=${_nfs_getattrs}"
			pure_perf+=" ${array_name}_nfs_setattrs=${_nfs_setattrs}"
			pure_perf+=" ${array_name}_nfs_lookups=${_nfs_lookups}"
			pure_perf+=" ${array_name}_nfs_accesses=${_nfs_accesses}"
			pure_perf+=" ${array_name}_nfs_readdirs=${_nfs_readdirs}"
			pure_perf+=" ${array_name}_nfs_readlinks=${_nfs_readlinks}"
			pure_perf+=" ${array_name}_nfs_symlinks=${_nfs_symlinks}"
			pure_perf+=" ${array_name}_nfs_links=${_nfs_links}"
			pure_perf+=" ${array_name}_nfs_readdirpluses=${_nfs_rdirplus}"
			pure_perf+=" ${array_name}_nfs_fsinfos=${_nfs_fsinfos}"
			pure_perf+=" ${array_name}_nfs_fsstats=${_nfs_fsstats}"
			pure_perf+=" ${array_name}_nfs_pathconfs=${_nfs_pathconfs}"
			pure_perf+=" ${array_name}_nfs_agg_file_meta_reads=${_nfs_agg_fmeta_rd}"
			pure_perf+=" ${array_name}_nfs_agg_file_meta_creates=${_nfs_agg_fmeta_cr}"
			pure_perf+=" ${array_name}_nfs_agg_file_meta_modifies=${_nfs_agg_fmeta_mo}"
			pure_perf+=" ${array_name}_nfs_agg_share_meta_reads=${_nfs_agg_smeta_rd}"
			pure_perf+=" ${array_name}_nfs_agg_other=${_nfs_agg_other}"
			pure_perf+=" ${array_name}_nfs_lat_read=${_nfs_lat_read}us"
			pure_perf+=" ${array_name}_nfs_lat_write=${_nfs_lat_write}us"
			pure_perf+=" ${array_name}_nfs_lat_create=${_nfs_lat_create}us"
			pure_perf+=" ${array_name}_nfs_lat_remove=${_nfs_lat_remove}us"
			pure_perf+=" ${array_name}_nfs_lat_rename=${_nfs_lat_rename}us"
			pure_perf+=" ${array_name}_nfs_lat_mkdir=${_nfs_lat_mkdir}us"
			pure_perf+=" ${array_name}_nfs_lat_rmdir=${_nfs_lat_rmdir}us"
			pure_perf+=" ${array_name}_nfs_lat_getattr=${_nfs_lat_getattr}us"
			pure_perf+=" ${array_name}_nfs_lat_setattr=${_nfs_lat_setattr}us"
			pure_perf+=" ${array_name}_nfs_lat_lookup=${_nfs_lat_lookup}us"
			pure_perf+=" ${array_name}_nfs_lat_access=${_nfs_lat_access}us"
			pure_perf+=" ${array_name}_nfs_lat_readdir=${_nfs_lat_readdir}us"
			pure_perf+=" ${array_name}_nfs_lat_readlink=${_nfs_lat_readlink}us"
			pure_perf+=" ${array_name}_nfs_lat_symlink=${_nfs_lat_symlink}us"
			pure_perf+=" ${array_name}_nfs_lat_link=${_nfs_lat_link}us"
			pure_perf+=" ${array_name}_nfs_lat_readdirplus=${_nfs_lat_rdirplus}us"
			pure_perf+=" ${array_name}_nfs_lat_fsinfo=${_nfs_lat_fsinfo}us"
			pure_perf+=" ${array_name}_nfs_lat_fsstat=${_nfs_lat_fsstat}us"
			pure_perf+=" ${array_name}_nfs_lat_pathconf=${_nfs_lat_pathconf}us"
		fi
	fi

	# NFS client performance (per-client breakdown)
	perf_cli_buffer=`${api_cmd_get}/arrays/clients/performance \
		-H "${CURL_OPTS_AUTH}" -H "${CURL_OPTS_JSON}"`

	if [[ -n "${perf_cli_buffer}" && ! "${perf_cli_buffer}" =~ '"errors"' ]]; then
		declare -a cli_name

		cli_name=(`echo "${perf_cli_buffer}" | "${JQ}" --unbuffered -r '(.items // [])[] | .name' 2>/dev/null | "${AWK}" 1 ORS=' '`)

		for count in "${!cli_name[@]}"; do
			_cliname="${cli_name[count]}"
			_safe_cli=`echo "${_cliname}" | tr '.-/: ' '_____'`

			_cli_reads=`echo "${perf_cli_buffer}" | "${JQ}" --unbuffered -r ".items[${count}].reads_per_sec // 0"`
			_cli_writes=`echo "${perf_cli_buffer}" | "${JQ}" --unbuffered -r ".items[${count}].writes_per_sec // 0"`
			_cli_others=`echo "${perf_cli_buffer}" | "${JQ}" --unbuffered -r ".items[${count}].others_per_sec // 0"`
			_cli_r_bandwidth=`echo "${perf_cli_buffer}" | "${JQ}" --unbuffered -r ".items[${count}].read_bytes_per_sec // 0"`
			_cli_w_bandwidth=`echo "${perf_cli_buffer}" | "${JQ}" --unbuffered -r ".items[${count}].write_bytes_per_sec // 0"`
			_cli_bytes_op=`echo "${perf_cli_buffer}" | "${JQ}" --unbuffered -r ".items[${count}].bytes_per_op // 0"`
			_cli_bytes_rd=`echo "${perf_cli_buffer}" | "${JQ}" --unbuffered -r ".items[${count}].bytes_per_read // 0"`
			_cli_bytes_wr=`echo "${perf_cli_buffer}" | "${JQ}" --unbuffered -r ".items[${count}].bytes_per_write // 0"`
			_cli_lat_rd=`echo "${perf_cli_buffer}" | "${JQ}" --unbuffered -r ".items[${count}].usec_per_read_op // 0"`
			_cli_lat_wr=`echo "${perf_cli_buffer}" | "${JQ}" --unbuffered -r ".items[${count}].usec_per_write_op // 0"`
			_cli_lat_other=`echo "${perf_cli_buffer}" | "${JQ}" --unbuffered -r ".items[${count}].usec_per_other_op // 0"`
			_cli_r_bandwidth_h=`_fmt_bandwidth "${_cli_r_bandwidth}"`
			_cli_w_bandwidth_h=`_fmt_bandwidth "${_cli_w_bandwidth}"`
			_cli_lat_rd_ms=`echo "${_cli_lat_rd}" | "${AWK}" '{printf "%.3f ms",$1/1000}'`
			_cli_lat_wr_ms=`echo "${_cli_lat_wr}" | "${AWK}" '{printf "%.3f ms",$1/1000}'`

			if [[ -n "${verbose}" ]]; then
				pure_output+="${status_ok} - NFS Client Perf ${_cliname}: R:${_cli_reads}/s W:${_cli_writes}/s Other:${_cli_others}/s"
				pure_output+=" | BW: R:${_cli_r_bandwidth_h}/s W:${_cli_w_bandwidth_h}/s"
				pure_output+=" | Latency: R:${_cli_lat_rd_ms} W:${_cli_lat_wr_ms}\n"
			fi

			pure_perf+=" client_${_safe_cli}_reads=${_cli_reads}"
			pure_perf+=" client_${_safe_cli}_writes=${_cli_writes}"
			pure_perf+=" client_${_safe_cli}_others=${_cli_others}"
			pure_perf+=" client_${_safe_cli}_read_bandwidth=`_perf_bandwidth "${_cli_r_bandwidth}"`"
			pure_perf+=" client_${_safe_cli}_write_bandwidth=`_perf_bandwidth "${_cli_w_bandwidth}"`"
			pure_perf+=" client_${_safe_cli}_bytes_per_op=${_cli_bytes_op}"
			pure_perf+=" client_${_safe_cli}_bytes_per_read=${_cli_bytes_rd}"
			pure_perf+=" client_${_safe_cli}_bytes_per_write=${_cli_bytes_wr}"
			pure_perf+=" client_${_safe_cli}_lat_read=${_cli_lat_rd}us"
			pure_perf+=" client_${_safe_cli}_lat_write=${_cli_lat_wr}us"
			pure_perf+=" client_${_safe_cli}_lat_other=${_cli_lat_other}us"
		done

		_cli_tot_reads=`echo "${perf_cli_buffer}" | "${JQ}" --unbuffered -r '.total[0].reads_per_sec // 0' 2>/dev/null`
		_cli_tot_writes=`echo "${perf_cli_buffer}" | "${JQ}" --unbuffered -r '.total[0].writes_per_sec // 0' 2>/dev/null`
		_cli_tot_others=`echo "${perf_cli_buffer}" | "${JQ}" --unbuffered -r '.total[0].others_per_sec // 0' 2>/dev/null`
		_cli_tot_r_bandwidth=`echo "${perf_cli_buffer}" | "${JQ}" --unbuffered -r '.total[0].read_bytes_per_sec // 0' 2>/dev/null`
		_cli_tot_w_bandwidth=`echo "${perf_cli_buffer}" | "${JQ}" --unbuffered -r '.total[0].write_bytes_per_sec // 0' 2>/dev/null`
		_cli_tot_bytes_op=`echo "${perf_cli_buffer}" | "${JQ}" --unbuffered -r '.total[0].bytes_per_op // 0' 2>/dev/null`
		_cli_tot_bytes_rd=`echo "${perf_cli_buffer}" | "${JQ}" --unbuffered -r '.total[0].bytes_per_read // 0' 2>/dev/null`
		_cli_tot_bytes_wr=`echo "${perf_cli_buffer}" | "${JQ}" --unbuffered -r '.total[0].bytes_per_write // 0' 2>/dev/null`
		_cli_tot_lat_rd=`echo "${perf_cli_buffer}" | "${JQ}" --unbuffered -r '.total[0].usec_per_read_op // 0' 2>/dev/null`
		_cli_tot_lat_wr=`echo "${perf_cli_buffer}" | "${JQ}" --unbuffered -r '.total[0].usec_per_write_op // 0' 2>/dev/null`
		_cli_tot_lat_other=`echo "${perf_cli_buffer}" | "${JQ}" --unbuffered -r '.total[0].usec_per_other_op // 0' 2>/dev/null`

		pure_perf+=" client_total_reads=${_cli_tot_reads}"
		pure_perf+=" client_total_writes=${_cli_tot_writes}"
		pure_perf+=" client_total_others=${_cli_tot_others}"
		pure_perf+=" client_total_read_bandwidth=`_perf_bandwidth "${_cli_tot_r_bandwidth}"`"
		pure_perf+=" client_total_write_bandwidth=`_perf_bandwidth "${_cli_tot_w_bandwidth}"`"
		pure_perf+=" client_total_bytes_per_op=${_cli_tot_bytes_op}"
		pure_perf+=" client_total_bytes_per_read=${_cli_tot_bytes_rd}"
		pure_perf+=" client_total_bytes_per_write=${_cli_tot_bytes_wr}"
		pure_perf+=" client_total_lat_read=${_cli_tot_lat_rd}us"
		pure_perf+=" client_total_lat_write=${_cli_tot_lat_wr}us"
		pure_perf+=" client_total_lat_other=${_cli_tot_lat_other}us"

		unset cli_name
	fi

	# S3-specific performance (FlashBlade)
	perf_s3_buffer=`${api_cmd_get}/arrays/s3-specific-performance \
		-H "${CURL_OPTS_AUTH}" -H "${CURL_OPTS_JSON}"`

	if [[ -n "${perf_s3_buffer}" && ! "${perf_s3_buffer}" =~ '"errors"' ]]; then
		_s3_cnt=`echo "${perf_s3_buffer}" | "${JQ}" --unbuffered -r '(.items // []) | length' 2>/dev/null`
		if [[ "${_s3_cnt}" -gt 0 ]]; then
			_s3_rd_obj=`echo "${perf_s3_buffer}" | "${JQ}" --unbuffered -r '.items[0].read_objects_per_sec // 0'`
			_s3_wr_obj=`echo "${perf_s3_buffer}" | "${JQ}" --unbuffered -r '.items[0].write_objects_per_sec // 0'`
			_s3_rd_bkt=`echo "${perf_s3_buffer}" | "${JQ}" --unbuffered -r '.items[0].read_buckets_per_sec // 0'`
			_s3_wr_bkt=`echo "${perf_s3_buffer}" | "${JQ}" --unbuffered -r '.items[0].write_buckets_per_sec // 0'`
			_s3_others=`echo "${perf_s3_buffer}" | "${JQ}" --unbuffered -r '.items[0].others_per_sec // 0'`
			_s3_lat_rd_obj=`echo "${perf_s3_buffer}" | "${JQ}" --unbuffered -r '.items[0].usec_per_read_object_op // 0'`
			_s3_lat_wr_obj=`echo "${perf_s3_buffer}" | "${JQ}" --unbuffered -r '.items[0].usec_per_write_object_op // 0'`
			_s3_lat_rd_bkt=`echo "${perf_s3_buffer}" | "${JQ}" --unbuffered -r '.items[0].usec_per_read_bucket_op // 0'`
			_s3_lat_wr_bkt=`echo "${perf_s3_buffer}" | "${JQ}" --unbuffered -r '.items[0].usec_per_write_bucket_op // 0'`
			_s3_lat_other=`echo "${perf_s3_buffer}" | "${JQ}" --unbuffered -r '.items[0].usec_per_other_op // 0'`
			_s3_lat_rd_obj_ms=`echo "${_s3_lat_rd_obj}" | "${AWK}" '{printf "%.3f ms",$1/1000}'`
			_s3_lat_wr_obj_ms=`echo "${_s3_lat_wr_obj}" | "${AWK}" '{printf "%.3f ms",$1/1000}'`
			if [[ -n "${verbose}" ]]; then
				pure_output+="${status_ok} - S3 Perf ${array_name}: ReadObj:${_s3_rd_obj}/s WriteObj:${_s3_wr_obj}/s"
				pure_output+=" | ReadBkt:${_s3_rd_bkt}/s WriteBkt:${_s3_wr_bkt}/s | Other:${_s3_others}/s"
				pure_output+=" | Latency Obj: R:${_s3_lat_rd_obj_ms} W:${_s3_lat_wr_obj_ms}\n"
			fi
			pure_perf+=" ${array_name}_s3_read_objects=${_s3_rd_obj}"
			pure_perf+=" ${array_name}_s3_write_objects=${_s3_wr_obj}"
			pure_perf+=" ${array_name}_s3_read_buckets=${_s3_rd_bkt}"
			pure_perf+=" ${array_name}_s3_write_buckets=${_s3_wr_bkt}"
			pure_perf+=" ${array_name}_s3_others=${_s3_others}"
			pure_perf+=" ${array_name}_s3_lat_read_object=${_s3_lat_rd_obj}us"
			pure_perf+=" ${array_name}_s3_lat_write_object=${_s3_lat_wr_obj}us"
			pure_perf+=" ${array_name}_s3_lat_read_bucket=${_s3_lat_rd_bkt}us"
			pure_perf+=" ${array_name}_s3_lat_write_bucket=${_s3_lat_wr_bkt}us"
			pure_perf+=" ${array_name}_s3_lat_other=${_s3_lat_other}us"
		fi
	fi

	if [[ -n "${verbose}" ]]; then
		pure_output+="---------------------------------------\n\n"
	fi

	unset -f _fmt_bandwidth _perf_bandwidth 2>/dev/null
fi

# ---------------------------------------------------------------------------
# Volumes Check (FlashArray — space + performance + snapshots)
# ---------------------------------------------------------------------------
if [[ ( -n "${enable_vol}" || -n "${enable_all}" ) && -z "${disable_vol}" ]]; then
	vol_space_buffer=`${api_cmd_get}/volumes/space \
		-H "${CURL_OPTS_AUTH}" -H "${CURL_OPTS_JSON}"`
	vol_perf_buffer=`${api_cmd_get}/volumes/performance \
		-H "${CURL_OPTS_AUTH}" -H "${CURL_OPTS_JSON}"`
	if [[ -n "${verbose}" ]]; then
		pure_output+="Volumes:\n---------------------------------------\n"
	fi

	# build blacklist / select maps for per-volume filtering
	declare -A _vol_bl_map _vol_sel_map
	if [[ -n "${vol_blacklist}" ]]; then
		IFS=',' read -ra _vbl_arr <<< "${vol_blacklist}"
		for _vbl_e in "${_vbl_arr[@]}"; do _vol_bl_map["${_vbl_e}"]=1; done
	fi
	if [[ -n "${vol_select}" ]]; then
		IFS=',' read -ra _vsel_arr <<< "${vol_select}"
		for _vsel_e in "${_vsel_arr[@]}"; do _vol_sel_map["${_vsel_e}"]=1; done
	fi

	# --- Space totals ---
	if [[ -n "${vol_space_buffer}" && ! "${vol_space_buffer}" =~ '"errors"' ]]; then
		_vt_provisioned=`echo "${vol_space_buffer}" | "${JQ}" --unbuffered -r '.total[0].space.total_provisioned // 0' 2>/dev/null`
		_vt_physical=`echo "${vol_space_buffer}" | "${JQ}" --unbuffered -r '.total[0].space.total_physical // 0' 2>/dev/null`
		_vt_unique=`echo "${vol_space_buffer}" | "${JQ}" --unbuffered -r '.total[0].space.unique // 0' 2>/dev/null`
		_vt_snapshots=`echo "${vol_space_buffer}" | "${JQ}" --unbuffered -r '.total[0].space.snapshots // 0' 2>/dev/null`
		_vt_dr=`echo "${vol_space_buffer}" | "${JQ}" --unbuffered -r '.total[0].space.data_reduction // 0' 2>/dev/null`
		_vt_count=`echo "${vol_space_buffer}" | "${JQ}" --unbuffered '.items | length' 2>/dev/null`

		_vt_prov_h=`echo "${_vt_provisioned}" | "${AWK}" '{if($1>=1099511627776) printf "%.2f TiB",$1/1099511627776; else if($1>=1073741824) printf "%.2f GiB",$1/1073741824; else if($1>=1048576) printf "%.2f MiB",$1/1048576; else printf "%d B",$1}'`
		_vt_phys_h=`echo "${_vt_physical}" | "${AWK}" '{if($1>=1099511627776) printf "%.2f TiB",$1/1099511627776; else if($1>=1073741824) printf "%.2f GiB",$1/1073741824; else if($1>=1048576) printf "%.2f MiB",$1/1048576; else printf "%d B",$1}'`
		_vt_snap_h=`echo "${_vt_snapshots}" | "${AWK}" '{if($1>=1099511627776) printf "%.2f TiB",$1/1099511627776; else if($1>=1073741824) printf "%.2f GiB",$1/1073741824; else if($1>=1048576) printf "%.2f MiB",$1/1048576; else printf "%d B",$1}'`
		_vt_dr_s=`echo "${_vt_dr}" | "${AWK}" '{printf "%.2f:1",$1}'`
		_vt_pct=`echo "${_vt_physical} ${_vt_provisioned}" | "${AWK}" '{if($2>0) printf "%.1f",$1/$2*100; else print "0"}'`

		_vt_state=`echo "${_vt_pct} ${crit_vol} ${warn_vol}" | "${AWK}" '{if($1+0>=$2+0) print "crit"; else if($1+0>=$3+0) print "warn"; else print "ok"}'`
		case "${_vt_state}" in
		crit)
			pure_output+="${status_crit} - Volumes ${array_name}: ${_vt_count} vol(s) Physical ${_vt_pct}% of Provisioned (${_vt_phys_h}/${_vt_prov_h}) Snapshots: ${_vt_snap_h} DR: ${_vt_dr_s}\n"
			pure_problem_output+="${status_crit} - Volumes ${array_name}: Physical ${_vt_pct}% >= ${crit_vol}%\n"
			;;
		warn)
			pure_output+="${status_warn} - Volumes ${array_name}: ${_vt_count} vol(s) Physical ${_vt_pct}% of Provisioned (${_vt_phys_h}/${_vt_prov_h}) Snapshots: ${_vt_snap_h} DR: ${_vt_dr_s}\n"
			pure_problem_output+="${status_warn} - Volumes ${array_name}: Physical ${_vt_pct}% >= ${warn_vol}%\n"
			;;
		*)
			pure_output+="${status_ok} - Volumes ${array_name}: ${_vt_count} vol(s) Physical: ${_vt_pct}% Provisioned: ${_vt_prov_h} Physical: ${_vt_phys_h} Snapshots: ${_vt_snap_h} DR: ${_vt_dr_s}\n"
			;;
		esac

		pure_perf+=" vol_total=${_vt_count}"
		pure_perf+=" vol_provisioned=${_vt_provisioned}B"
		pure_perf+=" vol_physical=${_vt_physical}B"
		pure_perf+=" vol_unique=${_vt_unique}B"
		pure_perf+=" vol_snapshots=${_vt_snapshots}B"
		pure_perf+=" vol_data_reduction=${_vt_dr_s}"
		pure_perf+=" vol_physical_pct=${_vt_pct};${warn_vol};${crit_vol};0;100"
	fi

	# --- Performance totals ---
	if [[ -n "${vol_perf_buffer}" && ! "${vol_perf_buffer}" =~ '"errors"' ]]; then
		_vp_r_iops=`echo "${vol_perf_buffer}" | "${JQ}" --unbuffered -r '.total[0].reads_per_sec // 0' 2>/dev/null`
		_vp_w_iops=`echo "${vol_perf_buffer}" | "${JQ}" --unbuffered -r '.total[0].writes_per_sec // 0' 2>/dev/null`
		_vp_r_bw=`echo "${vol_perf_buffer}" | "${JQ}" --unbuffered -r '.total[0].read_bytes_per_sec // 0' 2>/dev/null`
		_vp_w_bw=`echo "${vol_perf_buffer}" | "${JQ}" --unbuffered -r '.total[0].write_bytes_per_sec // 0' 2>/dev/null`
		_vp_r_lat=`echo "${vol_perf_buffer}" | "${JQ}" --unbuffered -r '.total[0].usec_per_read_op // 0' 2>/dev/null`
		_vp_w_lat=`echo "${vol_perf_buffer}" | "${JQ}" --unbuffered -r '.total[0].usec_per_write_op // 0' 2>/dev/null`
		_vp_total_iops=`echo "${_vp_r_iops} ${_vp_w_iops}" | "${AWK}" '{print $1+$2}'`

		_vp_r_bw_h=`echo "${_vp_r_bw}" | "${AWK}" '{if($1>=1073741824) printf "%.2f GiB/s",$1/1073741824; else if($1>=1048576) printf "%.2f MiB/s",$1/1048576; else if($1>=1024) printf "%.2f KiB/s",$1/1024; else printf "%d B/s",$1}'`
		_vp_w_bw_h=`echo "${_vp_w_bw}" | "${AWK}" '{if($1>=1073741824) printf "%.2f GiB/s",$1/1073741824; else if($1>=1048576) printf "%.2f MiB/s",$1/1048576; else if($1>=1024) printf "%.2f KiB/s",$1/1024; else printf "%d B/s",$1}'`
		_vp_r_lat_ms=`echo "${_vp_r_lat}" | "${AWK}" '{printf "%.3f ms",$1/1000}'`
		_vp_w_lat_ms=`echo "${_vp_w_lat}" | "${AWK}" '{printf "%.3f ms",$1/1000}'`

		if [[ -n "${verbose}" || -n "${show_perfdata}" ]]; then
			_vp_space_suffix=""
			[[ -n "${_vt_prov_h}" ]] && _vp_space_suffix=" Provisioned: ${_vt_prov_h} Physical: ${_vt_phys_h} Snapshots: ${_vt_snap_h} DR: ${_vt_dr_s}"
			pure_output+="${status_ok} - Volume Perf ${array_name} (total): IOPS: ${_vp_total_iops} (R:${_vp_r_iops} W:${_vp_w_iops}) BW: R:${_vp_r_bw_h} W:${_vp_w_bw_h} Latency: R:${_vp_r_lat_ms} W:${_vp_w_lat_ms}${_vp_space_suffix}\n"
		fi

		pure_perf+=" vol_read_iops=${_vp_r_iops}"
		pure_perf+=" vol_write_iops=${_vp_w_iops}"
		pure_perf+=" vol_total_iops=${_vp_total_iops}"
		pure_perf+=" vol_read_bandwidth=${_vp_r_bw}B"
		pure_perf+=" vol_write_bandwidth=${_vp_w_bw}B"
		pure_perf+=" vol_read_latency=${_vp_r_lat}us"
		pure_perf+=" vol_write_latency=${_vp_w_lat}us"
	fi

	# --- Per-volume (threshold check + optional verbose detail) ---
	# Batch-populate all arrays upfront (one jq call per field, one awk pass per format).
	# The inner loop then does only array lookups — zero subshell spawns per volume.
	if [[ -n "${vol_space_buffer}" && ! "${vol_space_buffer}" =~ '"errors"' ]]; then
		declare -a _pvol_name _pvol_safe _pvol_prov _pvol_phys _pvol_dr _pvol_snap
		declare -a _pvol_prov_h _pvol_phys_h _pvol_snap_h _pvol_dr_s _pvol_pct _pvol_state

		mapfile -t _pvol_name < <(echo "${vol_space_buffer}" | "${JQ}" --unbuffered -r '.items[].name // "unknown"' 2>/dev/null)
		mapfile -t _pvol_safe < <(printf '%s\n' "${_pvol_name[@]}" | sed 's/[.\/: -]/_/g')
		mapfile -t _pvol_prov < <(echo "${vol_space_buffer}" | "${JQ}" --unbuffered -r '.items[].space.total_provisioned // 0' 2>/dev/null)
		mapfile -t _pvol_phys < <(echo "${vol_space_buffer}" | "${JQ}" --unbuffered -r '.items[].space.total_physical // 0' 2>/dev/null)
		mapfile -t _pvol_dr   < <(echo "${vol_space_buffer}" | "${JQ}" --unbuffered -r '.items[].space.data_reduction // 0' 2>/dev/null)
		mapfile -t _pvol_snap < <(echo "${vol_space_buffer}" | "${JQ}" --unbuffered -r '.items[].space.snapshots // 0' 2>/dev/null)

		_size_fmt='{if($1>=1099511627776) printf "%.2f TiB\n",$1/1099511627776; else if($1>=1073741824) printf "%.2f GiB\n",$1/1073741824; else if($1>=1048576) printf "%.2f MiB\n",$1/1048576; else printf "%d B\n",$1}'
		mapfile -t _pvol_prov_h < <(printf '%s\n' "${_pvol_prov[@]}" | "${AWK}" "${_size_fmt}")
		mapfile -t _pvol_phys_h < <(printf '%s\n' "${_pvol_phys[@]}" | "${AWK}" "${_size_fmt}")
		mapfile -t _pvol_snap_h < <(printf '%s\n' "${_pvol_snap[@]}" | "${AWK}" "${_size_fmt}")
		mapfile -t _pvol_dr_s   < <(printf '%s\n' "${_pvol_dr[@]}"   | "${AWK}" '{printf "%.2f:1\n",$1}')
		mapfile -t _pvol_pct    < <(paste <(printf '%s\n' "${_pvol_prov[@]}") <(printf '%s\n' "${_pvol_phys[@]}") \
		                            | "${AWK}" '{if($1>0) printf "%.1f\n",$2/$1*100; else print "0"}')
		mapfile -t _pvol_state  < <(printf '%s\n' "${_pvol_pct[@]}" \
		                            | "${AWK}" -v w="${warn_vol}" -v c="${crit_vol}" \
		                              '{if($1+0>=c+0) print "crit"; else if($1+0>=w+0) print "warn"; else print "ok"}')

		declare -a _pvol_tiops _pvol_riops _pvol_wiops _pvol_rbw_h _pvol_wbw_h _pvol_rlat_ms _pvol_wlat_ms
		_pvol_has_perf=""
		if [[ -n "${vol_perf_buffer}" && ! "${vol_perf_buffer}" =~ '"errors"' ]]; then
			declare -a _pvol_rlat _pvol_wlat
			mapfile -t _pvol_riops  < <(echo "${vol_perf_buffer}" | "${JQ}" --unbuffered -r '.items[].reads_per_sec // 0' 2>/dev/null)
			mapfile -t _pvol_wiops  < <(echo "${vol_perf_buffer}" | "${JQ}" --unbuffered -r '.items[].writes_per_sec // 0' 2>/dev/null)
			mapfile -t _pvol_rbw    < <(echo "${vol_perf_buffer}" | "${JQ}" --unbuffered -r '.items[].read_bytes_per_sec // 0' 2>/dev/null)
			mapfile -t _pvol_wbw    < <(echo "${vol_perf_buffer}" | "${JQ}" --unbuffered -r '.items[].write_bytes_per_sec // 0' 2>/dev/null)
			mapfile -t _pvol_rlat   < <(echo "${vol_perf_buffer}" | "${JQ}" --unbuffered -r '.items[].usec_per_read_op // 0' 2>/dev/null)
			mapfile -t _pvol_wlat   < <(echo "${vol_perf_buffer}" | "${JQ}" --unbuffered -r '.items[].usec_per_write_op // 0' 2>/dev/null)
			mapfile -t _pvol_tiops  < <(paste <(printf '%s\n' "${_pvol_riops[@]}") <(printf '%s\n' "${_pvol_wiops[@]}") \
			                            | "${AWK}" '{print $1+$2}')
			_bw_fmt='{if($1>=1048576) printf "%.2f MiB/s\n",$1/1048576; else if($1>=1024) printf "%.2f KiB/s\n",$1/1024; else printf "%d B/s\n",$1}'
			mapfile -t _pvol_rbw_h  < <(printf '%s\n' "${_pvol_rbw[@]}"  | "${AWK}" "${_bw_fmt}")
			mapfile -t _pvol_wbw_h  < <(printf '%s\n' "${_pvol_wbw[@]}"  | "${AWK}" "${_bw_fmt}")
			mapfile -t _pvol_rlat_ms < <(printf '%s\n' "${_pvol_rlat[@]}" | "${AWK}" '{printf "%.3f ms\n",$1/1000}')
			mapfile -t _pvol_wlat_ms < <(printf '%s\n' "${_pvol_wlat[@]}" | "${AWK}" '{printf "%.3f ms\n",$1/1000}')
			_pvol_has_perf=1
		fi

		for count in "${!_pvol_name[@]}"; do
			_vname="${_pvol_name[count]}"
			[[ -n "${_vol_bl_map[${_vname}]}" ]] && continue
			[[ -n "${vol_select}" && -z "${_vol_sel_map[${_vname}]}" ]] && continue

			_vsafe="${_pvol_safe[count]}"
			_vs_perf_suffix=""
			[[ -n "${_pvol_has_perf}" ]] && \
				_vs_perf_suffix=" IOPS: ${_pvol_tiops[count]} (R:${_pvol_riops[count]} W:${_pvol_wiops[count]}) BW: R:${_pvol_rbw_h[count]} W:${_pvol_wbw_h[count]} Latency: R:${_pvol_rlat_ms[count]} W:${_pvol_wlat_ms[count]}"

			pure_perf+=" vol_${_vsafe}_provisioned=${_pvol_prov[count]}B"
			pure_perf+=" vol_${_vsafe}_physical=${_pvol_phys[count]}B"
			pure_perf+=" vol_${_vsafe}_pct=${_pvol_pct[count]};${warn_vol};${crit_vol};0;100"
			pure_perf+=" vol_${_vsafe}_snapshots=${_pvol_snap[count]}B"
			if [[ -n "${_pvol_has_perf}" ]]; then
				pure_perf+=" vol_${_vsafe}_read_iops=${_pvol_riops[count]}"
				pure_perf+=" vol_${_vsafe}_write_iops=${_pvol_wiops[count]}"
				pure_perf+=" vol_${_vsafe}_total_iops=${_pvol_tiops[count]}"
				pure_perf+=" vol_${_vsafe}_read_bw=${_pvol_rbw[count]}B"
				pure_perf+=" vol_${_vsafe}_write_bw=${_pvol_wbw[count]}B"
				pure_perf+=" vol_${_vsafe}_read_lat=${_pvol_rlat[count]}us"
				pure_perf+=" vol_${_vsafe}_write_lat=${_pvol_wlat[count]}us"
			fi

			case "${_pvol_state[count]}" in
			crit)
				pure_output+="${status_crit} - Volume ${array_name}/${_vname}: Physical ${_pvol_pct[count]}% of Provisioned (${_pvol_phys_h[count]}/${_pvol_prov_h[count]}) Snapshots: ${_pvol_snap_h[count]} DR: ${_pvol_dr_s[count]}${_vs_perf_suffix}\n"
				pure_problem_output+="${status_crit} - Volume ${array_name}/${_vname}: Physical ${_pvol_pct[count]}% >= ${crit_vol}%\n"
				;;
			warn)
				pure_output+="${status_warn} - Volume ${array_name}/${_vname}: Physical ${_pvol_pct[count]}% of Provisioned (${_pvol_phys_h[count]}/${_pvol_prov_h[count]}) Snapshots: ${_pvol_snap_h[count]} DR: ${_pvol_dr_s[count]}${_vs_perf_suffix}\n"
				pure_problem_output+="${status_warn} - Volume ${array_name}/${_vname}: Physical ${_pvol_pct[count]}% >= ${warn_vol}%\n"
				;;
			*)
				if [[ -n "${verbose}" ]]; then
					pure_output+="${status_ok} - Volume ${array_name}/${_vname}: Physical: ${_pvol_pct[count]}% Provisioned: ${_pvol_prov_h[count]} Physical: ${_pvol_phys_h[count]} Snapshots: ${_pvol_snap_h[count]} DR: ${_pvol_dr_s[count]}${_vs_perf_suffix}\n"
				fi
				;;
			esac
		done
		unset _pvol_name _pvol_safe _pvol_prov _pvol_phys _pvol_dr _pvol_snap \
		      _pvol_prov_h _pvol_phys_h _pvol_snap_h _pvol_dr_s _pvol_pct _pvol_state \
		      _pvol_riops _pvol_wiops _pvol_rbw _pvol_wbw _pvol_rlat _pvol_wlat \
		      _pvol_tiops _pvol_rbw_h _pvol_wbw_h _pvol_rlat_ms _pvol_wlat_ms \
		      _vol_bl_map _vol_sel_map
	fi

	if [[ -n "${verbose}" ]]; then
		pure_output+="---------------------------------------\n\n"
	fi
fi

# ---------------------------------------------------------------------------
# Volume Snapshots Check (FlashArray)
# ---------------------------------------------------------------------------
if [[ ( -n "${enable_snaps}" || -n "${enable_all}" ) && -z "${disable_snaps}" ]]; then
	vol_snap_buffer=`${api_cmd_get}/volume-snapshots \
		-H "${CURL_OPTS_AUTH}" -H "${CURL_OPTS_JSON}"`

	if [[ -n "${verbose}" ]]; then
		pure_output+="Volume Snapshots:\n---------------------------------------\n"
	fi

	if [[ -n "${vol_snap_buffer}" && ! "${vol_snap_buffer}" =~ '"errors"' ]]; then
		_size_fmt='{if($1>=1099511627776) printf "%.2f TiB\n",$1/1099511627776; else if($1>=1073741824) printf "%.2f GiB\n",$1/1073741824; else if($1>=1048576) printf "%.2f MiB\n",$1/1048576; else printf "%d B\n",$1}'

		_vsnap_count=`echo "${vol_snap_buffer}" | "${JQ}" --unbuffered '.items | length' 2>/dev/null`
		_vsnap_t_prov=`echo "${vol_snap_buffer}" | "${JQ}" --unbuffered -r '.total[0].space.total_provisioned // 0' 2>/dev/null`
		_vsnap_t_phys=`echo "${vol_snap_buffer}" | "${JQ}" --unbuffered -r '.total[0].space.total_physical // 0' 2>/dev/null`
		_vsnap_t_dr=`echo "${vol_snap_buffer}" | "${JQ}" --unbuffered -r '.total[0].space.data_reduction // 0' 2>/dev/null`
		_vsnap_t_prov_h=`echo "${_vsnap_t_prov}" | "${AWK}" "${_size_fmt}"`
		_vsnap_t_phys_h=`echo "${_vsnap_t_phys}" | "${AWK}" "${_size_fmt}"`
		_vsnap_t_dr_s=`echo "${_vsnap_t_dr}" | "${AWK}" '{printf "%.2f:1",$1}'`

		pure_output+="${status_ok} - Volume Snapshots ${array_name}: ${_vsnap_count} snapshot(s) Provisioned: ${_vsnap_t_prov_h} Physical: ${_vsnap_t_phys_h} DR: ${_vsnap_t_dr_s}\n"
		pure_perf+=" vol_snap_count=${_vsnap_count} vol_snap_provisioned=${_vsnap_t_prov}B vol_snap_physical=${_vsnap_t_phys}B"

		# per-snapshot: batch-populate arrays for both perfdata and verbose output
		declare -a _vsnap_name _vsnap_safe _vsnap_src _vsnap_prov _vsnap_phys _vsnap_dr
		declare -a _vsnap_prov_h _vsnap_phys_h _vsnap_dr_s
		mapfile -t _vsnap_name < <(echo "${vol_snap_buffer}" | "${JQ}" --unbuffered -r '.items[].name // "unknown"' 2>/dev/null)
		mapfile -t _vsnap_src  < <(echo "${vol_snap_buffer}" | "${JQ}" --unbuffered -r '.items[].source.name // "unknown"' 2>/dev/null)
		mapfile -t _vsnap_prov < <(echo "${vol_snap_buffer}" | "${JQ}" --unbuffered -r '.items[].space.total_provisioned // 0' 2>/dev/null)
		mapfile -t _vsnap_phys < <(echo "${vol_snap_buffer}" | "${JQ}" --unbuffered -r '.items[].space.total_physical // 0' 2>/dev/null)
		mapfile -t _vsnap_dr   < <(echo "${vol_snap_buffer}" | "${JQ}" --unbuffered -r '.items[].space.data_reduction // 0' 2>/dev/null)
		mapfile -t _vsnap_safe < <(printf '%s\n' "${_vsnap_name[@]}" | sed 's/[.\/: -]/_/g')
		mapfile -t _vsnap_prov_h < <(printf '%s\n' "${_vsnap_prov[@]}" | "${AWK}" "${_size_fmt}")
		mapfile -t _vsnap_phys_h < <(printf '%s\n' "${_vsnap_phys[@]}" | "${AWK}" "${_size_fmt}")
		mapfile -t _vsnap_dr_s   < <(printf '%s\n' "${_vsnap_dr[@]}"   | "${AWK}" '{printf "%.2f:1\n",$1}')

		for count in "${!_vsnap_name[@]}"; do
			pure_perf+=" snap_${_vsnap_safe[count]}_provisioned=${_vsnap_prov[count]}B"
			pure_perf+=" snap_${_vsnap_safe[count]}_physical=${_vsnap_phys[count]}B"
			pure_perf+=" snap_${_vsnap_safe[count]}_dr=${_vsnap_dr_s[count]}"
			if [[ -n "${verbose}" ]]; then
				pure_output+="${status_ok} - Snapshot ${array_name}/${_vsnap_name[count]} (src: ${_vsnap_src[count]}): Provisioned: ${_vsnap_prov_h[count]} Physical: ${_vsnap_phys_h[count]} DR: ${_vsnap_dr_s[count]}\n"
			fi
		done
		unset _vsnap_name _vsnap_safe _vsnap_src _vsnap_prov _vsnap_phys _vsnap_dr \
		      _vsnap_prov_h _vsnap_phys_h _vsnap_dr_s
	fi

	if [[ -n "${verbose}" ]]; then
		pure_output+="---------------------------------------\n\n"
	fi
	unset vol_snap_buffer
fi

# ---------------------------------------------------------------------------
# Volume Snapshot Transfers Check (FlashArray)
# ---------------------------------------------------------------------------
if [[ ( -n "${enable_snaps_xfer}" || -n "${enable_all}" ) && -z "${disable_snaps_xfer}" ]]; then
	vol_snap_xfer_buffer=`${api_cmd_get}/volume-snapshots/transfer \
		-H "${CURL_OPTS_AUTH}" -H "${CURL_OPTS_JSON}"`

	if [[ -n "${verbose}" ]]; then
		pure_output+="Snapshot Transfers:\n---------------------------------------\n"
	fi

	if [[ -n "${vol_snap_xfer_buffer}" && ! "${vol_snap_xfer_buffer}" =~ '"errors"' ]]; then
		_size_fmt='{if($1>=1099511627776) printf "%.2f TiB\n",$1/1099511627776; else if($1>=1073741824) printf "%.2f GiB\n",$1/1073741824; else if($1>=1048576) printf "%.2f MiB\n",$1/1048576; else printf "%d B\n",$1}'

		_vxfer_count=`echo "${vol_snap_xfer_buffer}" | "${JQ}" --unbuffered '.items | length' 2>/dev/null`
		if [[ "${_vxfer_count:-0}" -gt 0 ]]; then
			_vxfer_dtotal=`echo "${vol_snap_xfer_buffer}" | "${JQ}" --unbuffered -r '.total[0].data_transferred // 0' 2>/dev/null`
			_vxfer_pbwtotal=`echo "${vol_snap_xfer_buffer}" | "${JQ}" --unbuffered -r '.total[0].physical_bytes_written // 0' 2>/dev/null`
			_vxfer_dtotal_h=`echo "${_vxfer_dtotal}" | "${AWK}" "${_size_fmt}"`
			_vxfer_pbwtotal_h=`echo "${_vxfer_pbwtotal}" | "${AWK}" "${_size_fmt}"`

			pure_output+="${status_ok} - Snapshot Transfers ${array_name}: ${_vxfer_count} active Data: ${_vxfer_dtotal_h} Written: ${_vxfer_pbwtotal_h}\n"
			pure_perf+=" vol_snap_transfers=${_vxfer_count} vol_snap_data_transferred=${_vxfer_dtotal}B vol_snap_physical_written=${_vxfer_pbwtotal}B"

			# per-transfer: single jq->awk pipeline (one TSV line per item, guaranteed alignment)
			declare -a _vxfer_name _vxfer_safe _vxfer_prog_pct _vxfer_prog_raw \
			           _vxfer_data_h _vxfer_data_raw _vxfer_pbw_h _vxfer_pbw_raw
			while IFS=$'\t' read -r _tf_name _tf_prog_pct _tf_prog_raw _tf_data_h _tf_data_raw _tf_pbw_h _tf_pbw_raw; do
				_tf_safe="${_tf_name//[.\/: -]/_}"
				_vxfer_name+=("${_tf_name}")
				_vxfer_safe+=("${_tf_safe}")
				_vxfer_prog_pct+=("${_tf_prog_pct}")
				_vxfer_prog_raw+=("${_tf_prog_raw}")
				_vxfer_data_h+=("${_tf_data_h}")
				_vxfer_data_raw+=("${_tf_data_raw}")
				_vxfer_pbw_h+=("${_tf_pbw_h}")
				_vxfer_pbw_raw+=("${_tf_pbw_raw}")
			done < <(echo "${vol_snap_xfer_buffer}" | "${JQ}" --unbuffered -r \
				'.items[] | [(.name // "unknown"), ((.progress // 0)|tostring), ((.data_transferred // 0)|tostring), ((.physical_bytes_written // 0)|tostring)] | join("\t")' 2>/dev/null \
				| "${AWK}" 'BEGIN{FS=OFS="\t"}
				function fmtsz(n) { n+=0; if(n>=1099511627776) return sprintf("%.2f TiB",n/1099511627776); else if(n>=1073741824) return sprintf("%.2f GiB",n/1073741824); else if(n>=1048576) return sprintf("%.2f MiB",n/1048576); else return sprintf("%d B",n) }
				{ print $1, sprintf("%.1f%%",$2*100), $2, fmtsz($3+0), $3, fmtsz($4+0), $4 }')

			for count in "${!_vxfer_name[@]}"; do
				pure_perf+=" xfer_${_vxfer_safe[count]}_progress=${_vxfer_prog_raw[count]};0;1"
				pure_perf+=" xfer_${_vxfer_safe[count]}_data_transferred=${_vxfer_data_raw[count]}B"
				pure_perf+=" xfer_${_vxfer_safe[count]}_physical_written=${_vxfer_pbw_raw[count]}B"
				if [[ -n "${verbose}" ]]; then
					pure_output+="${status_ok} - Transfer ${array_name}/${_vxfer_name[count]}: Progress: ${_vxfer_prog_pct[count]} Transferred: ${_vxfer_data_h[count]} Written: ${_vxfer_pbw_h[count]}\n"
				fi
			done
			unset _vxfer_name _vxfer_safe _vxfer_prog_pct _vxfer_prog_raw \
			      _vxfer_data_h _vxfer_data_raw _vxfer_pbw_h _vxfer_pbw_raw
		elif [[ -n "${verbose}" ]]; then
			pure_output+="${status_ok} - Snapshot Transfers ${array_name}: none active\n"
		fi
	fi

	if [[ -n "${verbose}" ]]; then
		pure_output+="---------------------------------------\n\n"
	fi
	unset vol_snap_xfer_buffer
fi

# ---------------------------------------------------------------------------
# File-System Check (FlashBlade)
# ---------------------------------------------------------------------------
if [[ ( -n "${enable_fs}" || -n "${enable_all}" ) && -z "${disable_fs}" ]]; then
	fs_buffer=`${api_cmd_get}/file-systems \
		-H "${CURL_OPTS_AUTH}" -H "${CURL_OPTS_JSON}"`

	if [[ -n "${verbose}" ]]; then
		pure_output+="File Systems:\n---------------------------------------\n"
	fi

	declare -a fs_name fs_destroyed fs_writable fs_prov fs_virtual fs_phys fs_snap fs_dr

	fs_name=(     `echo "${fs_buffer}" | "${JQ}" --unbuffered -r '(.items // [])[] | .name'                      2>/dev/null | "${AWK}" 1 ORS=' '`)
	fs_destroyed=(`echo "${fs_buffer}" | "${JQ}" --unbuffered -r '(.items // [])[] | .destroyed // false'         2>/dev/null | "${AWK}" 1 ORS=' '`)
	fs_writable=( `echo "${fs_buffer}" | "${JQ}" --unbuffered -r '(.items // [])[] | .writable // true'           2>/dev/null | "${AWK}" 1 ORS=' '`)
	fs_prov=(     `echo "${fs_buffer}" | "${JQ}" --unbuffered -r '(.items // [])[] | .provisioned // 0'           2>/dev/null | "${AWK}" 1 ORS=' '`)
	fs_virtual=(  `echo "${fs_buffer}" | "${JQ}" --unbuffered -r '(.items // [])[] | .space.virtual // 0'         2>/dev/null | "${AWK}" 1 ORS=' '`)
	fs_phys=(     `echo "${fs_buffer}" | "${JQ}" --unbuffered -r '(.items // [])[] | .space.total_physical // 0'  2>/dev/null | "${AWK}" 1 ORS=' '`)
	fs_snap=(     `echo "${fs_buffer}" | "${JQ}" --unbuffered -r '(.items // [])[] | .space.snapshots // 0'       2>/dev/null | "${AWK}" 1 ORS=' '`)
	fs_dr=(       `echo "${fs_buffer}" | "${JQ}" --unbuffered -r '(.items // [])[] | .space.data_reduction // 1'  2>/dev/null | "${AWK}" 1 ORS=' '`)

	_fs_total=0
	_fs_warn=0
	_fs_crit=0

	for count in "${!fs_name[@]}"; do
		_fsname="${fs_name[count]}"
		_safe_fs=`echo "${array_name}_${_fsname}" | tr '.-/ ' '____'`

		if [[ "${fs_destroyed[count]}" == "true" ]]; then
			if [[ -n "${verbose}" ]]; then
				pure_output+="${status_ok} - FS ${array_name}/${_fsname}: DESTROYED (pending removal)\n"
			fi
			continue
		fi

		(( _fs_total++ ))
		_fsprov="${fs_prov[count]}"
		_fsvirt="${fs_virtual[count]}"
		_fsphys="${fs_phys[count]}"
		_fssnap="${fs_snap[count]}"
		_fsdr_s=`echo "${fs_dr[count]}" | "${AWK}" '{printf "%.1f",$1}'`

		_prov_h=`echo "${_fsprov}" | "${AWK}" '{
			if      ($1>=1099511627776) printf "%.2f TiB",$1/1099511627776
			else if ($1>=1073741824)    printf "%.2f GiB",$1/1073741824
			else if ($1>=1048576)       printf "%.2f MiB",$1/1048576
			else                        printf "%d B",$1}'`
		_virt_h=`echo "${_fsvirt}" | "${AWK}" '{
			if      ($1>=1099511627776) printf "%.2f TiB",$1/1099511627776
			else if ($1>=1073741824)    printf "%.2f GiB",$1/1073741824
			else if ($1>=1048576)       printf "%.2f MiB",$1/1048576
			else                        printf "%d B",$1}'`
		_phys_h=`echo "${_fsphys}" | "${AWK}" '{
			if      ($1>=1099511627776) printf "%.2f TiB",$1/1099511627776
			else if ($1>=1073741824)    printf "%.2f GiB",$1/1073741824
			else if ($1>=1048576)       printf "%.2f MiB",$1/1048576
			else                        printf "%d B",$1}'`

		if [[ "${fs_writable[count]}" == "false" ]]; then
			pure_output+="${status_warn} - FS ${array_name}/${_fsname}: NOT WRITABLE | provisioned: ${_prov_h} | physical: ${_phys_h}\n"
			pure_problem_output+="${status_warn} - FS ${array_name}/${_fsname}: NOT WRITABLE\n"
			(( _fs_warn++ ))
		fi

		if [[ "${_fsprov}" -gt 0 ]]; then
			_fs_pct=`echo "${_fsvirt} ${_fsprov}" | "${AWK}" '{printf "%.2f",$1*100/$2}'`
			_fs_pct_int=`echo "${_fs_pct}" | "${AWK}" -F. '{print $1+0}'`
			_warn_b=`echo "${_fsprov} ${warning}"  | "${AWK}" '{printf "%d",$1*$2/100}'`
			_crit_b=`echo "${_fsprov} ${critical}" | "${AWK}" '{printf "%d",$1*$2/100}'`

			if [[ "${_fs_pct_int}" -ge "${critical}" ]]; then
				pure_output+="${status_crit} - FS ${array_name}/${_fsname}: ${_virt_h} of ${_prov_h} used (${_fs_pct}%) | Physical: ${_phys_h} | DR: ${_fsdr_s}:1\n"
				pure_problem_output+="${status_crit} - FS ${array_name}/${_fsname}: ${_virt_h} of ${_prov_h} used (${_fs_pct}%)\n"
				(( _fs_crit++ ))
			elif [[ "${_fs_pct_int}" -ge "${warning}" ]]; then
				pure_output+="${status_warn} - FS ${array_name}/${_fsname}: ${_virt_h} of ${_prov_h} used (${_fs_pct}%) | Physical: ${_phys_h} | DR: ${_fsdr_s}:1\n"
				pure_problem_output+="${status_warn} - FS ${array_name}/${_fsname}: ${_virt_h} of ${_prov_h} used (${_fs_pct}%)\n"
				(( _fs_warn++ ))
			else
				if [[ -n "${verbose}" ]]; then
					pure_output+="${status_ok} - FS ${array_name}/${_fsname}: ${_virt_h} of ${_prov_h} used (${_fs_pct}%) | Physical: ${_phys_h} | DR: ${_fsdr_s}:1\n"
				fi
			fi

			pure_perf+=" fs_${_safe_fs}_virtual=${_fsvirt}B;${_warn_b};${_crit_b};0;${_fsprov}"
			pure_perf+=" fs_${_safe_fs}_pct=${_fs_pct}%;${warning};${critical};0;100"
		else
			if [[ -n "${verbose}" ]]; then
				pure_output+="${status_ok} - FS ${array_name}/${_fsname}: ${_virt_h} used (no quota) | Physical: ${_phys_h} | DR: ${_fsdr_s}:1\n"
			fi
			pure_perf+=" fs_${_safe_fs}_virtual=${_fsvirt}B"
		fi

		pure_perf+=" fs_${_safe_fs}_physical=${_fsphys}B"
		pure_perf+=" fs_${_safe_fs}_snapshots=${_fssnap}B"
		pure_perf+=" fs_${_safe_fs}_provisioned=${_fsprov}B"
		pure_perf+=" fs_${_safe_fs}_writable=`[[ "${fs_writable[count]}" == "true" ]] && echo 1 || echo 0`"
	done

	if [[ "${_fs_total}" -eq 0 && -n "${verbose}" ]]; then
		pure_output+="${status_ok} - File Systems: None found\n"
	elif [[ "${_fs_crit}" -eq 0 && "${_fs_warn}" -eq 0 && -z "${verbose}" ]]; then
		pure_output+="${status_ok} - File Systems: ${_fs_total} filesystem(s) OK\n"
	fi

	pure_perf+=" fs_total=${_fs_total} fs_critical=${_fs_crit} fs_warning=${_fs_warn}"

	if [[ -n "${verbose}" ]]; then
		pure_output+="---------------------------------------\n\n"
	fi

	unset fs_name fs_destroyed fs_writable fs_prov fs_virtual fs_phys fs_snap fs_dr
fi

# ---------------------------------------------------------------------------
# Directory Check (FlashBlade)
# ---------------------------------------------------------------------------
if [[ ( -n "${enable_dirs}" || -n "${enable_all}" ) && -z "${disable_dirs}" ]]; then
	dirs_buffer=`${api_cmd_get}/directories \
		-H "${CURL_OPTS_AUTH}" -H "${CURL_OPTS_JSON}"`

	if [[ -n "${verbose}" ]]; then
		pure_output+="Directories:\n---------------------------------------\n"
	fi

	declare -a di_name di_cap di_used

	di_name=(`echo "${dirs_buffer}" | "${JQ}" --unbuffered -r '.items[].name'                      2>/dev/null | "${AWK}" 1 ORS=' '`)
	di_cap=( `echo "${dirs_buffer}" | "${JQ}" --unbuffered -r '.items[].space.capacity // 0'       2>/dev/null | "${AWK}" 1 ORS=' '`)
	di_used=(`echo "${dirs_buffer}" | "${JQ}" --unbuffered -r '.items[].space.total_physical // 0' 2>/dev/null | "${AWK}" 1 ORS=' '`)

	for count in "${!di_name[@]}"; do
		_cap="${di_cap[count]}"
		_used="${di_used[count]}"
		_safe_di=`echo "${array_name}_${di_name[count]}" | tr '.-/ ' '____'`

		_used_h=`echo "${_used}" | "${AWK}" '{
			if      ($1>=1099511627776) printf "%.2f TiB",$1/1099511627776
			else if ($1>=1073741824)    printf "%.2f GiB",$1/1073741824
			else if ($1>=1048576)       printf "%.2f MiB",$1/1048576
			else                        printf "%d B",$1}'`

		if [[ "${_cap}" == "0" || "${_cap}" == "null" ]]; then
			if [[ -n "${verbose}" ]]; then
				pure_output+="${status_ok} - Directory ${array_name}/${di_name[count]}: ${_used_h} used (no quota)\n"
			fi
			pure_perf+=" dir_${_safe_di}_used=${_used}B"
			continue
		fi

		_pct=`echo "${_used} ${_cap}" | "${AWK}" '{printf "%.2f",$1*100/$2}'`
		_pct_int=`echo "${_pct}" | "${AWK}" -F. '{print $1+0}'`
		_cap_h=`echo "${_cap}" | "${AWK}" '{
			if      ($1>=1099511627776) printf "%.2f TiB",$1/1099511627776
			else if ($1>=1073741824)    printf "%.2f GiB",$1/1073741824
			else if ($1>=1048576)       printf "%.2f MiB",$1/1048576
			else                        printf "%d B",$1}'`
		_warn_b=`echo "${_cap} ${warning}"  | "${AWK}" '{printf "%d",$1*$2/100}'`
		_crit_b=`echo "${_cap} ${critical}" | "${AWK}" '{printf "%d",$1*$2/100}'`

		if [[ "${_pct_int}" -ge "${critical}" ]]; then
			pure_output+="${status_crit} - Directory ${array_name}/${di_name[count]}: ${_used_h} of ${_cap_h} used (${_pct}%)\n"
			pure_problem_output+="${status_crit} - Directory ${array_name}/${di_name[count]}: ${_used_h} of ${_cap_h} used (${_pct}%)\n"
		elif [[ "${_pct_int}" -ge "${warning}" ]]; then
			pure_output+="${status_warn} - Directory ${array_name}/${di_name[count]}: ${_used_h} of ${_cap_h} used (${_pct}%)\n"
			pure_problem_output+="${status_warn} - Directory ${array_name}/${di_name[count]}: ${_used_h} of ${_cap_h} used (${_pct}%)\n"
		else
			pure_output+="${status_ok} - Directory ${array_name}/${di_name[count]}: ${_used_h} of ${_cap_h} used (${_pct}%)\n"
		fi

		pure_perf+=" dir_${_safe_di}_used=${_used}B;${_warn_b};${_crit_b};0;${_cap}"
		pure_perf+=" dir_${_safe_di}_pct=${_pct}%;${warning};${critical};0;100"
	done

	if [[ "${#di_name[@]}" -eq 0 && -n "${verbose}" ]]; then
		pure_output+="${status_ok} - Directories: None found\n"
	fi

	if [[ -n "${verbose}" ]]; then
		pure_output+="---------------------------------------\n\n"
	fi

	unset di_name di_cap di_used
fi

# ---------------------------------------------------------------------------
# Bucket Check (FlashBlade S3)
# ---------------------------------------------------------------------------
if [[ ( -n "${enable_buckets}" || -n "${enable_all}" ) && -z "${disable_buckets}" ]]; then
	buckets_buffer=`${api_cmd_get}/buckets \
		-H "${CURL_OPTS_AUTH}" -H "${CURL_OPTS_JSON}"`

	if [[ -n "${verbose}" ]]; then
		pure_output+="Buckets:\n---------------------------------------\n"
	fi

	declare -a bu_name bu_used bu_obj

	bu_name=(`echo "${buckets_buffer}" | "${JQ}" --unbuffered -r '.items[].name'                       2>/dev/null | "${AWK}" 1 ORS=' '`)
	bu_used=(`echo "${buckets_buffer}" | "${JQ}" --unbuffered -r '.items[].space.total_physical // 0'  2>/dev/null | "${AWK}" 1 ORS=' '`)
	bu_obj=( `echo "${buckets_buffer}" | "${JQ}" --unbuffered -r '.items[].object_count // 0'          2>/dev/null | "${AWK}" 1 ORS=' '`)

	for count in "${!bu_name[@]}"; do
		_used="${bu_used[count]}"
		_obj="${bu_obj[count]}"
		_safe_bu=`echo "${array_name}_${bu_name[count]}" | tr '.-/ ' '____'`

		_used_h=`echo "${_used}" | "${AWK}" '{
			if      ($1>=1099511627776) printf "%.2f TiB",$1/1099511627776
			else if ($1>=1073741824)    printf "%.2f GiB",$1/1073741824
			else if ($1>=1048576)       printf "%.2f MiB",$1/1048576
			else                        printf "%d B",$1}'`

		pure_output+="${status_ok} - Bucket ${array_name}/${bu_name[count]}: ${_used_h} used | Objects: ${_obj}\n"
		pure_perf+=" bucket_${_safe_bu}_used=${_used}B"
		pure_perf+=" bucket_${_safe_bu}_objects=${_obj}c"
	done

	if [[ "${#bu_name[@]}" -eq 0 ]]; then
		pure_output+="${status_ok} - Buckets: None found\n"
	fi

	if [[ -n "${verbose}" ]]; then
		pure_output+="---------------------------------------\n\n"
	fi

	unset bu_name bu_used bu_obj
fi

# ---------------------------------------------------------------------------
# Object Store Account Check (FlashBlade S3)
# ---------------------------------------------------------------------------
if [[ ( -n "${enable_os}" || -n "${enable_all}" ) && -z "${disable_os}" ]]; then
	os_buffer=`${api_cmd_get}/object-store-accounts \
		-H "${CURL_OPTS_AUTH}" -H "${CURL_OPTS_JSON}"`

	if [[ -n "${verbose}" ]]; then
		pure_output+="Object Store Accounts:\n---------------------------------------\n"
	fi

	declare -a os_name os_used os_cap os_obj

	os_name=(`echo "${os_buffer}" | "${JQ}" --unbuffered -r '.items[].name'                       2>/dev/null | "${AWK}" 1 ORS=' '`)
	os_used=(`echo "${os_buffer}" | "${JQ}" --unbuffered -r '.items[].space.total_physical // 0'  2>/dev/null | "${AWK}" 1 ORS=' '`)
	os_cap=( `echo "${os_buffer}" | "${JQ}" --unbuffered -r '.items[].space.capacity // 0'        2>/dev/null | "${AWK}" 1 ORS=' '`)
	os_obj=( `echo "${os_buffer}" | "${JQ}" --unbuffered -r '.items[].object_count // 0'          2>/dev/null | "${AWK}" 1 ORS=' '`)

	for count in "${!os_name[@]}"; do
		_cap="${os_cap[count]}"
		_used="${os_used[count]}"
		_obj="${os_obj[count]}"
		_safe_os=`echo "${array_name}_${os_name[count]}" | tr '.-/ ' '____'`

		_used_h=`echo "${_used}" | "${AWK}" '{
			if      ($1>=1099511627776) printf "%.2f TiB",$1/1099511627776
			else if ($1>=1073741824)    printf "%.2f GiB",$1/1073741824
			else if ($1>=1048576)       printf "%.2f MiB",$1/1048576
			else                        printf "%d B",$1}'`

		if [[ "${_cap}" == "0" || "${_cap}" == "null" ]]; then
			pure_output+="${status_ok} - ObjectStore ${array_name}/${os_name[count]}: ${_used_h} used | Objects: ${_obj}\n"
			pure_perf+=" os_${_safe_os}_used=${_used}B os_${_safe_os}_objects=${_obj}c"
			continue
		fi

		_pct=`echo "${_used} ${_cap}" | "${AWK}" '{printf "%.2f",$1*100/$2}'`
		_pct_int=`echo "${_pct}" | "${AWK}" -F. '{print $1+0}'`
		_cap_h=`echo "${_cap}" | "${AWK}" '{
			if      ($1>=1099511627776) printf "%.2f TiB",$1/1099511627776
			else if ($1>=1073741824)    printf "%.2f GiB",$1/1073741824
			else if ($1>=1048576)       printf "%.2f MiB",$1/1048576
			else                        printf "%d B",$1}'`
		_warn_b=`echo "${_cap} ${warning}"  | "${AWK}" '{printf "%d",$1*$2/100}'`
		_crit_b=`echo "${_cap} ${critical}" | "${AWK}" '{printf "%d",$1*$2/100}'`

		if [[ "${_pct_int}" -ge "${critical}" ]]; then
			pure_output+="${status_crit} - ObjectStore ${array_name}/${os_name[count]}: ${_used_h} of ${_cap_h} (${_pct}%) | Objects: ${_obj}\n"
			pure_problem_output+="${status_crit} - ObjectStore ${array_name}/${os_name[count]}: ${_used_h} of ${_cap_h} (${_pct}%)\n"
		elif [[ "${_pct_int}" -ge "${warning}" ]]; then
			pure_output+="${status_warn} - ObjectStore ${array_name}/${os_name[count]}: ${_used_h} of ${_cap_h} (${_pct}%) | Objects: ${_obj}\n"
			pure_problem_output+="${status_warn} - ObjectStore ${array_name}/${os_name[count]}: ${_used_h} of ${_cap_h} (${_pct}%)\n"
		else
			pure_output+="${status_ok} - ObjectStore ${array_name}/${os_name[count]}: ${_used_h} of ${_cap_h} (${_pct}%) | Objects: ${_obj}\n"
		fi

		pure_perf+=" os_${_safe_os}_used=${_used}B;${_warn_b};${_crit_b};0;${_cap}"
		pure_perf+=" os_${_safe_os}_pct=${_pct}%;${warning};${critical};0;100"
		pure_perf+=" os_${_safe_os}_objects=${_obj}c"
	done

	if [[ "${#os_name[@]}" -eq 0 && -n "${verbose}" ]]; then
		pure_output+="${status_ok} - Object Store: No accounts found\n"
	fi

	if [[ -n "${verbose}" ]]; then
		pure_output+="---------------------------------------\n\n"
	fi

	unset os_name os_used os_cap os_obj
fi

# ---------------------------------------------------------------------------
# Quota Check (FlashBlade user/group directory quotas)
# ---------------------------------------------------------------------------
if [[ ( -n "${enable_quotas}" || -n "${enable_all}" ) && -z "${disable_quotas}" ]]; then
	if [[ -n "${verbose}" ]]; then
		pure_output+="Quotas:\n---------------------------------------\n"
	fi

	_quota_total=0
	_quota_warn=0
	_quota_crit=0

	for _qtype in group user; do
		_qbuf=`${api_cmd_get}/quotas/${_qtype}s \
			-H "${CURL_OPTS_AUTH}" -H "${CURL_OPTS_JSON}"`
		[[ -z "${_qbuf}" || "${_qbuf}" =~ '"errors"' ]] && continue

		declare -a _qname _qlimit _qused _qdir

		_qname=( `echo "${_qbuf}" | "${JQ}" --unbuffered -r '.items[].name // "unknown"'           2>/dev/null | "${AWK}" 1 ORS=' '`)
		_qlimit=(`echo "${_qbuf}" | "${JQ}" --unbuffered -r '.items[].quota_limit // 0'            2>/dev/null | "${AWK}" 1 ORS=' '`)
		_qused=( `echo "${_qbuf}" | "${JQ}" --unbuffered -r '.items[].usage // 0'                  2>/dev/null | "${AWK}" 1 ORS=' '`)
		_qdir=(  `echo "${_qbuf}" | "${JQ}" --unbuffered -r '.items[].directory.name // "unknown"' 2>/dev/null | "${AWK}" 1 ORS=' '`)

		for i in "${!_qname[@]}"; do
			[[ "${_qlimit[i]}" == "0" || "${_qlimit[i]}" == "null" ]] && continue
			(( _quota_total++ ))

			_qpct=`echo "${_qused[i]} ${_qlimit[i]}" | "${AWK}" '{printf "%.2f",$1*100/$2}'`
			_qpct_int=`echo "${_qpct}" | "${AWK}" -F. '{print $1+0}'`
			_safe_q=`echo "${array_name}_${_qdir[i]}_${_qtype}_${_qname[i]}" | tr '.-/ ' '____'`

			_qu_h=`echo "${_qused[i]}" | "${AWK}" '{
				if      ($1>=1099511627776) printf "%.2f TiB",$1/1099511627776
				else if ($1>=1073741824)    printf "%.2f GiB",$1/1073741824
				else if ($1>=1048576)       printf "%.2f MiB",$1/1048576
				else                        printf "%d B",$1}'`
			_ql_h=`echo "${_qlimit[i]}" | "${AWK}" '{
				if      ($1>=1099511627776) printf "%.2f TiB",$1/1099511627776
				else if ($1>=1073741824)    printf "%.2f GiB",$1/1073741824
				else if ($1>=1048576)       printf "%.2f MiB",$1/1048576
				else                        printf "%d B",$1}'`
			_qwarn_b=`echo "${_qlimit[i]} ${warning}"  | "${AWK}" '{printf "%d",$1*$2/100}'`
			_qcrit_b=`echo "${_qlimit[i]} ${critical}" | "${AWK}" '{printf "%d",$1*$2/100}'`

			if [[ "${_qpct_int}" -ge "${critical}" ]]; then
				pure_output+="${status_crit} - Quota ${array_name}/${_qdir[i]} ${_qtype} ${_qname[i]}: ${_qu_h} of ${_ql_h} (${_qpct}%)\n"
				pure_problem_output+="${status_crit} - Quota ${array_name}/${_qdir[i]} ${_qtype} ${_qname[i]}: ${_qu_h} of ${_ql_h} (${_qpct}%)\n"
				(( _quota_crit++ ))
			elif [[ "${_qpct_int}" -ge "${warning}" ]]; then
				pure_output+="${status_warn} - Quota ${array_name}/${_qdir[i]} ${_qtype} ${_qname[i]}: ${_qu_h} of ${_ql_h} (${_qpct}%)\n"
				pure_problem_output+="${status_warn} - Quota ${array_name}/${_qdir[i]} ${_qtype} ${_qname[i]}: ${_qu_h} of ${_ql_h} (${_qpct}%)\n"
				(( _quota_warn++ ))
			else
				if [[ -n "${verbose}" ]]; then
					pure_output+="${status_ok} - Quota ${array_name}/${_qdir[i]} ${_qtype} ${_qname[i]}: ${_qu_h} of ${_ql_h} (${_qpct}%)\n"
				fi
			fi

			pure_perf+=" quota_${_safe_q}_used=${_qused[i]}B;${_qwarn_b};${_qcrit_b};0;${_qlimit[i]}"
			pure_perf+=" quota_${_safe_q}_pct=${_qpct}%;${warning};${critical};0;100"
		done

		unset _qname _qlimit _qused _qdir
	done

	if [[ "${_quota_total}" -eq 0 && -n "${verbose}" ]]; then
		pure_output+="${status_ok} - Quotas: None configured\n"
	elif [[ "${_quota_total}" -gt 0 && "${_quota_crit}" -eq 0 && "${_quota_warn}" -eq 0 ]]; then
		pure_output+="${status_ok} - Quotas: ${_quota_total} quota(s) checked, all within limits\n"
	fi

	pure_perf+=" quotas_total=${_quota_total} quotas_warn=${_quota_warn} quotas_crit=${_quota_crit}"

	if [[ -n "${verbose}" ]]; then
		pure_output+="---------------------------------------\n\n"
	fi
fi

# ---------------------------------------------------------------------------
# Network Interface Check
# ---------------------------------------------------------------------------
if [[ ( -n "${enable_network}" || -n "${enable_all}" ) && -z "${disable_network}" ]]; then
	ni_buffer=`${api_cmd_get}/network-interfaces \
		-H "${CURL_OPTS_AUTH}" -H "${CURL_OPTS_JSON}"`

	if [[ -n "${verbose}" ]]; then
		pure_output+="Network Interfaces:\n---------------------------------------\n"
	fi

	declare -a ni_name ni_enabled ni_speed
	declare -a ni_addr ni_gw ni_hwaddr ni_mtu ni_netmask ni_svcs

	ni_name=(   `echo "${ni_buffer}" | "${JQ}" --unbuffered -r '.items[].name'            2>/dev/null | "${AWK}" 1 ORS=' '`)
	ni_enabled=(`echo "${ni_buffer}" | "${JQ}" --unbuffered -r '.items[].enabled // true' 2>/dev/null | "${AWK}" 1 ORS=' '`)
	ni_speed=(  `echo "${ni_buffer}" | "${JQ}" --unbuffered -r '.items[].speed // 0'      2>/dev/null | "${AWK}" 1 ORS=' '`)
	# use while-read for fields that may be empty string (word-split would drop them and misalign the array)
	while IFS= read -r line; do ni_addr+=(   "${line}"); done < <(echo "${ni_buffer}" | "${JQ}" --unbuffered -r '.items[] | .address  // ""' 2>/dev/null)
	while IFS= read -r line; do ni_gw+=(     "${line}"); done < <(echo "${ni_buffer}" | "${JQ}" --unbuffered -r '.items[] | .gateway  // ""' 2>/dev/null)
	while IFS= read -r line; do ni_hwaddr+=( "${line}"); done < <(echo "${ni_buffer}" | "${JQ}" --unbuffered -r '.items[] | .hwaddr   // ""' 2>/dev/null)
	while IFS= read -r line; do ni_mtu+=(    "${line}"); done < <(echo "${ni_buffer}" | "${JQ}" --unbuffered -r '.items[] | .mtu      // ""' 2>/dev/null)
	while IFS= read -r line; do ni_netmask+=("${line}"); done < <(echo "${ni_buffer}" | "${JQ}" --unbuffered -r '.items[] | .netmask  // ""' 2>/dev/null)
	while IFS= read -r line; do ni_svcs+=(   "${line}"); done < <(echo "${ni_buffer}" | "${JQ}" --unbuffered -r '.items[] | [.services // [] | .[]] | join(",")' 2>/dev/null)

	# build blacklist lookup from --blacklist-nics "eth88,eth89"
	declare -A _ni_bl_map
	if [[ -n "${ni_blacklist}" ]]; then
		IFS=',' read -ra _ni_bl_arr <<< "${ni_blacklist}"
		for _bl in "${_ni_bl_arr[@]}"; do
			_ni_bl_map["${_bl}"]=1
		done
	fi

	_ni_total=0
	_ni_enabled_cnt=0
	_ni_disabled_cnt=0
	_ni_blacklisted_cnt=0

	for count in "${!ni_name[@]}"; do
		_niname="${ni_name[count]}"

		if [[ -n "${_ni_bl_map[${_niname}]}" ]]; then
			(( _ni_blacklisted_cnt++ ))
			continue
		fi

		(( _ni_total++ ))
		_spd_h=`echo "${ni_speed[count]}" | "${AWK}" '{if($1>0) printf "%.0f Gbit/s",$1/1000000000; else print "n/a"}'`
		_safe_ni=`echo "${array_name}_${_niname}" | tr '.-/ ' '____'`

		_ni_detail=""
		if [[ -n "${verbose}" ]]; then
			[[ -n "${ni_svcs[count]}"    ]] && _ni_detail+=" | services: ${ni_svcs[count]}"
			[[ -n "${ni_addr[count]}"    ]] && _ni_detail+=" | addr: ${ni_addr[count]}"
			[[ -n "${ni_gw[count]}"      ]] && _ni_detail+=" | gw: ${ni_gw[count]}"
			[[ -n "${ni_netmask[count]}" ]] && _ni_detail+=" | mask: ${ni_netmask[count]}"
			[[ -n "${ni_mtu[count]}"     ]] && _ni_detail+=" | mtu: ${ni_mtu[count]}"
			[[ -n "${ni_hwaddr[count]}"  ]] && _ni_detail+=" | hw: ${ni_hwaddr[count]}"
		fi

		if [[ "${ni_enabled[count]}" == "true" ]]; then
			(( _ni_enabled_cnt++ ))
			if [[ -n "${verbose}" ]]; then
				pure_output+="${status_ok} - NI ${array_name}: ${_niname} | ${_spd_h}${_ni_detail}\n"
			fi
		else
			(( _ni_disabled_cnt++ ))
			if [[ -n "${verbose}" ]]; then
				pure_output+="${status_ok} - NI ${array_name}: ${_niname} DISABLED | ${_spd_h}${_ni_detail}\n"
			fi
		fi

	done

	if [[ "${_ni_total}" -gt 0 && -z "${verbose}" ]]; then
		_ni_bl_s=""
		[[ "${_ni_blacklisted_cnt}" -gt 0 ]] && _ni_bl_s=", ${_ni_blacklisted_cnt} blacklisted"
		pure_output+="${status_ok} - Network: ${_ni_enabled_cnt}/${_ni_total} interfaces enabled (${_ni_disabled_cnt} disabled${_ni_bl_s})\n"
	fi

	pure_perf+=" ni_total=${_ni_total} ni_enabled=${_ni_enabled_cnt} ni_disabled=${_ni_disabled_cnt}"

	if [[ -n "${verbose}" ]]; then
		pure_output+="---------------------------------------\n\n"
	fi

	unset ni_name ni_enabled ni_speed ni_addr ni_gw ni_hwaddr ni_mtu ni_netmask ni_svcs _ni_bl_map

	# Ports (FC / iSCSI / NVMe-oF) — verbose detail only
	ports_buffer=`${api_cmd_get}/ports \
		-H "${CURL_OPTS_AUTH}" -H "${CURL_OPTS_JSON}"`

	declare -a pt_name pt_wwn pt_iqn pt_nqn pt_portal pt_failover

	pt_name=(    `echo "${ports_buffer}" | "${JQ}" --unbuffered -r '.items[].name'              2>/dev/null | "${AWK}" 1 ORS=' '`)
	pt_wwn=(     `echo "${ports_buffer}" | "${JQ}" --unbuffered -r '.items[].wwn // ""'         2>/dev/null | "${AWK}" 1 ORS=' '`)
	pt_iqn=(     `echo "${ports_buffer}" | "${JQ}" --unbuffered -r '.items[].iqn // ""'         2>/dev/null | "${AWK}" 1 ORS=' '`)
	pt_nqn=(     `echo "${ports_buffer}" | "${JQ}" --unbuffered -r '.items[].nqn // ""'         2>/dev/null | "${AWK}" 1 ORS=' '`)
	pt_portal=(  `echo "${ports_buffer}" | "${JQ}" --unbuffered -r '.items[].portal // ""'      2>/dev/null | "${AWK}" 1 ORS=' '`)
	pt_failover=(`echo "${ports_buffer}" | "${JQ}" --unbuffered -r '.items[].failover // ""'    2>/dev/null | "${AWK}" 1 ORS=' '`)

	_pt_total="${#pt_name[@]}"

	if [[ "${_pt_total}" -gt 0 ]]; then
		if [[ -n "${verbose}" ]]; then
			pure_output+="Ports:\n---------------------------------------\n"
			for count in "${!pt_name[@]}"; do
				_pt_id=""
				_pt_type=""
				if [[ -n "${pt_wwn[count]}" ]]; then
					_pt_type="FC"
					_pt_id=" | WWN: ${pt_wwn[count]}"
				elif [[ -n "${pt_iqn[count]}" ]]; then
					_pt_type="iSCSI"
					_pt_id=" | IQN: ${pt_iqn[count]}"
					[[ -n "${pt_portal[count]}" ]] && _pt_id+=" | portal: ${pt_portal[count]}"
				elif [[ -n "${pt_nqn[count]}" ]]; then
					_pt_type="NVMe"
					_pt_id=" | NQN: ${pt_nqn[count]}"
					[[ -n "${pt_portal[count]}" ]] && _pt_id+=" | portal: ${pt_portal[count]}"
				fi
				_pt_fo=""
				[[ -n "${pt_failover[count]}" ]] && _pt_fo=" | failover: ${pt_failover[count]}"
				pure_output+="${status_ok} - Port ${array_name}: ${pt_name[count]} (${_pt_type:-unknown})${_pt_id}${_pt_fo}\n"
			done
			pure_output+="---------------------------------------\n\n"
		else
			pure_output+="${status_ok} - Ports: ${_pt_total} port(s) found\n"
		fi

		pure_perf+=" ports_total=${_pt_total}"
	fi

	unset pt_name pt_wwn pt_iqn pt_nqn pt_portal pt_failover
fi

# ---------------------------------------------------------------------------
# Network Interface Performance Check
# ---------------------------------------------------------------------------
if [[ ( -n "${enable_ni_perf}" || -n "${enable_all}" ) && -z "${disable_ni_perf}" ]]; then
	ni_perf_buffer=`${api_cmd_get}/network-interfaces/performance \
		-H "${CURL_OPTS_AUTH}" -H "${CURL_OPTS_JSON}"`
	# Fetch interface config for line speed
	ni_speed_buffer=`${api_cmd_get}/network-interfaces \
		-H "${CURL_OPTS_AUTH}" -H "${CURL_OPTS_JSON}"`

	if [[ -n "${verbose}" ]]; then
		pure_output+="Network Interface Performance:\n---------------------------------------\n"
	fi

	if [[ -n "${ni_perf_buffer}" && ! "${ni_perf_buffer}" =~ '"errors"' ]]; then
		_niperf_total=`echo "${ni_perf_buffer}" | "${JQ}" --unbuffered '.items | length' 2>/dev/null`

		if [[ "${_niperf_total:-0}" -gt 0 ]]; then
			# Build blacklist map
			declare -A _nip_bl_map
			if [[ -n "${ni_blacklist}" ]]; then
				IFS=',' read -ra _nip_bl_arr <<< "${ni_blacklist}"
				for _nip_bl_e in "${_nip_bl_arr[@]}"; do _nip_bl_map["${_nip_bl_e}"]=1; done
			fi

			# Build speed lookup map: name -> speed in bits/sec
			declare -A _nip_speed_map
			while IFS=$'\t' read -r _ns_name _ns_speed; do
				_nip_speed_map["${_ns_name}"]="${_ns_speed}"
			done < <(echo "${ni_speed_buffer}" | "${JQ}" --unbuffered -r '
				.items[] | [
					(.name // ""),
					((.speed // 0) | tostring)
				] | join("\t")' 2>/dev/null)

			declare -a _nip_name _nip_safe _nip_type _nip_rxb _nip_txb _nip_rxp _nip_txp _nip_err

			while IFS=$'\t' read -r _nf_name _nf_type _nf_rxb _nf_txb _nf_rxp _nf_txp _nf_err; do
				_nip_name+=("${_nf_name}")
				_nip_safe+=("${_nf_name//[.\/: -]/_}")
				_nip_type+=("${_nf_type}")
				_nip_rxb+=("${_nf_rxb}")
				_nip_txb+=("${_nf_txb}")
				_nip_rxp+=("${_nf_rxp}")
				_nip_txp+=("${_nf_txp}")
				_nip_err+=("${_nf_err}")
			done < <(echo "${ni_perf_buffer}" | "${JQ}" --unbuffered -r '
				.items[] | [
					(.name // "unknown"),
					(.interface_type // "eth"),
					(if .interface_type == "fc"
						then (.fc.received_bytes_per_sec // 0)
						else (.eth.received_bytes_per_sec // 0) end | tostring),
					(if .interface_type == "fc"
						then (.fc.transmitted_bytes_per_sec // 0)
						else (.eth.transmitted_bytes_per_sec // 0) end | tostring),
					(if .interface_type == "fc"
						then (.fc.received_frames_per_sec // 0)
						else (.eth.received_packets_per_sec // 0) end | tostring),
					(if .interface_type == "fc"
						then (.fc.transmitted_frames_per_sec // 0)
						else (.eth.transmitted_packets_per_sec // 0) end | tostring),
					(if .interface_type == "fc"
						then (.fc.total_errors_per_sec // 0)
						else (.eth.total_errors_per_sec // 0) end | tostring)
				] | join("\t")' 2>/dev/null)

			_nip_warn=0
			_nip_crit=0

			for count in "${!_nip_name[@]}"; do
				_nipn="${_nip_name[count]}"
				[[ -n "${_nip_bl_map[${_nipn}]}" ]] && continue

				_nip_spd="${_nip_speed_map[${_nipn}]:-0}"  # bits/sec from config
				_nip_rxb_v="${_nip_rxb[count]}"
				_nip_txb_v="${_nip_txb[count]}"

				# Human-readable bandwidth
				_nip_rxb_h=`_fmt_bandwidth "${_nip_rxb_v}"`
				_nip_txb_h=`_fmt_bandwidth "${_nip_txb_v}"`

				# Line speed display and utilisation calculation
				_nip_spd_h=""
				_nip_rx_pct=0
				_nip_tx_pct=0
				_nip_rx_warn_b=0
				_nip_rx_crit_b=0
				_nip_tx_warn_b=0
				_nip_tx_crit_b=0
				_nip_max_b=0

				if [[ "${_nip_spd}" -gt 0 ]] 2>/dev/null; then
					# speed is in bits/sec; convert to bytes/sec for comparison
					_nip_max_b=$(( _nip_spd / 8 ))
					_nip_rx_pct=`echo "${_nip_rxb_v} ${_nip_max_b}" | "${AWK}" '{if($2>0) printf "%d",$1*100/$2; else print 0}'`
					_nip_tx_pct=`echo "${_nip_txb_v} ${_nip_max_b}" | "${AWK}" '{if($2>0) printf "%d",$1*100/$2; else print 0}'`
					_nip_rx_warn_b=`echo "${_nip_max_b} ${warn_ni_bw}" | "${AWK}" '{printf "%d",$1*$2/100}'`
					_nip_rx_crit_b=`echo "${_nip_max_b} ${crit_ni_bw}" | "${AWK}" '{printf "%d",$1*$2/100}'`
					_nip_tx_warn_b="${_nip_rx_warn_b}"
					_nip_tx_crit_b="${_nip_rx_crit_b}"
					_nip_spd_h=`echo "${_nip_spd}" | "${AWK}" '{if($1>=1000000000) printf "%.0f Gbit/s",$1/1000000000; else if($1>=1000000) printf "%.0f Mbit/s",$1/1000000; else printf "%d bit/s",$1}'`
				fi

				# Perfdata with thresholds and max
				pure_perf+=" ni_${_nip_safe[count]}_rx_bps=${_nip_rxb_v}B;${_nip_rx_warn_b};${_nip_rx_crit_b};0;${_nip_max_b}"
				pure_perf+=" ni_${_nip_safe[count]}_tx_bps=${_nip_txb_v}B;${_nip_tx_warn_b};${_nip_tx_crit_b};0;${_nip_max_b}"
				pure_perf+=" ni_${_nip_safe[count]}_errors_per_sec=${_nip_err[count]};${warn_ni_errors};${crit_ni_errors}"

				# Threshold evaluation — bandwidth utilisation
				_nip_state="${status_ok}"
				_nip_dir=""
				if [[ "${_nip_spd}" -gt 0 ]] 2>/dev/null; then
					if (( _nip_rx_pct >= crit_ni_bw || _nip_tx_pct >= crit_ni_bw )) 2>/dev/null; then
						_nip_state="${status_crit}"
						[[ "${_nip_rx_pct}" -ge "${crit_ni_bw}" ]] && _nip_dir+=" RX:${_nip_rx_pct}%"
						[[ "${_nip_tx_pct}" -ge "${crit_ni_bw}" ]] && _nip_dir+=" TX:${_nip_tx_pct}%"
						pure_problem_output+="${status_crit} - NI Perf ${array_name}/${_nipn}: utilisation CRITICAL${_nip_dir} (threshold: ${crit_ni_bw}%)\n"
						(( _nip_crit++ ))
					elif (( _nip_rx_pct >= warn_ni_bw || _nip_tx_pct >= warn_ni_bw )) 2>/dev/null; then
						_nip_state="${status_warn}"
						[[ "${_nip_rx_pct}" -ge "${warn_ni_bw}" ]] && _nip_dir+=" RX:${_nip_rx_pct}%"
						[[ "${_nip_tx_pct}" -ge "${warn_ni_bw}" ]] && _nip_dir+=" TX:${_nip_tx_pct}%"
						pure_problem_output+="${status_warn} - NI Perf ${array_name}/${_nipn}: utilisation WARNING${_nip_dir} (threshold: ${warn_ni_bw}%)\n"
						(( _nip_warn++ ))
					fi
				fi

				# Threshold evaluation — errors/sec
				_nip_err_v="${_nip_err[count]}"
				if "${AWK}" "BEGIN{exit !(${_nip_err_v}+0 >= ${crit_ni_errors}+0)}" 2>/dev/null; then
					_nip_state="${status_crit}"
					pure_problem_output+="${status_crit} - NI Perf ${array_name}/${_nipn}: ${_nip_err_v} errors/s CRITICAL (threshold: ${crit_ni_errors})\n"
					(( _nip_crit++ ))
				elif "${AWK}" "BEGIN{exit !(${_nip_err_v}+0 >= ${warn_ni_errors}+0)}" 2>/dev/null; then
					[[ "${_nip_state}" != "${status_crit}" ]] && _nip_state="${status_warn}"
					pure_problem_output+="${status_warn} - NI Perf ${array_name}/${_nipn}: ${_nip_err_v} errors/s WARNING (threshold: ${warn_ni_errors})\n"
					(( _nip_warn++ ))
				fi

				# Per-interface output line
				_nip_spd_s=""
				[[ -n "${_nip_spd_h}" ]] && _nip_spd_s=" | Speed: ${_nip_spd_h}"
				_nip_util_s=""
				[[ "${_nip_spd}" -gt 0 ]] 2>/dev/null && _nip_util_s=" | RX: ${_nip_rx_pct}% TX: ${_nip_tx_pct}%"

				if [[ "${_nip_state}" != "${status_ok}" ]]; then
					pure_output+="${_nip_state} - NI Perf ${array_name}/${_nipn} (${_nip_type[count]})${_nip_spd_s}: RX: ${_nip_rxb_h}/s TX: ${_nip_txb_h}/s${_nip_util_s} | Pkts: ${_nip_rxp[count]}/${_nip_txp[count]}/s Err: ${_nip_err[count]}/s\n"
				elif [[ -n "${verbose}" ]]; then
					pure_output+="${status_ok} - NI Perf ${array_name}/${_nipn} (${_nip_type[count]})${_nip_spd_s}: RX: ${_nip_rxb_h}/s TX: ${_nip_txb_h}/s${_nip_util_s} | Pkts: ${_nip_rxp[count]}/${_nip_txp[count]}/s Err: ${_nip_err[count]}/s\n"
				fi
			done

			if [[ -z "${verbose}" && "${_nip_crit}" -eq 0 && "${_nip_warn}" -eq 0 ]]; then
				pure_output+="${status_ok} - NI Performance ${array_name}: ${_niperf_total} interfaces within thresholds (warn: ${warn_ni_bw}% crit: ${crit_ni_bw}%)\n"
			fi

			unset _nip_name _nip_safe _nip_type _nip_rxb _nip_txb _nip_rxp _nip_txp \
			      _nip_err _nip_bl_map _nip_speed_map
		fi
	fi

	if [[ -n "${verbose}" ]]; then
		pure_output+="---------------------------------------\n\n"
	fi

	unset ni_perf_buffer ni_speed_buffer
fi

# ---------------------------------------------------------------------------
# Network Interface Port Details Check
# ---------------------------------------------------------------------------
if [[ ( -n "${enable_ni_port}" || -n "${enable_all}" ) && -z "${disable_ni_port}" ]]; then
	ni_port_buffer=`${api_cmd_get}/network-interfaces/port-details \
		-H "${CURL_OPTS_AUTH}" -H "${CURL_OPTS_JSON}"`

	if [[ -n "${verbose}" ]]; then
		pure_output+="Network Interface Port Details:\n---------------------------------------\n"
	fi

	if [[ -n "${ni_port_buffer}" && ! "${ni_port_buffer}" =~ '"errors"' ]]; then
		_niport_total=`echo "${ni_port_buffer}" | "${JQ}" --unbuffered '.items | length' 2>/dev/null`

		if [[ "${_niport_total:-0}" -gt 0 ]]; then
			declare -A _nipo_bl_map
			if [[ -n "${ni_blacklist}" ]]; then
				IFS=',' read -ra _nipo_bl_arr <<< "${ni_blacklist}"
				for _nipo_bl_e in "${_nipo_bl_arr[@]}"; do _nipo_bl_map["${_nipo_bl_e}"]=1; done
			fi

			declare -a _nipo_name _nipo_type _nipo_status _nipo_txfault \
			           _nipo_rxpwr _nipo_txpwr _nipo_temp _nipo_vendor

			while IFS=$'\t' read -r _np_name _np_type _np_status _np_txfault \
			                         _np_rxpwr _np_txpwr _np_temp _np_vendor; do
				_nipo_name+=("${_np_name}")
				_nipo_type+=("${_np_type}")
				_nipo_status+=("${_np_status}")
				_nipo_txfault+=("${_np_txfault}")
				_nipo_rxpwr+=("${_np_rxpwr}")
				_nipo_txpwr+=("${_np_txpwr}")
				_nipo_temp+=("${_np_temp}")
				_nipo_vendor+=("${_np_vendor}")
			done < <(echo "${ni_port_buffer}" | "${JQ}" --unbuffered -r '
				.items[] | [
					(.name // "unknown"),
					(.interface_type // ""),
					([ (.rx_power // [])[], (.tx_power // [])[],
					   (.temperature // [])[], (.tx_bias // [])[], (.voltage // [])[]] |
					  map(.status) | map(if . == "alarm" then 2 elif . == "warn" then 1 else 0 end) |
					  max // 0 |
					  if . == 2 then "alarm" elif . == 1 then "warn" else "ok" end),
					(([(.tx_fault // [])[] | .flag] | any) | tostring),
					((.rx_power // []) | if length > 0 then .[0].measurement else 0 end | tostring),
					((.tx_power // []) | if length > 0 then .[0].measurement else 0 end | tostring),
					((.temperature // []) | if length > 0 then .[0].measurement else 0 end | tostring),
					(.static.vendor_name // "")
				] | join("\t")' 2>/dev/null)

			_niport_warn=0
			_niport_crit=0

			for count in "${!_nipo_name[@]}"; do
				_nipon="${_nipo_name[count]}"
				[[ -n "${_nipo_bl_map[${_nipon}]}" ]] && continue

				_niport_detail=""
				[[ -n "${_nipo_vendor[count]}" ]] && _niport_detail+=" | vendor: ${_nipo_vendor[count]}"
				[[ -n "${_nipo_type[count]}"   ]] && _niport_detail+=" | type: ${_nipo_type[count]}"
				_niport_detail+=" | rx_pwr: ${_nipo_rxpwr[count]} dBm | tx_pwr: ${_nipo_txpwr[count]} dBm | temp: ${_nipo_temp[count]}°C"

				if [[ "${_nipo_txfault[count]}" == "true" ]]; then
					pure_output+="${status_crit} - Port ${array_name}/${_nipon}: TX FAULT${_niport_detail}\n"
					pure_problem_output+="${status_crit} - Port ${array_name}/${_nipon}: TX FAULT\n"
					(( _niport_crit++ ))
				elif [[ "${_nipo_status[count]}" == "alarm" ]]; then
					pure_output+="${status_crit} - Port ${array_name}/${_nipon}: optical alarm${_niport_detail}\n"
					pure_problem_output+="${status_crit} - Port ${array_name}/${_nipon}: optical alarm\n"
					(( _niport_crit++ ))
				elif [[ "${_nipo_status[count]}" == "warn" ]]; then
					pure_output+="${status_warn} - Port ${array_name}/${_nipon}: optical warning${_niport_detail}\n"
					pure_problem_output+="${status_warn} - Port ${array_name}/${_nipon}: optical warning\n"
					(( _niport_warn++ ))
				elif [[ -n "${verbose}" ]]; then
					pure_output+="${status_ok} - Port ${array_name}/${_nipon}: optical OK${_niport_detail}\n"
				fi
			done

			if [[ "${_niport_crit}" -eq 0 && "${_niport_warn}" -eq 0 && -z "${verbose}" ]]; then
				pure_output+="${status_ok} - NI Port Details ${array_name}: ${_niport_total} ports OK\n"
			fi

			pure_perf+=" ni_port_total=${_niport_total} ni_port_warn=${_niport_warn} ni_port_crit=${_niport_crit}"

			unset _nipo_name _nipo_type _nipo_status _nipo_txfault \
			      _nipo_rxpwr _nipo_txpwr _nipo_temp _nipo_vendor _nipo_bl_map
		fi
	fi

	if [[ -n "${verbose}" ]]; then
		pure_output+="---------------------------------------\n\n"
	fi

	unset ni_port_buffer
fi

# ---------------------------------------------------------------------------
# Network Interface Neighbors (LLDP) Check
# ---------------------------------------------------------------------------
if [[ ( -n "${enable_ni_nbr}" || -n "${enable_all}" ) && -z "${disable_ni_nbr}" ]]; then
	ni_nbr_buffer=`${api_cmd_get}/network-interfaces/neighbors \
		-H "${CURL_OPTS_AUTH}" -H "${CURL_OPTS_JSON}"`

	if [[ -n "${verbose}" ]]; then
		pure_output+="Network Interface Neighbors (LLDP):\n---------------------------------------\n"
	fi

	if [[ -n "${ni_nbr_buffer}" && ! "${ni_nbr_buffer}" =~ '"errors"' ]]; then
		_ninbr_total=`echo "${ni_nbr_buffer}" | "${JQ}" --unbuffered '.items | length' 2>/dev/null`

		if [[ "${_ninbr_total:-0}" -gt 0 ]]; then
			declare -a _ninbr_local _ninbr_chassis _ninbr_desc _ninbr_port

			while IFS=$'\t' read -r _nb_local _nb_chassis _nb_desc _nb_port; do
				_ninbr_local+=("${_nb_local}")
				_ninbr_chassis+=("${_nb_chassis}")
				_ninbr_desc+=("${_nb_desc}")
				_ninbr_port+=("${_nb_port}")
			done < <(echo "${ni_nbr_buffer}" | "${JQ}" --unbuffered -r '
				.items[] | [
					(.local_port.name // ""),
					(.neighbor_chassis.name // ""),
					(.neighbor_chassis.description // ""),
					(.neighbor_port.id.value // "")
				] | join("\t")' 2>/dev/null)

			if [[ -n "${verbose}" ]]; then
				for count in "${!_ninbr_local[@]}"; do
					_nb_detail=""
					[[ -n "${_ninbr_desc[count]}" ]] && _nb_detail+=" | ${_ninbr_desc[count]}"
					pure_output+="${status_ok} - Neighbor ${array_name}/${_ninbr_local[count]}: ${_ninbr_chassis[count]} port ${_ninbr_port[count]}${_nb_detail}\n"
				done
			else
				pure_output+="${status_ok} - NI Neighbors ${array_name}: ${_ninbr_total} neighbor(s) discovered\n"
			fi

			pure_perf+=" ni_neighbors=${_ninbr_total}"

			unset _ninbr_local _ninbr_chassis _ninbr_desc _ninbr_port
		else
			if [[ -n "${verbose}" ]]; then
				pure_output+="${status_ok} - NI Neighbors ${array_name}: none discovered\n"
			fi
		fi
	fi

	if [[ -n "${verbose}" ]]; then
		pure_output+="---------------------------------------\n\n"
	fi

	unset ni_nbr_buffer
fi

# ---------------------------------------------------------------------------
# Offloads Check
# ---------------------------------------------------------------------------
if [[ ( -n "${enable_off}" || -n "${enable_all}" ) && -z "${disable_off}" ]]; then
	off_buffer=`${api_cmd_get}/offloads \
		-H "${CURL_OPTS_AUTH}" -H "${CURL_OPTS_JSON}"`

	if [[ -n "${verbose}" ]]; then
		pure_output+="Offloads:\n---------------------------------------\n"
	fi

	# null/empty/error -> OK (offloads are optional)
	if [[ -z "${off_buffer}" || "${off_buffer}" =~ '"errors"' || "${off_buffer}" == "null" ]]; then
		if [[ -n "${verbose}" ]]; then
			pure_output+="${status_ok} - Offloads ${array_name}: none configured\n"
		fi
	else
		_off_total=`echo "${off_buffer}" | "${JQ}" --unbuffered '.items | length' 2>/dev/null`

		if [[ "${_off_total:-0}" -eq 0 ]]; then
			if [[ -n "${verbose}" ]]; then
				pure_output+="${status_ok} - Offloads ${array_name}: none configured\n"
			fi
		else
			declare -a _off_name _off_safe _off_proto _off_status _off_state \
			           _off_phys _off_prov _off_foot _off_dr _off_target \
			           _off_phys_h _off_prov_h _off_foot_h

			while IFS=$'\t' read -r _of_name _of_proto _of_status _of_state \
			                         _of_phys _of_prov _of_foot _of_dr \
			                         _of_phys_h _of_prov_h _of_foot_h _of_target; do
				_off_name+=("${_of_name}")
				_off_safe+=("${_of_name//[.\/: -]/_}")
				_off_proto+=("${_of_proto}")
				_off_status+=("${_of_status}")
				_off_state+=("${_of_state}")
				_off_phys+=("${_of_phys}")
				_off_prov+=("${_of_prov}")
				_off_foot+=("${_of_foot}")
				_off_dr+=("${_of_dr}")
				_off_phys_h+=("${_of_phys_h}")
				_off_prov_h+=("${_of_prov_h}")
				_off_foot_h+=("${_of_foot_h}")
				_off_target+=("${_of_target}")
			done < <(echo "${off_buffer}" | "${JQ}" --unbuffered -r '
				.items[] | [
					(.name // "unknown"),
					(.protocol // ""),
					(.status // ""),
					(if   .status == "connected"     then "ok"
					 elif .status == "scanning"      then "ok"
					 elif .status == "connecting"    then "warn"
					 elif .status == "disconnecting" then "warn"
					 elif .status == "not connected" then "crit"
					 else "ok" end),
					((.space.total_physical  // 0) | tostring),
					((.space.total_provisioned // 0) | tostring),
					((.space.footprint        // 0) | tostring),
					((.space.data_reduction   // 0) | tostring),
					"", "", "", ""
				] | join("\t")' 2>/dev/null \
				| "${AWK}" 'BEGIN{FS=OFS="\t"}
				function fmtsz(n) { n+=0; if(n>=1099511627776) return sprintf("%.2f TiB",n/1099511627776); else if(n>=1073741824) return sprintf("%.2f GiB",n/1073741824); else if(n>=1048576) return sprintf("%.2f MiB",n/1048576); else return sprintf("%d B",n) }
				{ $9=fmtsz($5+0); $10=fmtsz($6+0); $11=fmtsz($7+0); print }')

			# Second pass: extract protocol-specific target detail (can't easily do it in above pipeline due to hyphen key)
			declare -a _off_target_raw
			while IFS=$'\t' read -r _of_t_name _of_t_detail; do
				_off_target_raw+=("${_of_t_detail}")
			done < <(echo "${off_buffer}" | "${JQ}" --unbuffered -r '
				.items[] | [
					(.name // "unknown"),
					(if   .protocol == "nfs"          then ((.nfs.address // "") + ":" + (.nfs.mount_point // ""))
					 elif .protocol == "s3"           then ((.s3.uri // "") + " bucket:" + (.s3.bucket // ""))
					 elif .protocol == "azure"        then ((.azure.account_name // "") + "/" + (.azure.container_name // ""))
					 elif .protocol == "google-cloud" then (.["google-cloud"].bucket // "")
					 else "" end)
				] | join("\t")' 2>/dev/null)

			_off_warn=0
			_off_crit=0
			_off_ok=0

			for count in "${!_off_name[@]}"; do
				_ofn="${_off_name[count]}"
				_ofsafe="${_off_safe[count]}"
				_ofstate="${_off_state[count]}"
				_ofst="${_off_status[count]}"

				pure_perf+=" offload_${_ofsafe}_physical=${_off_phys[count]}B"
				pure_perf+=" offload_${_ofsafe}_provisioned=${_off_prov[count]}B"
				pure_perf+=" offload_${_ofsafe}_footprint=${_off_foot[count]}B"

				_off_detail=" | protocol: ${_off_proto[count]}"
				[[ -n "${_off_target_raw[count]}" ]] && _off_detail+=" | target: ${_off_target_raw[count]}"
				_off_detail+=" | physical: ${_off_phys_h[count]} provisioned: ${_off_prov_h[count]} footprint: ${_off_foot_h[count]}"

				case "${_ofstate}" in
				crit)
					pure_output+="${status_crit} - Offload ${array_name}/${_ofn}: ${_ofst}${_off_detail}\n"
					pure_problem_output+="${status_crit} - Offload ${array_name}/${_ofn}: ${_ofst}\n"
					(( _off_crit++ ))
					;;
				warn)
					pure_output+="${status_warn} - Offload ${array_name}/${_ofn}: ${_ofst}${_off_detail}\n"
					pure_problem_output+="${status_warn} - Offload ${array_name}/${_ofn}: ${_ofst}\n"
					(( _off_warn++ ))
					;;
				*)
					(( _off_ok++ ))
					if [[ -n "${verbose}" ]]; then
						pure_output+="${status_ok} - Offload ${array_name}/${_ofn}: ${_ofst}${_off_detail}\n"
					fi
					;;
				esac
			done

			if [[ "${_off_crit}" -eq 0 && "${_off_warn}" -eq 0 && -z "${verbose}" ]]; then
				pure_output+="${status_ok} - Offloads ${array_name}: ${_off_total} target(s) connected\n"
			fi

			pure_perf+=" offload_total=${_off_total} offload_ok=${_off_ok} offload_warn=${_off_warn} offload_crit=${_off_crit}"

			unset _off_name _off_safe _off_proto _off_status _off_state \
			      _off_phys _off_prov _off_foot _off_dr _off_target _off_target_raw \
			      _off_phys_h _off_prov_h _off_foot_h
		fi
	fi

	if [[ -n "${verbose}" ]]; then
		pure_output+="---------------------------------------\n\n"
	fi

	unset off_buffer
fi

# ---------------------------------------------------------------------------
# Software Patches Check
# ---------------------------------------------------------------------------
if [[ ( -n "${enable_patch}" || -n "${enable_all}" ) && -z "${disable_patch}" ]]; then
	patch_buffer=`${api_cmd_get}/software-patches/catalog \
		-H "${CURL_OPTS_AUTH}" -H "${CURL_OPTS_JSON}"`

	if [[ -n "${verbose}" ]]; then
		pure_output+="Software Patches:\n---------------------------------------\n"
	fi

	if [[ -z "${patch_buffer}" || "${patch_buffer}" =~ '"errors"' || "${patch_buffer}" == "null" ]]; then
		if [[ -n "${verbose}" ]]; then
			pure_output+="${status_ok} - Software Patches ${array_name}: none available\n"
		fi
	else
		_patch_total=`echo "${patch_buffer}" | "${JQ}" --unbuffered '.items | length' 2>/dev/null`

		if [[ "${_patch_total:-0}" -eq 0 ]]; then
			if [[ -n "${verbose}" ]]; then
				pure_output+="${status_ok} - Software Patches ${array_name}: none available\n"
			fi
		else
			declare -a _pat_name _pat_ver _pat_status _pat_state _pat_desc _pat_pct _pat_ha _pat_hops

			while IFS=$'\t' read -r _pn _pv _ps _pst _pd _pp _pha _ph; do
				_pat_name+=("${_pn}")
				_pat_ver+=("${_pv}")
				_pat_status+=("${_ps}")
				_pat_state+=("${_pst}")
				_pat_desc+=("${_pd}")
				_pat_pct+=("${_pp}")
				_pat_ha+=("${_pha}")
				_pat_hops+=("${_ph}")
			done < <(echo "${patch_buffer}" | "${JQ}" --unbuffered -r '
				.items[] | (.status // "") as $s | [
					(.name // "unknown"),
					(.version // ""),
					$s,
					(if   $s == "installed"       then "ok"
					 elif $s == "not_applicable"  then "ok"
					 elif $s == "download_failed" then "crit"
					 elif $s == "failed"          then "crit"
					 else "warn" end),
					(.description // ""),
					((.progress // 0) * 100 | floor | tostring),
					((.ha_reduction_required // false) | tostring),
					((.upgrade_hops // []) | join(" -> "))
				] | join("\t")' 2>/dev/null)

			_patch_warn=0
			_patch_crit=0
			_patch_ok=0

			for count in "${!_pat_name[@]}"; do
				_pname="${_pat_name[count]}"
				_pstate="${_pat_state[count]}"
				_pst="${_pat_status[count]}"

				_pat_detail=""
				[[ -n "${_pat_ver[count]}" ]] && _pat_detail+=" v${_pat_ver[count]}"
				_pat_detail+=" | ${_pst}"
				[[ "${_pat_pct[count]}" != "0" ]] && _pat_detail+=" ${_pat_pct[count]}%"
				[[ -n "${_pat_desc[count]}" ]] && _pat_detail+=" | ${_pat_desc[count]}"
				[[ "${_pat_ha[count]}" == "true" ]] && _pat_detail+=" | HA reduction required"
				# Only show upgrade path when patch is available (not already installed)
				[[ "${_pstate}" != "ok" && -n "${_pat_hops[count]}" ]] && \
					_pat_detail+=" | path: ${_pat_hops[count]}"

				case "${_pstate}" in
				crit)
					pure_output+="${status_crit} - Patch ${array_name}/${_pname}:${_pat_detail}\n"
					pure_problem_output+="${status_crit} - Patch ${array_name}/${_pname}: ${_pst}\n"
					(( _patch_crit++ ))
					;;
				warn)
					pure_output+="${status_warn} - Patch ${array_name}/${_pname}:${_pat_detail}\n"
					pure_problem_output+="${status_warn} - Patch ${array_name}/${_pname}: ${_pst}\n"
					(( _patch_warn++ ))
					;;
				*)
					(( _patch_ok++ ))
					if [[ -n "${verbose}" ]]; then
						pure_output+="${status_ok} - Patch ${array_name}/${_pname}:${_pat_detail}\n"
					fi
					;;
				esac
			done

			if [[ "${_patch_crit}" -eq 0 && "${_patch_warn}" -eq 0 && -z "${verbose}" ]]; then
				pure_output+="${status_ok} - Software Patches ${array_name}: ${_patch_ok}/${_patch_total} installed\n"
			fi

			pure_perf+=" patch_total=${_patch_total} patch_ok=${_patch_ok} patch_warn=${_patch_warn} patch_crit=${_patch_crit}"

			unset _pat_name _pat_ver _pat_status _pat_state _pat_desc _pat_pct _pat_ha _pat_hops
		fi
	fi

	if [[ -n "${verbose}" ]]; then
		pure_output+="---------------------------------------\n\n"
	fi

	unset patch_buffer
fi

# ---------------------------------------------------------------------------
# Software / Upgrade Check
# ---------------------------------------------------------------------------
if [[ ( -n "${enable_sw}" || -n "${enable_all}" ) && -z "${disable_sw}" ]]; then
	sw_buffer=`${api_cmd_get}/software \
		-H "${CURL_OPTS_AUTH}" -H "${CURL_OPTS_JSON}"`

	if [[ -n "${verbose}" ]]; then
		pure_output+="Software / Upgrades:\n---------------------------------------\n"
	fi

	if [[ -z "${sw_buffer}" || "${sw_buffer}" =~ '"errors"' || "${sw_buffer}" == "null" ]]; then
		if [[ -n "${verbose}" ]]; then
			pure_output+="${status_ok} - Software ${array_name}: no upgrade activity\n"
		fi
	else
		_sw_total=`echo "${sw_buffer}" | "${JQ}" --unbuffered '.items | length' 2>/dev/null`

		if [[ "${_sw_total:-0}" -eq 0 ]]; then
			if [[ -n "${verbose}" ]]; then
				pure_output+="${status_ok} - Software ${array_name}: no upgrade activity\n"
			fi
		else
			declare -a _sw_name _sw_ver _sw_status _sw_state _sw_pct _sw_hops

			while IFS=$'\t' read -r _swn _swv _sws _swst _swp _swh; do
				_sw_name+=("${_swn}")
				_sw_ver+=("${_swv}")
				_sw_status+=("${_sws}")
				_sw_state+=("${_swst}")
				_sw_pct+=("${_swp}")
				_sw_hops+=("${_swh}")
			done < <(echo "${sw_buffer}" | "${JQ}" --unbuffered -r '
				.items[] | (.status // "" | ascii_downcase) as $s | [
					(.name // "unknown"),
					(.version // ""),
					$s,
					(if   $s == "installed"          then "ok"
					 elif $s == "new"                then "ok"
					 elif $s == "download_failed"    then "crit"
					 elif $s == "failed"             then "crit"
					 elif $s == "aborting"           then "crit"
					 elif $s == "abort"              then "crit"
					 elif $s == "canceled"           then "crit"
					 elif $s == "partially_installed" then "crit"
					 else "warn" end),
					((.progress // 0) * 100 | floor | tostring),
					((.upgrade_hops // []) | join(" -> "))
				] | join("\t")' 2>/dev/null)

			_sw_warn=0
			_sw_crit=0
			_sw_ok=0

			for count in "${!_sw_name[@]}"; do
				_swname="${_sw_name[count]}"
				_swstate="${_sw_state[count]}"
				_swst="${_sw_status[count]}"

				_sw_detail=" v${_sw_ver[count]} | ${_swst}"
				[[ "${_sw_pct[count]}" != "0" ]] && _sw_detail+=" ${_sw_pct[count]}%"
				# Only show upgrade path when not already at target version
				[[ "${_swstate}" != "ok" && -n "${_sw_hops[count]}" ]] && \
					_sw_detail+=" | path: ${_sw_hops[count]}"

				case "${_swstate}" in
				crit)
					pure_output+="${status_crit} - Software ${array_name}/${_swname}:${_sw_detail}\n"
					pure_problem_output+="${status_crit} - Software ${array_name}/${_swname}: ${_swst}\n"
					(( _sw_crit++ ))
					;;
				warn)
					pure_output+="${status_warn} - Software ${array_name}/${_swname}:${_sw_detail}\n"
					pure_problem_output+="${status_warn} - Software ${array_name}/${_swname}: ${_swst}\n"
					(( _sw_warn++ ))
					;;
				*)
					(( _sw_ok++ ))
					if [[ -n "${verbose}" ]]; then
						pure_output+="${status_ok} - Software ${array_name}/${_swname}:${_sw_detail}\n"
					fi
					;;
				esac
			done

			if [[ "${_sw_crit}" -eq 0 && "${_sw_warn}" -eq 0 && -z "${verbose}" ]]; then
				pure_output+="${status_ok} - Software ${array_name}: ${_sw_ok}/${_sw_total} item(s) OK\n"
			fi

			pure_perf+=" sw_total=${_sw_total} sw_ok=${_sw_ok} sw_warn=${_sw_warn} sw_crit=${_sw_crit}"

			unset _sw_name _sw_ver _sw_status _sw_state _sw_pct _sw_hops
		fi
	fi

	# Verbose: show latest software pre-check results
	if [[ -n "${verbose}" ]]; then
		swchk_buffer=`${api_cmd_get}/software-check \
			-H "${CURL_OPTS_AUTH}" -H "${CURL_OPTS_JSON}"`

		if [[ -n "${swchk_buffer}" && ! "${swchk_buffer}" =~ '"errors"' && "${swchk_buffer}" != "null" ]]; then
			_swchk_total=`echo "${swchk_buffer}" | "${JQ}" --unbuffered '.items | length' 2>/dev/null`
			if [[ "${_swchk_total:-0}" -gt 0 ]]; then
				pure_output+="Software Pre-checks:\n"
				while IFS=$'\t' read -r _sc_swname _sc_swver _sc_status _sc_checks; do
					pure_output+="${status_ok} - SW Check ${array_name}/${_sc_swname} v${_sc_swver}: ${_sc_status}"
					[[ -n "${_sc_checks}" ]] && pure_output+=" | ${_sc_checks}"
					pure_output+="\n"
				done < <(echo "${swchk_buffer}" | "${JQ}" --unbuffered -r '
					.items[] | [
						(.software_name // .name // ""),
						(.software_version // ""),
						(.status // ""),
						((.checks // []) | map(.name + ":" + .status) | join(", "))
					] | join("\t")' 2>/dev/null)
			fi
		fi
		unset swchk_buffer

		pure_output+="---------------------------------------\n\n"
	fi

	unset sw_buffer
fi

# ---------------------------------------------------------------------------
# DNS Check
# ---------------------------------------------------------------------------
if [[ ( -n "${enable_dns}" || -n "${enable_all}" ) && -z "${disable_dns}" ]]; then
	dns_buffer=`${api_cmd_get}/dns \
		-H "${CURL_OPTS_AUTH}" -H "${CURL_OPTS_JSON}"`

	if [[ -n "${verbose}" ]]; then
		pure_output+="DNS:\n---------------------------------------\n"
	fi

	declare -a dns_name dns_domain dns_ns

	dns_name=(  `echo "${dns_buffer}" | "${JQ}" --unbuffered -r '(.items // [])[] | .name'          2>/dev/null | "${AWK}" 1 ORS=' '`)
	dns_domain=(`echo "${dns_buffer}" | "${JQ}" --unbuffered -r '(.items // [])[] | .domain // ""'  2>/dev/null | "${AWK}" 1 ORS=' '`)
	while IFS= read -r line; do dns_ns+=("${line}"); done < \
		<(echo "${dns_buffer}" | "${JQ}" --unbuffered -r '(.items // [])[] | (.nameservers // []) | join(",")' 2>/dev/null)

	_dns_total=0
	_dns_warn=0

	for count in "${!dns_name[@]}"; do
		(( _dns_total++ ))
		_dname="${dns_name[count]}"
		_ddomain="${dns_domain[count]}"
		_dns_configured="${dns_ns[count]}"

		if [[ -n "${check_dns}" ]]; then
			_dns_ok=0
			if [[ -n "${dns_strict}" ]]; then
				[[ "${_dns_configured}" == "${check_dns}" ]] && _dns_ok=1
			else
				_servers_subset "${check_dns}" "${_dns_configured}" && _dns_ok=1
			fi
			if [[ "${_dns_ok}" -eq 1 ]]; then
				if [[ -n "${verbose}" ]]; then
					pure_output+="${status_ok} - DNS ${array_name}/${_dname}: nameservers OK (${_dns_configured}) | domain: ${_ddomain}\n"
				fi
			else
				_dns_mode_s=""
				[[ -n "${dns_strict}" ]] && _dns_mode_s=" (strict)"
				pure_output+="${status_warn} - DNS ${array_name}/${_dname}: nameserver mismatch${_dns_mode_s} — expected: ${check_dns} | configured: ${_dns_configured:-none} | domain: ${_ddomain}\n"
				pure_problem_output+="${status_warn} - DNS ${array_name}/${_dname}: nameserver mismatch${_dns_mode_s} — expected: ${check_dns} | configured: ${_dns_configured:-none}\n"
				(( _dns_warn++ ))
			fi
		else
			pure_output+="${status_ok} - DNS ${array_name}/${_dname}: nameservers: ${_dns_configured:-none} | domain: ${_ddomain}\n"
		fi
	done

	if [[ "${_dns_total}" -eq 0 ]]; then
		pure_output+="${status_ok} - DNS: No DNS configuration found\n"
	elif [[ -n "${check_dns}" && "${_dns_warn}" -eq 0 && -z "${verbose}" ]]; then
		pure_output+="${status_ok} - DNS: ${_dns_total} config(s) nameservers OK\n"
	fi

	if [[ -n "${verbose}" ]]; then
		pure_output+="---------------------------------------\n\n"
	fi

	unset dns_name dns_domain dns_ns
fi

# ---------------------------------------------------------------------------
# Syslog Servers Check
# ---------------------------------------------------------------------------
if [[ ( -n "${enable_syslog}" || -n "${enable_all}" ) && -z "${disable_syslog}" ]]; then
	syslog_buffer=`${api_cmd_get}/syslog-servers \
		-H "${CURL_OPTS_AUTH}" -H "${CURL_OPTS_JSON}"`

	if [[ -n "${verbose}" ]]; then
		pure_output+="Syslog Servers:\n---------------------------------------\n"
	fi

	declare -a syslog_name syslog_uri syslog_svcs

	while IFS= read -r line; do syslog_name+=("${line}"); done < \
		<(echo "${syslog_buffer}" | "${JQ}" --unbuffered -r '(.items // [])[] | .name // ""' 2>/dev/null)
	while IFS= read -r line; do syslog_uri+=(  "${line}"); done < \
		<(echo "${syslog_buffer}" | "${JQ}" --unbuffered -r '(.items // [])[] | .uri  // ""' 2>/dev/null)
	while IFS= read -r line; do syslog_svcs+=( "${line}"); done < \
		<(echo "${syslog_buffer}" | "${JQ}" --unbuffered -r '(.items // [])[] | (.services // []) | join(",")' 2>/dev/null)

	_syslog_total="${#syslog_name[@]}"
	_syslog_warn=0

	# Build comma-separated list of all configured URIs for subset/strict comparison
	_syslog_configured_uris=$(IFS=','; echo "${syslog_uri[*]}")

	if [[ "${_syslog_total}" -eq 0 ]]; then
		if [[ -n "${check_syslog}" ]]; then
			pure_output+="${status_warn} - Syslog ${array_name}: no syslog servers configured — expected: ${check_syslog}\n"
			pure_problem_output+="${status_warn} - Syslog ${array_name}: no syslog servers configured — expected: ${check_syslog}\n"
			(( _syslog_warn++ ))
		else
			pure_output+="${status_ok} - Syslog ${array_name}: no syslog servers configured\n"
		fi
	else
		if [[ -n "${check_syslog}" ]]; then
			_syslog_ok=0
			if [[ -n "${syslog_strict}" ]]; then
				[[ "${_syslog_configured_uris}" == "${check_syslog}" ]] && _syslog_ok=1
			else
				_servers_subset "${check_syslog}" "${_syslog_configured_uris}" && _syslog_ok=1
			fi
			if [[ "${_syslog_ok}" -eq 1 ]]; then
				if [[ -n "${verbose}" ]]; then
					for count in "${!syslog_name[@]}"; do
						_sl_svc=""
						[[ -n "${syslog_svcs[count]}" ]] && _sl_svc=" | services: ${syslog_svcs[count]}"
						pure_output+="${status_ok} - Syslog ${array_name}/${syslog_name[count]}: ${syslog_uri[count]}${_sl_svc}\n"
					done
				fi
			else
				_syslog_mode_s=""
				[[ -n "${syslog_strict}" ]] && _syslog_mode_s=" (strict)"
				pure_output+="${status_warn} - Syslog ${array_name}: URI mismatch${_syslog_mode_s} — expected: ${check_syslog} | configured: ${_syslog_configured_uris:-none}\n"
				pure_problem_output+="${status_warn} - Syslog ${array_name}: URI mismatch${_syslog_mode_s} — expected: ${check_syslog} | configured: ${_syslog_configured_uris:-none}\n"
				(( _syslog_warn++ ))
			fi
		else
			for count in "${!syslog_name[@]}"; do
				_sl_svc=""
				[[ -n "${syslog_svcs[count]}" ]] && _sl_svc=" | services: ${syslog_svcs[count]}"
				pure_output+="${status_ok} - Syslog ${array_name}/${syslog_name[count]}: ${syslog_uri[count]}${_sl_svc}\n"
			done
		fi
	fi

	if [[ -n "${check_syslog}" && "${_syslog_warn}" -eq 0 && "${_syslog_total}" -gt 0 && -z "${verbose}" ]]; then
		pure_output+="${status_ok} - Syslog ${array_name}: ${_syslog_total} server(s) URI OK\n"
	fi

	pure_perf+=" syslog_total=${_syslog_total}"

	if [[ -n "${verbose}" ]]; then
		pure_output+="---------------------------------------\n\n"
	fi

	unset syslog_name syslog_uri syslog_svcs
fi

# ---------------------------------------------------------------------------
# Replication Check (pods, array connections, pod replica links)
# ---------------------------------------------------------------------------
if [[ ( -n "${enable_repl}" || -n "${enable_all}" ) && -z "${disable_repl}" ]]; then
	pods_buffer=`${api_cmd_get}/pods \
		-H "${CURL_OPTS_AUTH}" -H "${CURL_OPTS_JSON}"`
	conn_buffer=`${api_cmd_get}/array-connections \
		-H "${CURL_OPTS_AUTH}" -H "${CURL_OPTS_JSON}"`
	rlink_buffer=`${api_cmd_get}/pod-replica-links \
		-H "${CURL_OPTS_AUTH}" -H "${CURL_OPTS_JSON}"`

	if [[ -n "${verbose}" ]]; then
		pure_output+="Replication:\n---------------------------------------\n"
	fi

	# --- Pods (ActiveCluster) ---
	declare -a pod_name pod_status pod_med

	pod_name=(  `echo "${pods_buffer}" | "${JQ}" --unbuffered -r '.items[].name'                         2>/dev/null | "${AWK}" 1 ORS=' '`)
	pod_status=(`echo "${pods_buffer}" | "${JQ}" --unbuffered -r '.items[].status // "healthy"'          2>/dev/null | "${AWK}" 1 ORS=' '`)
	pod_med=(   `echo "${pods_buffer}" | "${JQ}" --unbuffered -r '.items[].mediator_status // "unknown"' 2>/dev/null | "${AWK}" 1 ORS=' '`)

	_pod_total=0
	_pod_unhealthy=0

	for count in "${!pod_name[@]}"; do
		(( _pod_total++ ))
		_pstatus="${pod_status[count]}"
		_pmed="${pod_med[count]}"
		_safe_pod=`echo "${array_name}_${pod_name[count]}" | tr '.-/ ' '____'`

		if [[ "${_pstatus}" == "unhealthy" || "${_pstatus}" == "unreachable" ]]; then
			pure_output+="${status_crit} - Pod ${array_name}/${pod_name[count]}: ${_pstatus^^}\n"
			pure_problem_output+="${status_crit} - Pod ${array_name}/${pod_name[count]}: ${_pstatus^^}\n"
			(( _pod_unhealthy++ ))
		elif [[ "${_pstatus}" == "recovering" || "${_pstatus}" == "suspended" ]]; then
			pure_output+="${status_warn} - Pod ${array_name}/${pod_name[count]}: ${_pstatus^^}\n"
			pure_problem_output+="${status_warn} - Pod ${array_name}/${pod_name[count]}: ${_pstatus^^}\n"
			(( _pod_unhealthy++ ))
		else
			if [[ "${_pmed}" == "disconnected" ]]; then
				pure_output+="${status_warn} - Pod ${array_name}/${pod_name[count]}: mediator DISCONNECTED\n"
				pure_problem_output+="${status_warn} - Pod ${array_name}/${pod_name[count]}: mediator DISCONNECTED\n"
			elif [[ -n "${verbose}" ]]; then
				pure_output+="${status_ok} - Pod ${array_name}/${pod_name[count]}: ${_pstatus} | mediator: ${_pmed}\n"
			fi
		fi

		pure_perf+=" pod_${_safe_pod}_healthy=`[[ "${_pstatus}" == "healthy" ]] && echo 1 || echo 0`"
		pure_perf+=" pod_${_safe_pod}_mediator=`[[ "${_pmed}" == "connected" ]] && echo 1 || echo 0`"
	done

	if [[ "${_pod_total}" -gt 0 && "${_pod_unhealthy}" -eq 0 && -z "${verbose}" ]]; then
		pure_output+="${status_ok} - Pods: ${_pod_total} pod(s) healthy\n"
	fi

	pure_perf+=" pods_total=${_pod_total} pods_unhealthy=${_pod_unhealthy}"
	unset pod_name pod_status pod_med

	# --- Array connections ---
	declare -a ac_remote ac_status ac_type ac_transport

	ac_remote=(   `echo "${conn_buffer}" | "${JQ}" --unbuffered -r '.items[].remote.name // .items[].id // "unknown"' 2>/dev/null | "${AWK}" 1 ORS=' '`)
	ac_status=(   `echo "${conn_buffer}" | "${JQ}" --unbuffered -r '.items[].status // "connected"'                   2>/dev/null | "${AWK}" 1 ORS=' '`)
	ac_type=(     `echo "${conn_buffer}" | "${JQ}" --unbuffered -r '.items[].type // "unknown"'                       2>/dev/null | "${AWK}" 1 ORS=' '`)
	ac_transport=(`echo "${conn_buffer}" | "${JQ}" --unbuffered -r '.items[].replication_transport // "ip"'           2>/dev/null | "${AWK}" 1 ORS=' '`)

	_ac_total=0
	_ac_down=0

	for count in "${!ac_remote[@]}"; do
		(( _ac_total++ ))
		_acst="${ac_status[count]}"
		_safe_ac=`echo "${array_name}_${ac_remote[count]}" | tr '.-/ ' '____'`

		if [[ "${_acst}" == "disconnected" ]]; then
			pure_output+="${status_crit} - Replication ${array_name} -> ${ac_remote[count]} (${ac_type[count]}/${ac_transport[count]}): DISCONNECTED\n"
			pure_problem_output+="${status_crit} - Replication ${array_name} -> ${ac_remote[count]}: DISCONNECTED\n"
			(( _ac_down++ ))
		elif [[ "${_acst}" == "connecting" ]]; then
			pure_output+="${status_warn} - Replication ${array_name} -> ${ac_remote[count]} (${ac_type[count]}/${ac_transport[count]}): CONNECTING\n"
			pure_problem_output+="${status_warn} - Replication ${array_name} -> ${ac_remote[count]}: CONNECTING\n"
			(( _ac_down++ ))
		else
			if [[ -n "${verbose}" ]]; then
				pure_output+="${status_ok} - Replication ${array_name} -> ${ac_remote[count]} (${ac_type[count]}/${ac_transport[count]}): ${_acst}\n"
			fi
		fi

		pure_perf+=" repl_${_safe_ac}_up=`[[ "${_acst}" == "connected" ]] && echo 1 || echo 0`"
	done

	if [[ "${_ac_total}" -gt 0 && "${_ac_down}" -eq 0 && -z "${verbose}" ]]; then
		pure_output+="${status_ok} - Array connections: ${_ac_total} connection(s) up\n"
	fi

	pure_perf+=" repl_connections_total=${_ac_total} repl_connections_down=${_ac_down}"
	unset ac_remote ac_status ac_type ac_transport

	# --- Pod replica links ---
	if [[ -n "${rlink_buffer}" && ! "${rlink_buffer}" =~ '"errors"' ]]; then
		declare -a rl_src rl_dst rl_status rl_lag rl_paused

		while IFS= read -r line; do rl_src+=(   "${line}"); done < <(echo "${rlink_buffer}" | "${JQ}" --unbuffered -r '.items[] | (.sources // [])[0].name // (.sources // [])[0].id // "unknown"' 2>/dev/null)
		while IFS= read -r line; do rl_dst+=(   "${line}"); done < <(echo "${rlink_buffer}" | "${JQ}" --unbuffered -r '.items[] | (.targets // [])[0].name // (.targets // [])[0].id // "unknown"' 2>/dev/null)
		rl_status=(`echo "${rlink_buffer}" | "${JQ}" --unbuffered -r '.items[].status  // "replicating"' 2>/dev/null | "${AWK}" 1 ORS=' '`)
		rl_lag=(   `echo "${rlink_buffer}" | "${JQ}" --unbuffered -r '.items[].lag     // 0'             2>/dev/null | "${AWK}" 1 ORS=' '`)
		rl_paused=(`echo "${rlink_buffer}" | "${JQ}" --unbuffered -r '.items[].paused  // false'         2>/dev/null | "${AWK}" 1 ORS=' '`)

		_rl_total=0
		_rl_crit=0
		_rl_warn=0

		for count in "${!rl_src[@]}"; do
			(( _rl_total++ ))
			_rlst="${rl_status[count]}"
			_rlpause="${rl_paused[count]}"
			_rllag_ms=`echo "${rl_lag[count]}" | "${AWK}" '{printf "%.0f",$1/1000}'`
			_safe_rl=`echo "${array_name}_${rl_src[count]}_${rl_dst[count]}" | tr '.-/ ' '____'`
			_rl_ids="${rl_src[count]}->${rl_dst[count]}"
			_rl_pause_s=""
			[[ "${_rlpause}" == "true" ]] && _rl_pause_s=" | PAUSED"

			case "${_rlst}" in
			replicating)
				if [[ "${_rlpause}" == "true" ]]; then
					pure_output+="${status_warn} - PodReplicaLink ${array_name} ${_rl_ids}: ${_rlst}${_rl_pause_s} | lag: ${_rllag_ms}ms\n"
					pure_problem_output+="${status_warn} - PodReplicaLink ${array_name} ${_rl_ids}: ${_rlst}${_rl_pause_s}\n"
					(( _rl_warn++ ))
				elif [[ -n "${verbose}" ]]; then
					pure_output+="${status_ok} - PodReplicaLink ${array_name} ${_rl_ids}: ${_rlst} | lag: ${_rllag_ms}ms\n"
				fi
				;;
			idle)
				pure_output+="${status_warn} - PodReplicaLink ${array_name} ${_rl_ids}: IDLE${_rl_pause_s} | lag: ${_rllag_ms}ms\n"
				pure_problem_output+="${status_warn} - PodReplicaLink ${array_name} ${_rl_ids}: IDLE${_rl_pause_s}\n"
				(( _rl_warn++ ))
				;;
			unhealthy)
				pure_output+="${status_crit} - PodReplicaLink ${array_name} ${_rl_ids}: UNHEALTHY${_rl_pause_s} | lag: ${_rllag_ms}ms\n"
				pure_problem_output+="${status_crit} - PodReplicaLink ${array_name} ${_rl_ids}: UNHEALTHY${_rl_pause_s}\n"
				(( _rl_crit++ ))
				;;
			*)
				pure_output+="${status_unkn} - PodReplicaLink ${array_name} ${_rl_ids}: unrecognized status: ${_rlst}${_rl_pause_s}\n"
				pure_problem_output+="${status_unkn} - PodReplicaLink ${array_name} ${_rl_ids}: unrecognized status: ${_rlst}\n"
				;;
			esac

			pure_perf+=" rlink_${_safe_rl}_lag=${rl_lag[count]}us"
		done

		if [[ "${_rl_total}" -gt 0 && "${_rl_crit}" -eq 0 && "${_rl_warn}" -eq 0 && -z "${verbose}" ]]; then
			pure_output+="${status_ok} - PodReplicaLinks: ${_rl_total} link(s) replicating\n"
		fi

		pure_perf+=" rlinks_total=${_rl_total} rlinks_crit=${_rl_crit} rlinks_warn=${_rl_warn}"
		unset rl_src rl_dst rl_status rl_lag rl_paused
	fi

	# --- Bucket replica links (FlashBlade) ---
	brl_buffer=`${api_cmd_get}/bucket-replica-links \
		-H "${CURL_OPTS_AUTH}" -H "${CURL_OPTS_JSON}"`

	if [[ -n "${brl_buffer}" && ! "${brl_buffer}" =~ '"errors"' ]]; then
		declare -a brl_lbkt brl_rbkt brl_remote brl_status brl_lag brl_dir brl_details

		brl_lbkt=(  `echo "${brl_buffer}" | "${JQ}" --unbuffered -r '(.items // [])[] | .local_bucket.name // "unknown"'  2>/dev/null | "${AWK}" 1 ORS=' '`)
		brl_rbkt=(  `echo "${brl_buffer}" | "${JQ}" --unbuffered -r '(.items // [])[] | .remote_bucket.name // "unknown"' 2>/dev/null | "${AWK}" 1 ORS=' '`)
		brl_remote=(`echo "${brl_buffer}" | "${JQ}" --unbuffered -r '(.items // [])[] | .remote.name // "unknown"'        2>/dev/null | "${AWK}" 1 ORS=' '`)
		brl_status=(`echo "${brl_buffer}" | "${JQ}" --unbuffered -r '(.items // [])[] | .status // "unknown"'             2>/dev/null | "${AWK}" 1 ORS=' '`)
		brl_lag=(   `echo "${brl_buffer}" | "${JQ}" --unbuffered -r '(.items // [])[] | .lag // 0'                        2>/dev/null | "${AWK}" 1 ORS=' '`)
		brl_dir=(   `echo "${brl_buffer}" | "${JQ}" --unbuffered -r '(.items // [])[] | .direction // "unknown"'          2>/dev/null | "${AWK}" 1 ORS=' '`)
		while IFS= read -r line; do brl_details+=("${line}"); done < \
			<(echo "${brl_buffer}" | "${JQ}" --unbuffered -r '(.items // [])[] | .status_details // ""' 2>/dev/null)

		_brl_total=0
		_brl_crit=0
		_brl_warn=0

		for count in "${!brl_lbkt[@]}"; do
			(( _brl_total++ ))
			_brlst="${brl_status[count]}"
			_brldet="${brl_details[count]}"
			_brllag_ms=`echo "${brl_lag[count]}" | "${AWK}" '{printf "%.0f",$1/1000}'`
			_safe_brl=`echo "${array_name}_${brl_lbkt[count]}_${brl_rbkt[count]}" | tr '.-/ ' '____'`
			_det_s=""
			[[ -n "${_brldet}" ]] && _det_s=" | ${_brldet}"

			if [[ "${_brlst}" == "replicating" ]]; then
				if [[ -n "${verbose}" ]]; then
					pure_output+="${status_ok} - BucketReplica ${array_name} ${brl_lbkt[count]}->${brl_rbkt[count]} (${brl_remote[count]}, ${brl_dir[count]}): replicating | lag: ${_brllag_ms}ms\n"
				fi
			elif [[ "${_brlst}" == "paused" ]]; then
				pure_output+="${status_warn} - BucketReplica ${array_name} ${brl_lbkt[count]}->${brl_rbkt[count]} (${brl_remote[count]}, ${brl_dir[count]}): PAUSED | lag: ${_brllag_ms}ms${_det_s}\n"
				pure_problem_output+="${status_warn} - BucketReplica ${array_name} ${brl_lbkt[count]}->${brl_rbkt[count]}: PAUSED${_det_s}\n"
				(( _brl_warn++ ))
			elif [[ "${_brlst}" == "unhealthy" ]]; then
				pure_output+="${status_crit} - BucketReplica ${array_name} ${brl_lbkt[count]}->${brl_rbkt[count]} (${brl_remote[count]}, ${brl_dir[count]}): UNHEALTHY | lag: ${_brllag_ms}ms${_det_s}\n"
				pure_problem_output+="${status_crit} - BucketReplica ${array_name} ${brl_lbkt[count]}->${brl_rbkt[count]}: UNHEALTHY${_det_s}\n"
				(( _brl_crit++ ))
			else
				pure_output+="${status_unkn} - BucketReplica ${array_name} ${brl_lbkt[count]}->${brl_rbkt[count]} (${brl_remote[count]}): status '${_brlst}'${_det_s}\n"
				pure_problem_output+="${status_unkn} - BucketReplica ${array_name} ${brl_lbkt[count]}->${brl_rbkt[count]}: status '${_brlst}'${_det_s}\n"
			fi

			pure_perf+=" brl_${_safe_brl}_lag=${brl_lag[count]}us"
		done

		if [[ "${_brl_total}" -gt 0 && "${_brl_crit}" -eq 0 && "${_brl_warn}" -eq 0 && -z "${verbose}" ]]; then
			pure_output+="${status_ok} - Bucket replica links: ${_brl_total} link(s) replicating\n"
		fi

		pure_perf+=" brl_total=${_brl_total} brl_critical=${_brl_crit} brl_warning=${_brl_warn}"
		unset brl_lbkt brl_rbkt brl_remote brl_status brl_lag brl_dir brl_details
	fi

	# --- Array connection paths ---
	path_buffer=`${api_cmd_get}/array-connections/path \
		-H "${CURL_OPTS_AUTH}" -H "${CURL_OPTS_JSON}"`

	if [[ -n "${path_buffer}" && ! "${path_buffer}" =~ '"errors"' ]]; then
		declare -a cp_remote cp_src cp_dst cp_status cp_details

		cp_remote=(`echo "${path_buffer}" | "${JQ}" --unbuffered -r \
			'(.items // [])[] | .remote.name // .remote.id // "unknown"' 2>/dev/null | "${AWK}" 1 ORS=' '`)
		cp_src=(   `echo "${path_buffer}" | "${JQ}" --unbuffered -r \
			'(.items // [])[] | .source // "unknown"'      2>/dev/null | "${AWK}" 1 ORS=' '`)
		cp_dst=(   `echo "${path_buffer}" | "${JQ}" --unbuffered -r \
			'(.items // [])[] | .destination // "unknown"' 2>/dev/null | "${AWK}" 1 ORS=' '`)
		cp_status=(`echo "${path_buffer}" | "${JQ}" --unbuffered -r \
			'(.items // [])[] | .status // "unknown"'      2>/dev/null | "${AWK}" 1 ORS=' '`)
		while IFS= read -r line; do cp_details+=("${line}"); done < \
			<(echo "${path_buffer}" | "${JQ}" --unbuffered -r \
				'(.items // [])[] | .status_details // ""' 2>/dev/null)

		_cp_total=0
		_cp_warn=0

		for count in "${!cp_remote[@]}"; do
			(( _cp_total++ ))
			_cpst="${cp_status[count]}"
			_cpdet="${cp_details[count]}"
			_det_s=""
			[[ -n "${_cpdet}" ]] && _det_s=" | ${_cpdet}"
			_safe_cp=`echo "${array_name}_${cp_remote[count]}_${count}" | tr '.-/: ' '_____'`
			if [[ "${cp_src[count]}" != "unknown" || "${cp_dst[count]}" != "unknown" ]]; then
				_path_s="${cp_src[count]} -> ${cp_dst[count]} "
			else
				_path_s=""
			fi

			if [[ "${_cpst}" == "connected" ]]; then
				if [[ -n "${verbose}" && -n "${_path_s}" ]]; then
					pure_output+="${status_ok} - ConnPath ${array_name}: ${_path_s}(${cp_remote[count]}): connected\n"
				fi
			elif [[ "${_cpst}" == "connecting" ]]; then
				pure_output+="${status_warn} - ConnPath ${array_name}: ${_path_s}(${cp_remote[count]}): connecting${_det_s}\n"
				pure_problem_output+="${status_warn} - ConnPath ${array_name}: ${_path_s}(${cp_remote[count]}): connecting${_det_s}\n"
				(( _cp_warn++ ))
			else
				pure_output+="${status_unkn} - ConnPath ${array_name}: ${_path_s}(${cp_remote[count]}): ${_cpst}${_det_s}\n"
				pure_problem_output+="${status_unkn} - ConnPath ${array_name}: ${_path_s}(${cp_remote[count]}): ${_cpst}${_det_s}\n"
				(( _cp_warn++ ))
			fi

			pure_perf+=" connpath_${_safe_cp}_up=`[[ "${_cpst}" == "connected" ]] && echo 1 || echo 0`"
		done

		if [[ "${_cp_total}" -gt 0 && "${_cp_warn}" -eq 0 && -z "${verbose}" ]]; then
			pure_output+="${status_ok} - Connection paths: ${_cp_total} path(s) connected\n"
		fi

		pure_perf+=" connpaths_total=${_cp_total} connpaths_warn=${_cp_warn}"
		unset cp_remote cp_src cp_dst cp_status cp_details
	fi

	# --- Array connection replication performance ---
	rcp_buffer=`${api_cmd_get}/array-connections/performance/replication \
		-H "${CURL_OPTS_AUTH}" -H "${CURL_OPTS_JSON}"`

	if [[ -n "${rcp_buffer}" && ! "${rcp_buffer}" =~ '"errors"' ]]; then
		declare -a rcp_remote

		rcp_remote=(`echo "${rcp_buffer}" | "${JQ}" --unbuffered -r \
			'(.items // [])[] | .remote.name // .remote.id // "unknown"' 2>/dev/null | "${AWK}" 1 ORS=' '`)

		for count in "${!rcp_remote[@]}"; do
			_rcp_tx=`echo "${rcp_buffer}" | "${JQ}" --unbuffered -r \
				".items[${count}].periodic.transmitted_bytes_per_sec // 0"`
			_rcp_rx=`echo "${rcp_buffer}" | "${JQ}" --unbuffered -r \
				".items[${count}].periodic.received_bytes_per_sec // 0"`
			_safe_rcp=`echo "${array_name}_${rcp_remote[count]}" | tr '.-/ ' '____'`
			_rcp_tx_h=`echo "${_rcp_tx}" | "${AWK}" '{if($1>=1073741824) printf "%.2f GiB/s",$1/1073741824; else if($1>=1048576) printf "%.2f MiB/s",$1/1048576; else if($1>=1024) printf "%.2f KiB/s",$1/1024; else printf "%d B/s",$1}'`
			_rcp_rx_h=`echo "${_rcp_rx}" | "${AWK}" '{if($1>=1073741824) printf "%.2f GiB/s",$1/1073741824; else if($1>=1048576) printf "%.2f MiB/s",$1/1048576; else if($1>=1024) printf "%.2f KiB/s",$1/1024; else printf "%d B/s",$1}'`
			if [[ -n "${verbose}" ]]; then
				pure_output+="${status_ok} - ReplPerf ${array_name} -> ${rcp_remote[count]}: TX:${_rcp_tx_h} RX:${_rcp_rx_h}\n"
			fi
			pure_perf+=" rcp_${_safe_rcp}_tx=`_perf_bandwidth "${_rcp_tx}"`"
			pure_perf+=" rcp_${_safe_rcp}_rx=`_perf_bandwidth "${_rcp_rx}"`"
		done

		_rcp_tot_tx=`echo "${rcp_buffer}" | "${JQ}" --unbuffered -r \
			'.total[0].periodic.transmitted_bytes_per_sec // 0' 2>/dev/null`
		_rcp_tot_rx=`echo "${rcp_buffer}" | "${JQ}" --unbuffered -r \
			'.total[0].periodic.received_bytes_per_sec // 0' 2>/dev/null`
		_rcp_tot_tx_h=`echo "${_rcp_tot_tx}" | "${AWK}" '{if($1>=1073741824) printf "%.2f GiB/s",$1/1073741824; else if($1>=1048576) printf "%.2f MiB/s",$1/1048576; else if($1>=1024) printf "%.2f KiB/s",$1/1024; else printf "%d B/s",$1}'`
		_rcp_tot_rx_h=`echo "${_rcp_tot_rx}" | "${AWK}" '{if($1>=1073741824) printf "%.2f GiB/s",$1/1073741824; else if($1>=1048576) printf "%.2f MiB/s",$1/1048576; else if($1>=1024) printf "%.2f KiB/s",$1/1024; else printf "%d B/s",$1}'`
		if [[ -n "${verbose}" ]]; then
			pure_output+="${status_ok} - ReplPerf ${array_name} total: TX:${_rcp_tot_tx_h} RX:${_rcp_tot_rx_h}\n"
		fi
		pure_perf+=" rcp_${array_name}_total_tx=`_perf_bandwidth "${_rcp_tot_tx}"`"
		pure_perf+=" rcp_${array_name}_total_rx=`_perf_bandwidth "${_rcp_tot_rx}"`"

		unset rcp_remote
	fi

	if [[ -n "${verbose}" ]]; then
		pure_output+="---------------------------------------\n\n"
	fi
fi

# ---------------------------------------------------------------------------
# Certificate Check
# ---------------------------------------------------------------------------
if [[ ( -n "${enable_certs}" || -n "${enable_all}" ) && -z "${disable_certs}" ]]; then
	cert_buffer=`${api_cmd_get}/certificates \
		-H "${CURL_OPTS_AUTH}" -H "${CURL_OPTS_JSON}"`

	if [[ -n "${verbose}" ]]; then
		pure_output+="Certificates:\n---------------------------------------\n"
	fi

	declare -a cert_name cert_cn cert_type cert_issued_by cert_valid_to

	cert_name=(`echo "${cert_buffer}" | "${JQ}" --unbuffered -r '.items[].name'                      2>/dev/null | "${AWK}" 1 ORS=' '`)
	cert_cn=(  `echo "${cert_buffer}" | "${JQ}" --unbuffered -r '.items[].common_name // "n/a"'      2>/dev/null | "${AWK}" 1 ORS=' '`)
	cert_type=(`echo "${cert_buffer}" | "${JQ}" --unbuffered -r '.items[].certificate_type // "n/a"' 2>/dev/null | "${AWK}" 1 ORS=' '`)
	while IFS= read -r line; do cert_issued_by+=("${line}"); done < \
		<(echo "${cert_buffer}" | "${JQ}" --unbuffered -r '.items[].issued_by // "unknown"' 2>/dev/null)
	while IFS= read -r line; do cert_valid_to+=("${line}"); done < \
		<(echo "${cert_buffer}" | "${JQ}" --unbuffered -r '.items[].valid_to // ""' 2>/dev/null)

	_cert_total=0
	_cert_crit=0
	_cert_warn=0
	_cert_min_days=99999
	_now_epoch=`date +%s`

	for count in "${!cert_name[@]}"; do
		(( _cert_total++ ))
		_cname="${cert_name[count]}"
		_ccn="${cert_cn[count]}"
		_cvto="${cert_valid_to[count]}"
		_cissby="${cert_issued_by[count]}"
		_safe_cert=`echo "${array_name}_${_cname}" | tr '.-/ ' '____'`

		if [[ -z "${_cvto}" ]]; then
			pure_output+="${status_unkn} - Cert ${array_name}/${_cname}: no valid_to date available\n"
			pure_problem_output+="${status_unkn} - Cert ${array_name}/${_cname}: no valid_to date available\n"
			continue
		fi

		if [[ "${_cvto}" =~ ^[0-9]+$ ]]; then
			_cert_epoch=$(( _cvto / 1000 ))
		else
			_cert_epoch=`date -d "${_cvto}" +%s 2>/dev/null`
		fi
		if [[ -z "${_cert_epoch}" ]]; then
			pure_output+="${status_unkn} - Cert ${array_name}/${_cname}: cannot parse expiry date '${_cvto}'\n"
			pure_problem_output+="${status_unkn} - Cert ${array_name}/${_cname}: cannot parse expiry date '${_cvto}'\n"
			continue
		fi

		_days_left=$(( (_cert_epoch - _now_epoch) / 86400 ))
		[[ "${_days_left}" -lt "${_cert_min_days}" ]] && _cert_min_days="${_days_left}"

		if [[ "${_days_left}" -le 0 ]]; then
			pure_output+="${status_crit} - Cert ${array_name}/${_cname}: EXPIRED since ${_cvto} | CN: ${_ccn} | issued by: ${_cissby}\n"
			pure_problem_output+="${status_crit} - Cert ${array_name}/${_cname}: EXPIRED since ${_cvto}\n"
			(( _cert_crit++ ))
		elif [[ "${_days_left}" -lt "${crit_cert}" ]]; then
			pure_output+="${status_crit} - Cert ${array_name}/${_cname}: expires ${_cvto} (${_days_left} days) | CN: ${_ccn} | issued by: ${_cissby}\n"
			pure_problem_output+="${status_crit} - Cert ${array_name}/${_cname}: expires in ${_days_left} days (${_cvto})\n"
			(( _cert_crit++ ))
		elif [[ "${_days_left}" -lt "${warn_cert}" ]]; then
			pure_output+="${status_warn} - Cert ${array_name}/${_cname}: expires ${_cvto} (${_days_left} days) | CN: ${_ccn} | issued by: ${_cissby}\n"
			pure_problem_output+="${status_warn} - Cert ${array_name}/${_cname}: expires in ${_days_left} days (${_cvto})\n"
			(( _cert_warn++ ))
		else
			if [[ -n "${verbose}" ]]; then
				pure_output+="${status_ok} - Cert ${array_name}/${_cname} (${cert_type[count]}): expires ${_cvto} (${_days_left} days) | CN: ${_ccn} | issued by: ${_cissby}\n"
			fi
		fi

		pure_perf+=" cert_${_safe_cert}_days=${_days_left};${warn_cert};${crit_cert};0"
	done

	if [[ "${_cert_total}" -gt 0 && "${_cert_crit}" -eq 0 && "${_cert_warn}" -eq 0 && -z "${verbose}" ]]; then
		if [[ "${_cert_min_days}" -lt 99999 ]]; then
			pure_output+="${status_ok} - Certificates: ${_cert_total} cert(s) valid, earliest expiry in ${_cert_min_days} days\n"
		else
			pure_output+="${status_ok} - Certificates: ${_cert_total} cert(s) checked\n"
		fi
	fi

	pure_perf+=" certs_total=${_cert_total} certs_critical=${_cert_crit} certs_warning=${_cert_warn}"

	if [[ -n "${verbose}" ]]; then
		pure_output+="---------------------------------------\n\n"
	fi

	unset cert_name cert_cn cert_type cert_issued_by cert_valid_to
fi

# ---------------------------------------------------------------------------
# Alerts Check
# ---------------------------------------------------------------------------
if [[ ( -n "${enable_alerts}" || -n "${enable_all}" ) && -z "${disable_alerts}" ]]; then
	alerts_buffer=`${api_cmd_get}"/alerts?filter=state!%3D%27closed%27" \
		-H "${CURL_OPTS_AUTH}" -H "${CURL_OPTS_JSON}"`

	if [[ -n "${verbose}" ]]; then
		pure_output+="Alerts:\n---------------------------------------\n"
	fi

	declare -a al_id al_code al_sev al_cat al_state
	declare -a al_comp_a al_summ_a al_kb_a

	al_id=(   `echo "${alerts_buffer}" | "${JQ}" --unbuffered -r '.items[].id'                2>/dev/null | "${AWK}" 1 ORS=' '`)
	al_code=( `echo "${alerts_buffer}" | "${JQ}" --unbuffered -r '.items[].code // 0'         2>/dev/null | "${AWK}" 1 ORS=' '`)
	al_sev=(  `echo "${alerts_buffer}" | "${JQ}" --unbuffered -r '.items[].severity'          2>/dev/null | "${AWK}" 1 ORS=' '`)
	al_cat=(  `echo "${alerts_buffer}" | "${JQ}" --unbuffered -r '.items[].category // "n/a"' 2>/dev/null | "${AWK}" 1 ORS=' '`)
	al_state=(`echo "${alerts_buffer}" | "${JQ}" --unbuffered -r '.items[].state // "open"'   2>/dev/null | "${AWK}" 1 ORS=' '`)
	while IFS= read -r line; do al_comp_a+=("${line}"); done < \
		<(echo "${alerts_buffer}" | "${JQ}" --unbuffered -r '.items[].component_name // "unknown"' 2>/dev/null)
	while IFS= read -r line; do al_summ_a+=("${line}"); done < \
		<(echo "${alerts_buffer}" | "${JQ}" --unbuffered -r '.items[].summary // "no summary"' 2>/dev/null)
	while IFS= read -r line; do al_kb_a+=("${line}"); done < \
		<(echo "${alerts_buffer}" | "${JQ}" --unbuffered -r '.items[].knowledge_base_url // ""' 2>/dev/null)

	# build blacklist map from --blacklist-alarmcode "111,112,113"
	declare -A _al_bl_map
	if [[ -n "${al_blacklist}" ]]; then
		IFS=',' read -ra _al_bl_arr <<< "${al_blacklist}"
		for _bl in "${_al_bl_arr[@]}"; do
			_al_bl_map["${_bl}"]=1
		done
	fi

	_al_total=`echo "${alerts_buffer}" | "${JQ}" --unbuffered '.items | length' 2>/dev/null`
	_al_error=0
	_al_warning=0
	_al_info=0
	_al_blacklisted=0

	for count in "${!al_id[@]}"; do
		_alcode="${al_code[count]}"

		if [[ -n "${_al_bl_map[${_alcode}]}" ]]; then
			(( _al_blacklisted++ ))
			continue
		fi

		_sev="${al_sev[count]}"
		_state="${al_state[count]}"
		_comp="${al_comp_a[count]}"
		_summ="${al_summ_a[count]}"
		_kb="${al_kb_a[count]}"
		_kb_s=""
		[[ -n "${_kb}" ]] && _kb_s=" (KB: ${_kb})"
		_prefix="Alert ${array_name}: [${al_cat[count]}] (code:${_alcode}) ${_comp}: ${_summ}"

		if [[ "${_state}" == "open" ]]; then
			case "${_sev}" in
			error|critical)
				pure_output+="${status_crit} - ${_prefix}${_kb_s}\n"
				pure_problem_output+="${status_crit} - ${_prefix}${_kb_s}\n"
				(( _al_error++ ))
				;;
			warning)
				pure_output+="${status_warn} - ${_prefix}${_kb_s}\n"
				pure_problem_output+="${status_warn} - ${_prefix}${_kb_s}\n"
				(( _al_warning++ ))
				;;
			info)
				pure_output+="${status_ok} - ${_prefix}${_kb_s}\n"
				(( _al_info++ ))
				;;
			esac
		elif [[ "${_state}" == "waiting to downgrade" ]]; then
			pure_output+="${status_warn} - ${_prefix} (${_state})${_kb_s}\n"
			pure_problem_output+="${status_warn} - ${_prefix} (${_state})${_kb_s}\n"
			(( _al_warning++ ))
		else
			# closing or any other non-open non-waiting state -> OK
			if [[ -n "${verbose}" ]]; then
				pure_output+="${status_ok} - ${_prefix} (${_state})${_kb_s}\n"
			fi
		fi
	done

	_al_active=$(( _al_total - _al_blacklisted ))
	if [[ "${_al_active}" -eq 0 ]]; then
		_bl_s=""
		[[ "${_al_blacklisted}" -gt 0 ]] && _bl_s=" (${_al_blacklisted} blacklisted)"
		pure_output+="${status_ok} - Alerts: No active alerts${_bl_s}\n"
	elif [[ "${_al_error}" -eq 0 && "${_al_warning}" -eq 0 ]]; then
		pure_output+="${status_ok} - Alerts: ${_al_info} informational alert(s)\n"
	fi

	pure_perf+=" alerts_total=${_al_active} alerts_error=${_al_error} alerts_warning=${_al_warning} alerts_info=${_al_info}"

	if [[ -n "${verbose}" ]]; then
		pure_output+="---------------------------------------\n\n"
	fi

	unset al_id al_code al_sev al_cat al_state al_comp_a al_summ_a al_kb_a _al_bl_map
fi

# ---------------------------------------------------------------------------
# Subscriptions Check
# ---------------------------------------------------------------------------
if [[ ( -n "${enable_subs}" || -n "${enable_all}" ) && -z "${disable_subs}" ]]; then
	subs_buffer=`${api_cmd_get}/subscriptions \
		-H "${CURL_OPTS_AUTH}" -H "${CURL_OPTS_JSON}"`

	if [[ -z "${subs_buffer}" || "${subs_buffer}" =~ '"errors"' || "${subs_buffer}" == 'null' ]]; then
		pure_output+="${status_ok} - Subscriptions: none (no additional license installed)\n"
	else

	if [[ -n "${verbose}" ]]; then
		pure_output+="Subscriptions:\n---------------------------------------\n"
	fi

	declare -a sub_name sub_status sub_service sub_exp sub_start

	sub_name=(   `echo "${subs_buffer}" | "${JQ}" --unbuffered -r '.items[].name'              2>/dev/null | "${AWK}" 1 ORS=' '`)
	sub_status=( `echo "${subs_buffer}" | "${JQ}" --unbuffered -r '.items[].status // "unknown"' 2>/dev/null | "${AWK}" 1 ORS=' '`)
	sub_exp=(    `echo "${subs_buffer}" | "${JQ}" --unbuffered -r '.items[].expiration_date // 0' 2>/dev/null | "${AWK}" 1 ORS=' '`)
	while IFS= read -r line; do sub_service+=("${line}"); done < \
		<(echo "${subs_buffer}" | "${JQ}" --unbuffered -r '.items[].service // "n/a"' 2>/dev/null)

	_sub_total=0
	_sub_ok=0
	_sub_warn=0
	_sub_crit=0
	_now_epoch=`date +%s`

	for count in "${!sub_name[@]}"; do
		_sname="${sub_name[count]}"
		[[ -z "${_sname}" || "${_sname}" == "null" ]] && continue
		(( _sub_total++ ))
		_sstatus="${sub_status[count]}"
		_sservice="${sub_service[count]}"
		_sexp_ms="${sub_exp[count]}"
		_safe_sub=`echo "${array_name}_${_sname}" | tr '.-/ ' '____'`

		# evaluate status
		case "${_sstatus}" in
		active|signed)
			_sub_status_flag=0
			;;
		poc-expired)
			_sub_status_flag=1
			;;
		terminated)
			_sub_status_flag=2
			;;
		*)
			_sub_status_flag=3
			;;
		esac

		# evaluate expiry
		_sub_exp_s=""
		_sub_days_left=""
		if [[ "${_sexp_ms}" -gt 0 ]]; then
			_sexp_epoch=$(( _sexp_ms / 1000 ))
			_sub_days_left=$(( (_sexp_epoch - _now_epoch) / 86400 ))
			_sexp_date=`date -d "@${_sexp_epoch}" +%Y-%m-%d 2>/dev/null || date -r "${_sexp_epoch}" +%Y-%m-%d 2>/dev/null`
			_sub_exp_s=" expires: ${_sexp_date} (${_sub_days_left}d)"

			if [[ "${_sub_days_left}" -le 0 ]]; then
				[[ "${_sub_status_flag}" -lt 2 ]] && _sub_status_flag=2
				_sub_exp_s=" EXPIRED ${_sexp_date}"
			elif [[ "${_sub_days_left}" -lt "${crit_sub}" ]]; then
				[[ "${_sub_status_flag}" -lt 2 ]] && _sub_status_flag=2
			elif [[ "${_sub_days_left}" -lt "${warn_sub}" ]]; then
				[[ "${_sub_status_flag}" -lt 1 ]] && _sub_status_flag=1
			fi
		fi

		case "${_sub_status_flag}" in
		0)
			(( _sub_ok++ ))
			if [[ -n "${verbose}" ]]; then
				pure_output+="${status_ok} - Subscription ${array_name}: ${_sname} (${_sservice}) ${_sstatus}${_sub_exp_s}\n"
			fi
			pure_perf+=" sub_${_safe_sub}_days=${_sub_days_left:-0};${warn_sub};${crit_sub};0;"
			;;
		1)
			(( _sub_warn++ ))
			pure_output+="${status_warn} - Subscription ${array_name}: ${_sname} (${_sservice}) ${_sstatus^^}${_sub_exp_s}\n"
			pure_problem_output+="${status_warn} - Subscription ${array_name}: ${_sname} ${_sstatus^^}${_sub_exp_s}\n"
			pure_perf+=" sub_${_safe_sub}_days=${_sub_days_left:-0};${warn_sub};${crit_sub};0;"
			;;
		2)
			(( _sub_crit++ ))
			pure_output+="${status_crit} - Subscription ${array_name}: ${_sname} (${_sservice}) ${_sstatus^^}${_sub_exp_s}\n"
			pure_problem_output+="${status_crit} - Subscription ${array_name}: ${_sname} ${_sstatus^^}${_sub_exp_s}\n"
			pure_perf+=" sub_${_safe_sub}_days=${_sub_days_left:-0};${warn_sub};${crit_sub};0;"
			;;
		*)
			pure_output+="${status_unkn} - Subscription ${array_name}: ${_sname} (${_sservice}) unrecognized status: ${_sstatus}\n"
			pure_problem_output+="${status_unkn} - Subscription ${array_name}: ${_sname} unrecognized status: ${_sstatus}\n"
			;;
		esac
	done

	if [[ "${_sub_total}" -eq 0 ]]; then
		pure_output+="${status_ok} - Subscription ${array_name}: no additional license installed\n"
	elif [[ "${_sub_crit}" -eq 0 && "${_sub_warn}" -eq 0 && -z "${verbose}" ]]; then
		pure_output+="${status_ok} - Subscriptions: ${_sub_ok}/${_sub_total} active\n"
	fi

	pure_perf+=" subs_total=${_sub_total} subs_ok=${_sub_ok} subs_warn=${_sub_warn} subs_crit=${_sub_crit}"

	if [[ -n "${verbose}" ]]; then
		pure_output+="---------------------------------------\n\n"
	fi

	unset sub_name sub_status sub_service sub_exp

	fi # end null/error check
fi

# ---------------------------------------------------------------------------
# Metrics Check
# ---------------------------------------------------------------------------
if [[ ( -n "${enable_metrics}" || -n "${enable_all}" ) && -z "${disable_metrics}" ]]; then
	metrics_catalog_buffer=`${api_cmd_get}"/metrics?resource_types=array" \
		-H "${CURL_OPTS_AUTH}" -H "${CURL_OPTS_JSON}"`

	if [[ -z "${metrics_catalog_buffer}" || "${metrics_catalog_buffer}" =~ '"errors"' ]]; then
		pure_output+="${status_ok} - Metrics: endpoint not available on this array (Pure1 cloud API only)\n"
	else

	_met_names_raw=(`echo "${metrics_catalog_buffer}" | "${JQ}" --unbuffered -r '.items[].name' 2>/dev/null | "${AWK}" 1 ORS=' '`)
	_met_units_raw=(`echo "${metrics_catalog_buffer}" | "${JQ}" --unbuffered -r '.items[].unit // "none"' 2>/dev/null | "${AWK}" 1 ORS=' '`)

	_met_total="${#_met_names_raw[@]}"

	if [[ "${_met_total}" -gt 0 ]]; then
		_met_names_csv=$(IFS=,; echo "${_met_names_raw[*]}")

		_now_sec=`date +%s`
		_start_ms=$(( (_now_sec - 120) * 1000 ))
		_end_ms=$(( _now_sec * 1000 ))

		metrics_history_buffer=`${api_cmd_get}"/metrics/history?resolution=30000&start_time=${_start_ms}&end_time=${_end_ms}&names=${_met_names_csv}" \
			-H "${CURL_OPTS_AUTH}" -H "${CURL_OPTS_JSON}"`

		declare -a mh_name mh_val mh_unit

		while IFS= read -r line; do mh_name+=("${line}"); done < \
			<(echo "${metrics_history_buffer}" | "${JQ}" --unbuffered -r '.items[] | .name // "unknown"' 2>/dev/null)
		while IFS= read -r line; do mh_val+=("${line}"); done < \
			<(echo "${metrics_history_buffer}" | "${JQ}" --unbuffered -r '.items[] | if (.data | length) > 0 then .data[-1][1] else null end | . // "U"' 2>/dev/null)

		_met_catalog_map=()
		for i in "${!_met_names_raw[@]}"; do
			_met_catalog_map+=("${_met_names_raw[$i]}=${_met_units_raw[$i]}")
		done

		_met_ok=0
		_met_null=0

		if [[ -n "${verbose}" ]]; then
			pure_output+="Metrics:\n---------------------------------------\n"
		fi

		for count in "${!mh_name[@]}"; do
			_mn="${mh_name[count]}"
			_mv="${mh_val[count]}"

			_mu="none"
			for _cm in "${_met_catalog_map[@]}"; do
				if [[ "${_cm%%=*}" == "${_mn}" ]]; then
					_mu="${_cm#*=}"
					break
				fi
			done

			_perf_label="${_mn//\//_}"
			_perf_label="${_perf_label//-/_}"

			if [[ "${_mv}" == "U" || "${_mv}" == "null" ]]; then
				(( _met_null++ ))
				pure_perf+=" metric_${_perf_label}=U"
			else
				(( _met_ok++ ))
				case "${_mu}" in
				bytes|byte)    pure_perf+=" metric_${_perf_label}=${_mv}B" ;;
				ms)            pure_perf+=" metric_${_perf_label}=${_mv}ms" ;;
				us|usec)       pure_perf+=" metric_${_perf_label}=${_mv}us" ;;
				percent|pct)   pure_perf+=" metric_${_perf_label}=${_mv}%" ;;
				*)             pure_perf+=" metric_${_perf_label}=${_mv}" ;;
				esac
				if [[ -n "${verbose}" ]]; then
					pure_output+="${status_ok} - Metric ${_mn}: ${_mv} ${_mu}\n"
				fi
			fi
		done

		if [[ -z "${verbose}" ]]; then
			pure_output+="${status_ok} - Metrics: ${_met_ok} metric(s) collected, ${_met_null} without data\n"
		else
			pure_output+="---------------------------------------\n\n"
		fi

		unset mh_name mh_val mh_unit _met_catalog_map
	else
		pure_output+="${status_ok} - Metrics: no metrics available from catalog\n"
	fi

	unset _met_names_raw _met_units_raw
	fi # end error check
fi

# ---------------------------------------------------------------------------
# Determine exit state from output content and print result
# ---------------------------------------------------------------------------
if [[ ${pure_output} =~ "[UNKNOWN]" ]]; then
	state=3
	if [[ -z "${silent}" ]]; then
		pure_problems="One or more Problems detected:\n---------------------------------------------------------------------\n"
		pure_problem_output+="---------------------------------------------------------------------\n\nAll Services:\n---------------------------------------------------------------------\n"
	fi
elif [[ ${pure_output} =~ "[CRITICAL]" ]]; then
	state=2
	if [[ -z "${silent}" ]]; then
		pure_problems="One or more Problems detected:\n---------------------------------------------------------------------\n"
		pure_problem_output+="---------------------------------------------------------------------\n\nAll Services:\n---------------------------------------------------------------------\n"
	fi
elif [[ ${pure_output} =~ "[WARNING]" ]]; then
	state=1
	if [[ -z "${silent}" ]]; then
		pure_problems="One or more Problems detected:\n---------------------------------------------------------------------\n"
		pure_problem_output+="---------------------------------------------------------------------\n\nAll Services:\n---------------------------------------------------------------------\n"
	fi
else
	state=0
	pure_problems="All Services OK"
fi

# Replace | in human-readable text with , to avoid Nagios treating it as a perfdata separator
_pp="${pure_problem_output//|/,}"
_po="${pure_output//|/,}"
_perf_sep="${no_perfdata:+}" ; [[ -z "${no_perfdata}" ]] && _perf_sep="|${pure_perf}"

if [[ -z "${silent}" && -n "${pure_problem_output}" ]]; then
	echo -e "${pure_problems}${_pp}${_po}${_perf_sep}"
elif [[ -n "${silent}" && -n "${pure_problem_output}" ]]; then
	echo -e "${_pp}${_perf_sep}"
elif [[ -n "${silent}" && -z "${pure_problem_output}" ]]; then
	echo -e "${status_ok} - All Services are fine${_perf_sep}"
elif [[ -z "${silent}" && -z "${pure_problem_output}" ]]; then
	echo -e "${_po}${_perf_sep}"
else
	echo -e "${_po}${_perf_sep}"
fi
exitstate=${state}
exit ${exitstate}
