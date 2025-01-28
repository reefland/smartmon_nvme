#!/usr/bin/env bash
#
# Script informed by the collectd monitoring script for smartmontools (using smartctl)
# originally by Samuel B. <samuel_._behan_(at)_dob_._sk> (c) 2012.
# source at: http://devel.dob.sk/collectd-scripts/

# Updated to support nvme attributes from smartmontools and not use scsi attributes
# by Richard J. Durso - source at: https://github.com/reefland/smartmon_nvme
# Released: 01/28/2025

# Formatting done via shfmt -i 2
# https://github.com/mvdan/sh

# Check if we are root
if [ "$EUID" -ne 0 ]; then
  echo "${0##*/}: root is required to access smartctl daemon, please run as root!" >&2
  exit 1
fi

# Check if smartctl is installed
if ! command -v smartctl >/dev/null 2>&1; then
  echo "${0##*/}: smartctl is not installed. Aborting." >&2
  exit 1
fi

set -euo pipefail
IFS=$'\n\t'

parse_smartctl_attributes_awk="$(
  cat <<'SMARTCTLAWK'
$1 ~ /^ *[0-9]+$/ && $2 ~ /^[a-zA-Z0-9_-]+$/ {
  gsub(/-/, "_");
  printf "%s_value{%s,smart_id=\"%s\"} %d\n", tolower($2), labels, $1, $4
  printf "%s_worst{%s,smart_id=\"%s\"} %d\n", tolower($2), labels, $1, $5
  printf "%s_threshold{%s,smart_id=\"%s\"} %d\n", tolower($2), labels, $1, $6
  printf "%s_raw_value{%s,smart_id=\"%s\"} %e\n", tolower($2), labels, $1, $10
}
SMARTCTLAWK
)"

smartmon_attrs="$(
  cat <<'SMARTMONATTRS'
airflow_temperature_cel
command_timeout
current_pending_sector
end_to_end_error
erase_fail_count
g_sense_error_rate
hardware_ecc_recovered
host_reads_mib
host_reads_32mib
host_writes_mib
host_writes_32mib
load_cycle_count
media_wearout_indicator
wear_leveling_count
nand_writes_1gib
offline_uncorrectable
percent_lifetime_remain
power_cycle_count
power_on_hours
program_fail_count
raw_read_error_rate
reallocated_event_count
reallocated_sector_ct
reported_uncorrect
sata_downshift_count
seek_error_rate
spin_retry_count
spin_up_time
start_stop_count
temperature_case
temperature_celsius
temperature_internal
total_lbas_read
total_lbas_written
udma_crc_error_count
unsafe_shutdown_count
workld_host_reads_perc
workld_media_wear_indic
workload_minutes
SMARTMONATTRS
)"
smartmon_attrs="$(echo "${smartmon_attrs}" | xargs | tr ' ' '|')"

parse_smartctl_attributes() {
  local labels="$1"
  sed 's/^ \+//g' |
    awk -v labels="${labels}" "${parse_smartctl_attributes_awk}" 2>/dev/null |
    grep -iE "(${smartmon_attrs})"
}

