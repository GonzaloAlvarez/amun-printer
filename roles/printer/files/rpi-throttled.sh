#!/bin/bash
# amun-printer: export `vcgencmd get_throttled` (+ SoC temperature and core
# voltage) as node_exporter textfile metrics. Runs from /etc/cron.d every
# minute on Raspberry Pi hosts; a no-op anywhere without vcgencmd.
#
# get_throttled bits: 0 under-voltage now, 1 ARM frequency capped now,
# 2 throttled now, 3 soft temperature limit now; 16–19 = the same, "has
# occurred since boot".
set -u
OUT="${RPI_TEXTFILE_DIR:-/var/lib/node_exporter/textfile_collector}/rpi.prom"

command -v vcgencmd >/dev/null 2>&1 || exit 0
raw="$(vcgencmd get_throttled 2>/dev/null | sed -n 's/^throttled=//p')"
[ -n "$raw" ] || exit 0
v=$((raw))
temp="$(vcgencmd measure_temp 2>/dev/null | sed -n "s/^temp=\([0-9.]*\)'C.*/\1/p")"
volt="$(vcgencmd measure_volts core 2>/dev/null | sed -n 's/^volt=\([0-9.]*\)V.*/\1/p')"

bit() { echo $(( (v >> $1) & 1 )); }

tmp="${OUT}.$$"
{
  echo "# HELP rpi_throttled_raw Raw bitfield from vcgencmd get_throttled."
  echo "# TYPE rpi_throttled_raw gauge"
  echo "rpi_throttled_raw $v"
  echo "# HELP rpi_undervoltage_now 1 while the SoC reports under-voltage (<4.63 V)."
  echo "# TYPE rpi_undervoltage_now gauge"
  echo "rpi_undervoltage_now $(bit 0)"
  echo "# HELP rpi_frequency_capped_now 1 while the ARM frequency is capped."
  echo "# TYPE rpi_frequency_capped_now gauge"
  echo "rpi_frequency_capped_now $(bit 1)"
  echo "# HELP rpi_throttled_now 1 while the SoC is throttled."
  echo "# TYPE rpi_throttled_now gauge"
  echo "rpi_throttled_now $(bit 2)"
  echo "# HELP rpi_soft_temp_limit_now 1 while the soft temperature limit is active."
  echo "# TYPE rpi_soft_temp_limit_now gauge"
  echo "rpi_soft_temp_limit_now $(bit 3)"
  echo "# HELP rpi_undervoltage_occurred 1 if under-voltage happened since boot."
  echo "# TYPE rpi_undervoltage_occurred gauge"
  echo "rpi_undervoltage_occurred $(bit 16)"
  echo "# HELP rpi_frequency_capped_occurred 1 if frequency capping happened since boot."
  echo "# TYPE rpi_frequency_capped_occurred gauge"
  echo "rpi_frequency_capped_occurred $(bit 17)"
  echo "# HELP rpi_throttled_occurred 1 if throttling happened since boot."
  echo "# TYPE rpi_throttled_occurred gauge"
  echo "rpi_throttled_occurred $(bit 18)"
  echo "# HELP rpi_soft_temp_limit_occurred 1 if the soft temperature limit was hit since boot."
  echo "# TYPE rpi_soft_temp_limit_occurred gauge"
  echo "rpi_soft_temp_limit_occurred $(bit 19)"
  if [ -n "$temp" ]; then
    echo "# HELP rpi_soc_temp_celsius SoC temperature from vcgencmd measure_temp."
    echo "# TYPE rpi_soc_temp_celsius gauge"
    echo "rpi_soc_temp_celsius $temp"
  fi
  if [ -n "$volt" ]; then
    echo "# HELP rpi_core_volts Core voltage from vcgencmd measure_volts core."
    echo "# TYPE rpi_core_volts gauge"
    echo "rpi_core_volts $volt"
  fi
  echo "# HELP rpi_throttled_last_update_seconds Unix time this file was written."
  echo "# TYPE rpi_throttled_last_update_seconds gauge"
  echo "rpi_throttled_last_update_seconds $(date +%s)"
} > "$tmp" && mv -f "$tmp" "$OUT"
