# Human-readable snapshot of shell/system health. No network requests are made.

__f_health_bytes() {
  awk -v kb="${1:-0}" 'BEGIN { b=kb*1024; split("B KiB MiB GiB TiB PiB",u," "); i=1; while (b>=1024 && i<6) {b/=1024; i++}; if (i==1) printf "%.0f %s",b,u[i]; else printf "%.1f %s",b,u[i] }'
}

f_health() {
  if [[ "${1:-}" == '--help' || "${1:-}" == '-h' ]]; then
    printf 'Usage: f_health [EXISTING_PATH]\nShows date/time, uptime, OS, load, RAM/swap, directory size, and filesystem space.\n'
    return 0
  fi
  local _f_target="${1:-$PWD}" _f_now _f_uptime _f_os _f_kernel _f_arch _f_load
  local _f_mem_total=0 _f_mem_avail=0 _f_mem_used=0 _f_swap_total=0 _f_swap_free=0
  local _f_disk_line _f_dir_size _f_cyan='' _f_bold='' _f_reset=''

  if [[ ! -e "$_f_target" ]]; then
    printf 'F health: path does not exist: %s\n' "$_f_target" >&2
    return 2
  fi
  if [[ -t 1 && -z "${NO_COLOR:-}" && "${TERM:-dumb}" != dumb ]]; then
    _f_cyan=$'\033[36m'; _f_bold=$'\033[1m'; _f_reset=$'\033[0m'
  fi

  _f_now="$(date '+%A, %d %B %Y  %H:%M:%S %Z' 2>/dev/null || date)"
  _f_uptime="$(uptime -p 2>/dev/null || true)"
  [[ -n "$_f_uptime" ]] || _f_uptime="$(awk '{printf "up %.0f minutes", $1/60}' /proc/uptime 2>/dev/null || printf 'not available')"
  _f_os="$(uname -s 2>/dev/null || printf 'unknown')"
  _f_kernel="$(uname -r 2>/dev/null || printf 'unknown')"
  _f_arch="$(uname -m 2>/dev/null || printf 'unknown')"
  _f_load="$(awk '{print $1 " / " $2 " / " $3}' /proc/loadavg 2>/dev/null || true)"
  [[ -n "$_f_load" ]] || _f_load="$(uptime 2>/dev/null | sed 's/.*load averages\{0,1\}: //')"
  [[ -n "$_f_load" ]] || _f_load='not available'

  if [[ -r /proc/meminfo ]]; then
    read -r _f_mem_total _f_mem_avail _f_swap_total _f_swap_free < <(
      awk '
        /^MemTotal:/ {t=$2}
        /^MemAvailable:/ {a=$2}
        /^MemFree:/ {f=$2}
        /^Buffers:/ {b=$2}
        /^Cached:/ {c=$2}
        /^SwapTotal:/ {st=$2}
        /^SwapFree:/ {sf=$2}
        END {if (!a) a=f+b+c; printf "%d %d %d %d\n",t,a,st,sf}' /proc/meminfo
    )
  elif command -v free >/dev/null 2>&1; then
    read -r _f_mem_total _f_mem_used _f_mem_avail < <(free -k 2>/dev/null | awk '/^Mem:/ {print $2,$3,$7; exit}')
    read -r _f_swap_total _f_swap_free < <(free -k 2>/dev/null | awk '/^Swap:/ {print $2,$4; exit}')
    _f_mem_total=$((_f_mem_total * 1)); _f_mem_avail=$((_f_mem_avail * 1)); _f_swap_total=$((_f_swap_total * 1)); _f_swap_free=$((_f_swap_free * 1))
  fi
  _f_mem_total=${_f_mem_total:-0}; _f_mem_avail=${_f_mem_avail:-0}; _f_swap_total=${_f_swap_total:-0}; _f_swap_free=${_f_swap_free:-0}
  ((_f_mem_total >= _f_mem_avail)) && _f_mem_used=$((_f_mem_total - _f_mem_avail)) || _f_mem_used=0
  _f_disk_line="$(df -Ph "$_f_target" 2>/dev/null | awk 'NR==2 {printf "%s used of %s total (%s full; %s available)", $3,$2,$5,$4}')"
  [[ -n "$_f_disk_line" ]] || _f_disk_line='filesystem information unavailable'
  _f_dir_size="$(du -sh "$_f_target" 2>/dev/null | awk 'NR==1 {print $1}')"
  [[ -n "$_f_dir_size" ]] || _f_dir_size='unavailable'

  printf '\n%s╭─ F · SYSTEM HEALTH ─────────────────────────────────────────────╮%s\n' "$_f_cyan" "$_f_reset"
  printf '  %s%-12s%s %s\n' "$_f_bold" 'Local time' "$_f_reset" "$_f_now"
  printf '  %s%-12s%s %s\n' "$_f_bold" 'Uptime' "$_f_reset" "$_f_uptime"
  printf '  %s%-12s%s %s %s(%s)%s\n' "$_f_bold" 'Operating OS' "$_f_reset" "$_f_os" "$_f_dim" "$_f_kernel" "$_f_reset"
  printf '  %s%-12s%s %s\n' "$_f_bold" 'Architecture' "$_f_reset" "$_f_arch"
  printf '  %s%-12s%s %s\n' "$_f_bold" 'CPU load' "$_f_reset" "$_f_load"
  if ((_f_mem_total > 0)); then
    printf '  %s%-12s%s %s used / %s total (%s available)\n' "$_f_bold" 'RAM' "$_f_reset" "$(__f_health_bytes "$_f_mem_used")" "$(__f_health_bytes "$_f_mem_total")" "$(__f_health_bytes "$_f_mem_avail")"
  else
    printf '  %s%-12s%s %s\n' "$_f_bold" 'RAM' "$_f_reset" 'not available'
  fi
  if ((_f_swap_total > 0)); then
    printf '  %s%-12s%s %s free / %s total\n' "$_f_bold" 'Swap' "$_f_reset" "$(__f_health_bytes "$_f_swap_free")" "$(__f_health_bytes "$_f_swap_total")"
  else
    printf '  %s%-12s%s %s\n' "$_f_bold" 'Swap' "$_f_reset" 'not configured or unavailable'
  fi
  printf '  %s%-12s%s %s\n' "$_f_bold" 'Folder size' "$_f_reset" "$_f_dir_size"
  printf '  %s%-12s%s %s\n' "$_f_bold" 'Disk space' "$_f_reset" "$_f_disk_line"
  printf '  %s%-12s%s %s\n' "$_f_bold" 'Current path' "$_f_reset" "$_f_target"
  printf '%s╰───────────────────────────────────────────────────────────────╯%s\n\n' "$_f_cyan" "$_f_reset"
}