parse_smartctl_scsi_attributes() {
  local labels="$1"
  while read -r line; do
    attr_type="$(echo "${line}" | tr '=' ':' | cut -f1 -d: | sed 's/^ \+//g' | tr ' ' '_')"
    attr_value="$(echo "${line}" | tr '=' ':' | cut -f2 -d: | sed 's/^ \+//g')"
    case "${attr_type}" in
    number_of_hours_powered_up_) power_on="$(echo "${attr_value}" | awk '{ printf "%e\n", $1 }')" ;;
    Current_Drive_Temperature) temp_cel="$(echo "${attr_value}" | cut -f1 -d' ' | awk '{ printf "%e\n", $1 }')" ;;
    Blocks_sent_to_initiator_) lbas_read="$(echo "${attr_value}" | awk '{ printf "%e\n", $1 }')" ;;
    Blocks_received_from_initiator_) lbas_written="$(echo "${attr_value}" | awk '{ printf "%e\n", $1 }')" ;;
    Accumulated_start-stop_cycles) power_cycle="$(echo "${attr_value}" | awk '{ printf "%e\n", $1 }')" ;;
    Elements_in_grown_defect_list) grown_defects="$(echo "${attr_value}" | awk '{ printf "%e\n", $1 }')" ;;
    esac
  done
  [ -n "$power_on" ] && echo "power_on_hours_raw_value{${labels},smart_id=\"9\"} ${power_on}"
  [ -n "$temp_cel" ] && echo "temperature_celsius_raw_value{${labels},smart_id=\"194\"} ${temp_cel}"
  [ -n "$lbas_read" ] && echo "total_lbas_read_raw_value{${labels},smart_id=\"242\"} ${lbas_read}"
  [ -n "$lbas_written" ] && echo "total_lbas_written_raw_value{${labels},smart_id=\"241\"} ${lbas_written}"
  [ -n "$power_cycle" ] && echo "power_cycle_count_raw_value{${labels},smart_id=\"12\"} ${power_cycle}"
  [ -n "$grown_defects" ] && echo "grown_defects_count_raw_value{${labels},smart_id=\"196\"} ${grown_defects}"
}

# NVME tested with smartctl 7.2
parse_smartctl_nvme_attributes() {
  local labels="$1"
  while read -r line; do
    attr_type="$(echo "${line}" | tr '=' ':' | cut -f1 -d: | sed 's/^ \+//g' | tr ' ' '_')"
    attr_value="$(echo "${line}" | tr '=' ':' | cut -f2 -d: | sed 's/^ \+//g')"
    case "${attr_type}" in
    Power_On_Hours) power_on="$(echo "${attr_value}" | awk '{ gsub(",",""); printf "%e\n", $1 }')" ;;
    Temperature) temp_cel="$(echo "${attr_value}" | cut -f1 -d' ' | awk '{ printf "%e\n", $1 }')" ;;
    Data_Units_Read) lbas_read="$(echo "${attr_value}" | awk '{ gsub(",",""); printf "%e\n", $1*1000 }')" ;; #Stored as number of thousands units
    Data_Units_Written) lbas_written="$(echo "${attr_value}" | awk '{ gsub(",",""); printf "%e\n", $1*1000 }')" ;; #Stored as number of thousands units
    Power_Cycles) power_cycle="$(echo "${attr_value}" | awk '{ gsub(",",""); printf "%e\n", $1 }')" ;;
    Media_and_Data_Integrity_Errors) grown_defects="$(echo "${attr_value}" | awk '{ gsub(",",""); printf "%e\n", $1 }')" ;;
    Unsafe_Shutdowns) unsafe_shutdown_count="$(echo "${attr_value}" | awk '{ gsub(",",""); printf "%e\n", $1 }')" ;;
    Percentage_Used) wear_leveling_count="$(echo "${attr_value}" | awk '{ gsub(",",""); printf "%d\n", 100-$1 }')" ;; # value subtracted from 100
    esac
  done
  [ -n "$power_on" ] && echo "power_on_hours_raw_value{${labels},smart_id=\"9\"} ${power_on}"
  [ -n "$temp_cel" ] && echo "temperature_celsius_raw_value{${labels},smart_id=\"194\"} ${temp_cel}"
  [ -n "$lbas_read" ] && echo "total_lbas_read_raw_value{${labels},smart_id=\"242\"} ${lbas_read}"
  [ -n "$lbas_written" ] && echo "total_lbas_written_raw_value{${labels},smart_id=\"241\"} ${lbas_written}"
  [ -n "$power_cycle" ] && echo "power_cycle_count_raw_value{${labels},smart_id=\"12\"} ${power_cycle}"
  [ -n "$grown_defects" ] && echo "grown_defects_count_raw_value{${labels},smart_id=\"196\"} ${grown_defects}"
  [ -n "$unsafe_shutdown_count" ] && echo "unsafe_shutdown_count_raw_value{${labels},smart_id=\"228\"} ${unsafe_shutdown_count}"
  [ -n "$wear_leveling_count" ] && echo "wear_leveling_count_value{${labels},smart_id=\"233\"} ${wear_leveling_count}"
}

