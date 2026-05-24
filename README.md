# PureStorage FlashArray / FlashBlade Monitoring Plugin

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Shell Script](https://img.shields.io/badge/Shell-Bash-green.svg)](https://www.gnu.org/software/bash/)
[![Monitoring](https://img.shields.io/badge/Monitoring-Icinga%2FNagios-blue.svg)](https://icinga.com/)
[![Version](https://img.shields.io/badge/version-2.7.0-orange.svg)](CHANGELOG.md)

A comprehensive Bash-based monitoring plugin for PureStorage FlashArray and FlashBlade appliances, compatible with Icinga and Nagios monitoring systems. This plugin monitors hardware health, capacity, performance, replication, networking, and more — directly via the PureStorage REST API v2. No Pure1 cloud account or RSA key required.

## Features

- **Direct API Access**: Connects to the array's local REST API v2 — no Pure1 cloud dependency
- **FlashArray & FlashBlade**: A single plugin covers both product lines
- **Comprehensive Coverage**: Hardware, drives, space, performance, volumes, snapshots, replication, networking, certificates, alerts, offloads, software, and more
- **Flexible Authentication**: API token, username/password, or pre-obtained session token
- **Opt-in or Opt-out**: Use `-eX` flags to run only specific checks, or `--disable-X` to suppress individual modules from the full set
- **Granular Thresholds**: Per-metric warning/critical thresholds for space, temperature, latency, IOPS, bandwidth, certificates, and more
- **Blacklisting & Selection**: Skip or focus on specific volumes, NICs, or alert codes
- **Perfdata Output**: Full Nagios-compatible perfdata for all check modules — compatible with PNP4Nagios, Graphite, InfluxDB, etc.
- **Verbose & Silent Modes**: Tunable output verbosity for dashboards and automation

## Prerequisites

Ensure the following tools are installed on your monitoring server:

- **bash** (4.0 or higher)
- **curl** (for API communication)
- **jq** (for JSON parsing)
- **awk** (for text processing)

### Installation on Different Platforms

**Ubuntu/Debian:**
```bash
sudo apt-get update
sudo apt-get install curl jq gawk
```

**RHEL/CentOS/Rocky Linux:**
```bash
sudo dnf install curl jq gawk
```

**Gentoo:**
```bash
sudo emerge net-misc/curl app-misc/jq sys-apps/gawk
```

## Installation

1. **Clone the repository:**
   ```bash
   git clone https://github.com/ascii42/check_purestorage_health.git
   cd check_purestorage_health
   ```

2. **Make the script executable:**
   ```bash
   chmod +x check_purestorage_health.sh
   ```

3. **Copy to your monitoring plugins directory:**
   ```bash
   # For Icinga2
   sudo cp check_purestorage_health.sh /usr/lib/nagios/plugins/

   # For Nagios
   sudo cp check_purestorage_health.sh /usr/local/nagios/libexec/
   ```

## Usage

### Basic Syntax

```bash
./check_purestorage_health.sh [-h] [-V] -H <host> { -a <api_token> | -U <user> -P <pass> } [options] [-w <warn>] [-c <crit>]
```

### Authentication

| Method | Parameters | Description |
|--------|-----------|-------------|
| API token | `-a <token>` | Recommended — token generated per user in array GUI (Settings › Users › API tokens) |
| Username / Password | `-U <user> -P <pass>` | Login-based — session token obtained automatically |
| Pre-obtained token | `-T <x-auth-token>` | Skips login step — useful for testing or CI pipelines |

### Required Parameters

| Parameter | Description |
|-----------|-------------|
| `-H, --host <hostname\|IP>` | Hostname or IP address of the FlashArray or FlashBlade |
| `-a, --api-token <token>` | API token (option A) |
| `-U, --username <user>` | Username (option B) |
| `-P, --password <pass>` | Password (option B) |

### Enable Flags (opt-in)

If any `-eX` flag is given, **only those modules** run. When no flags are given, all modules run (equivalent to `-A`).

| Flag | Long form | Description |
|------|-----------|-------------|
| `-eAr` | `--enable-arrays` | Array info: name, OS, Purity version |
| `-eS` | `--enable-space` | Space / capacity utilization |
| `-eH` | `--enable-hardware` | Hardware component health with temperature |
| `-eConn` | `--enable-connectors` | Connector / port health (FC, iSCSI, NVMe-oF, Ethernet) |
| `-eCTRL` | `--enable-controllers` | Controller status and mode |
| `-eD` | `--enable-drives` | Drive health |
| `-eBl` | `--enable-blades` | FlashBlade blade health and raw capacity |
| `-eP` | `--enable-performance` | Array + FS + bucket I/O (IOPS, BW, latency) |
| `-eVol` | `--enable-volumes` | Volume space and per-volume I/O performance |
| `-eSnap` | `--enable-snapshots` | Volume snapshot space and DR |
| `-eSnapXfer` | `--enable-snapshot-transfers` | Active snapshot transfer progress |
| `-eFS` | `--enable-filesystems` | FlashBlade file-system space / writable state |
| `-eDi` | `--enable-directories` | FlashBlade directory space / quota |
| `-eBu` | `--enable-buckets` | FlashBlade S3 bucket space and object count |
| `-eOS` | `--enable-object-store` | FlashBlade S3 object store account space |
| `-eQ` | `--enable-quotas` | FlashBlade user/group quota |
| `-eNI` | `--enable-network` | Network interface status and port details |
| `-eNIPerf` | `--enable-ni-performance` | Per-interface RX/TX bandwidth, packet rates, errors |
| `-eNIPort` | `--enable-ni-port-details` | Optical transceiver health (rx/tx power, temp, bias, voltage) |
| `-eNINbr` | `--enable-ni-neighbors` | LLDP neighbor discovery |
| `-eOff` | `--enable-offloads` | Offload targets (NFS/S3/Azure/GCS) status and space |
| `-ePatch` | `--enable-patches` | Software patch catalog state |
| `-eSW` | `--enable-software` | Software/upgrade status and pre-check results |
| `-eDNS` | `--enable-dns` | DNS configuration check |
| `-eSyslog` | `--enable-syslog` | Syslog server configuration check |
| `-eRep` | `--enable-replication` | Pods, array connections, replica-link lag |
| `-eCert` | `--enable-certs` | Certificate expiry check |
| `-eAl` | `--enable-alerts` | Open alerts |
| `-eSub` | `--enable-subscriptions` | Subscription status and expiry |
| `-eM` | `--enable-metrics` | Raw metrics via /metrics + /metrics/history (perfdata) |
| `-A` | `--enable-all` | Enable all checks |

### Disable Flags (opt-out)

Suppress individual modules when running the full check set:

```
--disable-arrays        --disable-space         --disable-hardware
--disable-connectors    --disable-controllers   --disable-drives        --disable-blades
--disable-performance   --disable-volumes       --disable-snapshots     --disable-snapshot-transfers
--disable-filesystems   --disable-directories   --disable-buckets       --disable-object-store
--disable-quotas        --disable-network       --disable-ni-performance
--disable-ni-port-details  --disable-ni-neighbors
--disable-offloads      --disable-patches       --disable-software
--disable-dns           --disable-syslog        --disable-replication
--disable-certs         --disable-alerts        --disable-subscriptions --disable-license
--disable-metrics
```

### Threshold Options

| Option | Default | Description |
|--------|---------|-------------|
| `-w, --warning <pct>` | 80 | WARNING threshold for space/quota in % |
| `-c, --critical <pct>` | 90 | CRITICAL threshold for space/quota in % |
| `--warn-temp <°C>` | 65 | WARNING threshold for component temperature |
| `--crit-temp <°C>` | 75 | CRITICAL threshold for component temperature |
| `--warn-cert <days>` | 30 | WARNING threshold for certificate expiry |
| `--crit-cert <days>` | 15 | CRITICAL threshold for certificate expiry |
| `--warn-sub <days>` | 30 | WARNING threshold for subscription expiry |
| `--crit-sub <days>` | 15 | CRITICAL threshold for subscription expiry |
| `-wIO <iops>` | — | WARNING threshold for total array IOPS |
| `-cIO <iops>` | — | CRITICAL threshold for total array IOPS |
| `-wBW <MB/s>` | — | WARNING threshold for array bandwidth |
| `-cBW <MB/s>` | — | CRITICAL threshold for array bandwidth |
| `-wLat <ms>` | — | WARNING threshold for read/write latency |
| `-cLat <ms>` | — | CRITICAL threshold for read/write latency |
| `-wVol <%>` | 80 | WARNING threshold for volume physical / provisioned % |
| `-cVol <%>` | 90 | CRITICAL threshold for volume physical / provisioned % |

### Compliance / Expected Configuration

| Option | Description |
|--------|-------------|
| `-N, --array-name <name>` | Expected array name — exits UNKNOWN if connected array does not match |
| `--ntp-server <server[,...]>` | Expected NTP server(s) — WARNING if any are missing (subset check) |
| `--ntp-servers-strict` | NTP check: require exact match (no extra servers allowed) |
| `--timezone <tz>` | Expected timezone string (e.g. `Europe/Berlin`) — WARNING if array TZ differs |
| `--dns-server <server[,...]>` | Expected DNS nameserver(s) — WARNING if any are missing (subset check) |
| `--dns-servers-strict` | DNS check: require exact match |
| `--syslog-server <uri[,...]>` | Expected syslog server URI(s) — WARNING if any are missing (subset check) |
| `--syslog-servers-strict` | Syslog check: require exact match |

### Filter Options

| Option | Description |
|--------|-------------|
| `--blacklist-alarmcode <list>` | Comma-separated alert codes to suppress (e.g. `111,112`) |
| `--blacklist-volumes <list>` | Volume names to skip in per-volume checks |
| `--select-volumes <list>` | Only check these volume names (exclusive) |
| `--blacklist-nics <list>` | NIC names to skip in NI checks |

### Output Options

| Option | Description |
|--------|-------------|
| `--perfdata` | Show performance data in output even without `--verbose` |
| `--no-perfdata` | Suppress the perfdata section entirely |
| `-s, --silent` | Show only problem lines (suppress OK detail) |
| `-v, --verbose` | Print section headers and full per-item detail |
| `-d, --debug` | Enable bash trace output (`set -x`) |
| `--api-version <ver>` | Override REST API version (default: auto-detect latest 2.x) |

## Examples

### Full Health Check
Check everything with default thresholds:
```bash
./check_purestorage_health.sh -H 10.0.0.100 -a fad28db0-xxxx-yyyy-zzzz -A -w 80 -c 90
```

### Check Specific Modules
Only hardware and open alerts:
```bash
./check_purestorage_health.sh -H flasharray.example.com -a <token> -eH -eAl -v
```

### Volumes with Thresholds and Blacklist
Check volumes, warn at 70%, skip test/staging volumes:
```bash
./check_purestorage_health.sh -H 10.0.0.100 -a <token> -eVol -wVol 70 -cVol 85 \
  --blacklist-volumes staging-vol,test-vol
```

### Replication with Verbose Output
```bash
./check_purestorage_health.sh -H flasharray.example.com -U monitor -P secret -eRep -v
```

### Certificate Expiry with Custom Thresholds
Warn 60 days before, critical 14 days before:
```bash
./check_purestorage_health.sh -H 10.0.0.100 -a <token> -eCert --warn-cert 60 --crit-cert 14
```

### Verify NTP and Syslog Configuration
Ensure specific servers are configured — strict match required:
```bash
./check_purestorage_health.sh -H 10.0.0.100 -a <token> -eAr \
  --ntp-server ntp1.example.com,ntp2.example.com --ntp-servers-strict \
  --syslog-server tcp://syslog.example.com --syslog-servers-strict
```

### Performance Summary Without Full Verbose
Show volume performance data without per-item detail lines:
```bash
./check_purestorage_health.sh -H 10.0.0.100 -a <token> -eVol --perfdata
```

### Full Check, Suppress Noisy Modules
```bash
./check_purestorage_health.sh -H 10.0.0.100 -a <token> -A \
  --disable-metrics --disable-ni-performance --disable-ni-neighbors --no-perfdata
```

## Sample Output

```
Arrays:
---------------------------------------
[OK] - Array: myflasharray (FlashArray) | Purity: 6.4.12 | Rev: 1234567890 | OS: Purity//FA
---------------------------------------

Space / Capacity:
---------------------------------------
[OK] - Space myflasharray: used 42.30 TiB / 100.00 TiB (42.3%) DR: 3.45:1 | 12 volumes
---------------------------------------

Hardware:
---------------------------------------
[OK] - Hardware myflasharray: 24 components OK (0 warn, 0 crit)
---------------------------------------

Volumes:
---------------------------------------
[OK] - Volumes myflasharray: 12 volumes | physical: 42.30 TiB provisioned: 200.00 TiB (21.2%) DR: 3.45:1 | snapshots: 1.20 TiB
[OK] - Volume myflasharray/data-vol-01: 10.50 TiB / 50.00 TiB (21.0%) DR: 3.20:1 snap: 512.00 MiB
[WARNING] - Volume myflasharray/archive-vol: 43.50 GiB / 50.00 GiB (87.0%) DR: 1.10:1 snap: 0 B
---------------------------------------

Replication:
---------------------------------------
[OK] - Pod myflasharray/ActivePod1: healthy | mediator: connected
[OK] - Replication myflasharray -> myflasharray-dr (sync/ip): connected
---------------------------------------

Alerts:
---------------------------------------
[OK] - Alerts myflasharray: no open alerts
---------------------------------------
```

## Integration with Monitoring Systems

### Icinga2 Configuration

Create a command definition in `/etc/icinga2/conf.d/commands.conf`:

```icinga2
object CheckCommand "check_purestorage" {
    command = [ PluginDir + "/check_purestorage_health.sh" ]
    arguments = {
        "-H"  = "$pure_host$"
        "-a"  = "$pure_api_token$"
        "-U"  = "$pure_username$"
        "-P"  = "$pure_password$"
        "-w"  = "$pure_warning$"
        "-c"  = "$pure_critical$"
        "-A"  = {
            set_if = "$pure_check_all$"
        }
        "-v"  = {
            set_if = "$pure_verbose$"
        }
        "--warn-cert"       = "$pure_warn_cert$"
        "--crit-cert"       = "$pure_crit_cert$"
        "--warn-temp"       = "$pure_warn_temp$"
        "--crit-temp"       = "$pure_crit_temp$"
        "--ntp-server"      = "$pure_ntp_server$"
        "--syslog-server"   = "$pure_syslog_server$"
        "--disable-metrics" = {
            set_if = "$pure_disable_metrics$"
        }
        "--no-perfdata" = {
            set_if = "$pure_no_perfdata$"
        }
    }
    vars.pure_warning        = 80
    vars.pure_critical       = 90
    vars.pure_warn_cert      = 30
    vars.pure_crit_cert      = 15
    vars.pure_warn_temp      = 65
    vars.pure_crit_temp      = 75
    vars.pure_check_all      = true
    vars.pure_verbose        = false
    vars.pure_disable_metrics = false
    vars.pure_no_perfdata    = false
}
```

Create a service definition:

```icinga2
apply Service "PureStorage Health" {
    check_command = "check_purestorage"
    vars.pure_host      = host.vars.pure_host
    vars.pure_api_token = host.vars.pure_api_token
    vars.pure_warning   = 80
    vars.pure_critical  = 90
    vars.pure_warn_cert = 30
    vars.pure_crit_cert = 14

    assign where host.vars.pure_host != ""
}
```

### Nagios Configuration

Add to `commands.cfg`:

```nagios
define command {
    command_name    check_purestorage
    command_line    $USER1$/check_purestorage_health.sh -H $ARG1$ -a $ARG2$ -A -w $ARG3$ -c $ARG4$
}
```

Add to `services.cfg`:

```nagios
define service {
    use                 generic-service
    host_name           myflasharray
    service_description PureStorage Health
    check_command       check_purestorage!10.0.0.100!your-api-token-here!80!90
}
```

## Security Considerations

- **API Token**: Create a dedicated read-only monitoring user in the array GUI and generate an API token for that account. Avoid reusing admin credentials.
- **Credential Storage**: Store API tokens in your monitoring system's secrets store (Icinga2 `TicketSalt`, HashiCorp Vault, etc.) — not in plain-text config files where possible.
- **Network Access**: The monitoring server requires HTTPS (port 443) access to the array management IP. No outbound internet access is needed.
- **Self-Signed Certificates**: The plugin uses `--insecure` with curl to accept the array's self-signed certificate. If you have a trusted CA-signed certificate on the array, this flag has no effect on security.
- **Minimal Permissions**: The API token user only needs read access — a `Read Only` role is sufficient for all check modules.

## Troubleshooting

### Common Issues

**Authentication Failure (`[UNKNOWN]`):**
- Verify the API token or username/password is correct
- Check if the API token has expired (Pure arrays support token expiry)
- Confirm the user account is not locked
- Try with `-T` and a manually obtained session token to isolate the issue

**Connection Timeout:**
- Verify network connectivity: `curl -k https://<array-ip>/api/api_version`
- Check firewall rules between the monitoring server and the array management IP
- Confirm port 443 is open

**`jq: command not found`:**
- Install jq: `apt install jq` / `dnf install jq` / `emerge app-misc/jq`

**Empty or `null` response fields:**
- Some endpoints (subscriptions, offloads, software) return null on arrays where the feature is not in use — this is intentional and reported as OK.
- Use `--no-perfdata` to suppress the perfdata section entirely if a downstream system cannot handle the output format.

**API version mismatch:**
- Use `--api-version 2.x` to pin to a specific version if auto-detection picks up an unsupported version.

### Debug Mode

Enable full bash trace output for deep troubleshooting:
```bash
./check_purestorage_health.sh -H 10.0.0.100 -a <token> -A -d 2>&1 | less
```

Or use verbose mode for readable per-item detail:
```bash
./check_purestorage_health.sh -H 10.0.0.100 -a <token> -eVol -eRep -v
```

## Contributing

Contributions are welcome! Please feel free to submit issues, feature requests, or pull requests.

1. Fork the repository
2. Create a feature branch (`git checkout -b feature/my-new-check`)
3. Make your changes
4. Test against a real array or a mock JSON fixture
5. Submit a pull request

## License

This project is licensed under the MIT License — see the [LICENSE](LICENSE) file for details.

## Support

For support, please:
1. Review the troubleshooting section above
2. Check existing GitHub issues
3. Open a new issue with your array model, Purity version, and the full plugin output with `-d` (debug) enabled

## Author

**Felix Longardt**
- Email: monitoring@longardt.com
- GitHub: [@ascii42](https://github.com/ascii42)

## Acknowledgments

- Pure Storage for the comprehensive REST API v2 documentation
- The Icinga and Nagios communities for feedback and testing
- Contributors who have helped improve this plugin

---

**Note**: This plugin is not officially supported by Pure Storage, Inc. Use at your own discretion and test thoroughly in your environment before deploying to production monitoring.