extract_labels_from_smartctl_info() {
  local disk="$1" disk_type="$2"
  local model_family='<None>' device_model='<None>' serial_number='<None>' fw_version='<None>' vendor='<None>' product='<None>' revision='<None>' lun_id='<None>'
  while read -r line; do
    info_type="$(echo "${line}" | cut -f1 -d: | tr ' ' '_')"
    info_value="$(echo "${line}" | cut -f2- -d: | sed 's/^ \+//g' | sed 's/"/'"'"'/g')"
    case "${info_type}" in
    Model_Family) model_family="${info_value}" ;;
    Device_Model) device_model="${info_value}" ;;
    Model_Number) device_model="${info_value}" ;;
    Serial_Number) serial_number="${info_value}" ;;
    Firmware_Version) fw_version="${info_value}" ;;
    Vendor) vendor="${info_value}" ;;
    Product) product="${info_value}" ;;
    Revision) revision="${info_value}" ;;
    Logical_Unit_id) lun_id="${info_value}" ;;
    esac
  done
  echo "disk=\"${disk}\",type=\"${disk_type}\",vendor=\"${vendor}\",product=\"${product}\",revision=\"${revision}\",lun_id=\"${lun_id}\",model_family=\"${model_family}\",device_model=\"${device_model}\",serial_number=\"${serial_number}\",firmware_version=\"${fw_version}\""
}

parse_smartctl_info() {
  local -i smart_available=0 smart_enabled=0 smart_healthy='' sector_size_log=512 sector_size_phy=512
  local labels="$1"
  while read -r line; do
    info_type="$(echo "${line}" | cut -f1 -d: | tr ' ' '_')"
    info_value="$(echo "${line}" | cut -f2- -d: | sed 's/^ \+//g' | sed 's/"/\\"/')"

    case "${info_type}" in
      'SMART_support_is')
        case "${info_value:0:7}" in
        Enabled)
          smart_available=1
          smart_enabled=1
          ;;
        Availab)
          smart_available=1
          smart_enabled=0
          ;;
        Unavail)
          smart_available=0
          smart_enabled=0
          ;;
        esac
      ;;
      'SMART_overall-health_self-assessment_test_result')
        case "${info_value:0:6}" in
          PASSED) smart_healthy=1 ;;
          *) smart_healthy=0 ;;
        esac
        ;;
      'SMART_Health_Status')
        case "${info_value:0:2}" in
        OK) smart_healthy=1 ;;
        *) smart_healthy=0 ;;
        esac
        ;;
      'Sector_Size')
        sector_size_log=$(echo "$info_value" | cut -d' ' -f1)
        sector_size_phy=$(echo "$info_value" | cut -d' ' -f1)
        ;;
      'Sector_Sizes')
        sector_size_log="$(echo "$info_value" | cut -d' ' -f1)"
        sector_size_phy="$(echo "$info_value" | cut -d' ' -f4)"
        ;;
    esac

  done
  [ -n "${smart_healthy}" ] && echo "device_smart_healthy{${labels}} ${smart_healthy}"
  echo "device_smart_available{${labels}} ${smart_available}"
  echo "device_smart_enabled{${labels}} ${smart_enabled}"
  echo "device_sector_size_logical{${labels}} ${sector_size_log}"
  echo "device_sector_size_physical{${labels}} ${sector_size_phy}"
}

parse_smartctl_returnvalue() {
  local status=$1
  local labels=$2

  for ((i = 0; i < 8; i++)); do
    case $i in
    0) echo -n "smartctl_statusbit_commandline_not_parsed{${labels}} " ;;
    1) echo -n "smartctl_statusbit_device_open_failed{${labels}} " ;;
    2) echo -n "smartctl_statusbit_device_command_failed{${labels}} " ;;
    3) echo -n "smartctl_statusbit_disk_failing{${labels}} " ;;
    4) echo -n "smartctl_statusbit_prefail_attributes_below_thresh{${labels}} " ;;
    5) echo -n "smartctl_statusbit_disk_ok_previous_prefail_attributes{${labels}} " ;;
    6) echo -n "smartctl_statusbit_device_error_log_has_errors{${labels}} " ;;
    7) echo -n "smartctl_statusbit_device_selftest_log_has_errors{${labels}} " ;;
    esac
    echo "$((status & 2 ** i && 1))"
  done
}

output_format_awk="$(
  cat <<'OUTPUTAWK'
BEGIN { v = "" }
v != $1 {
  print "# HELP smartmon_" $1 " SMART metric " $1;
  print "# TYPE smartmon_" $1 " gauge";
  v = $1
}
{print "smartmon_" $0}
OUTPUTAWK
)"

format_output() {
  sort |
    awk -F'{' "${output_format_awk}"
}

smartctl_version="$(/usr/sbin/smartctl -V | head -n1 | awk '$1 == "smartctl" {print $2}')"

echo "smartctl_version{version=\"${smartctl_version}\"} 1" | format_output

if [[ "$(expr "${smartctl_version}" : '\([0-9]*\)\..*')" -lt 6 ]]; then
  exit
fi

device_list="$(/usr/sbin/smartctl --scan-open | awk '/^\/dev/{print $1 "|" $3}')"

for device in ${device_list}; do
  disk="$(echo "${device}" | cut -f1 -d'|')"
  type="$(echo "${device}" | cut -f2 -d'|')"
  active=1
  echo "smartctl_run{disk=\"${disk}\",type=\"${type}\"}" "$(TZ=UTC date '+%s')"
  # Check if the device is in a low-power mode
  /usr/sbin/smartctl -n standby -d "${type}" "${disk}" >/dev/null || active=0
  echo "device_active{disk=\"${disk}\",type=\"${type}\"}" "${active}"
  # Skip further metrics to prevent the disk from spinning up
  test ${active} -eq 0 && continue

  # Get the SMART information and health,
  # Allow non-zero exit code and store it
  set +e
  smart_info="$(/usr/sbin/smartctl -i -H -d "${type}" "${disk}")"
  status=$?
  set -e

  disk_labels="$(echo "$smart_info" | extract_labels_from_smartctl_info "${disk}" "${type}")"
  echo "$smart_info" | parse_smartctl_info "${disk_labels}"

  # Parse out smartctl's exit code into separate metrics
  parse_smartctl_returnvalue $status "${disk_labels}"

  # Get the SMART attributes
  case ${type} in
  sat) /usr/sbin/smartctl -A -d "${type}" "${disk}" | parse_smartctl_attributes "${disk_labels}" || true ;;
  sat+megaraid*) /usr/sbin/smartctl -A -d "${type}" "${disk}" | parse_smartctl_attributes "${disk_labels}" || true ;;
  scsi) /usr/sbin/smartctl -A -d "${type}" "${disk}" | parse_smartctl_scsi_attributes "${disk_labels}" || true ;;
  megaraid*) /usr/sbin/smartctl -A -d "${type}" "${disk}" | parse_smartctl_scsi_attributes "${disk_labels}" || true ;;
  nvme*) /usr/sbin/smartctl -A -d "${type}" "${disk}" | parse_smartctl_nvme_attributes "${disk_labels}" || true ;;
  *)
    (echo >&2 "disk type is not sat, scsi, nvme or megaraid but ${type}")
    exit
    ;;
  esac
done | format_output
