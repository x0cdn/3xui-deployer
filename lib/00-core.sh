
if [[ -t 1 ]]; then
  C_G=$'\e[32m'; C_Y=$'\e[33m'; C_R=$'\e[31m'; C_B=$'\e[1m'; C_D=$'\e[2m'; C_C=$'\e[36m'; C_N=$'\e[0m'
else
  C_G=; C_Y=; C_R=; C_B=; C_D=; C_C=; C_N=
fi

info() { printf '%s\n' "$*"; }
ok()   { printf '%s\n' "  ${C_G}✓${C_N} $*"; }
warn() { printf '%s\n' "  ${C_Y}!${C_N} $*" >&2; }
die()  { printf '%s\n' "${C_R}✗ $*${C_N}" >&2; exit 1; }
step() { printf '\n%s\n' "${C_B}${C_C}==> $*${C_N}"; }
dim()  { printf '%s\n' "${C_D}$*${C_N}"; }

DRY_RUN="${DRY_RUN:-no}"
run() {
  if [[ $DRY_RUN == yes ]]; then
    printf '%s\n' "  ${C_D}[dry-run] $*${C_N}" >&2
    return 0
  fi
  "$@"
}

rand_str() { openssl rand -base64 48 | tr -dc 'a-zA-Z0-9' | head -c "${1:-16}"; }
rand_hex() { openssl rand -hex "${1:-8}"; }
uuid()     { cat /proc/sys/kernel/random/uuid; }

valid_domain() {
  local name="$1"
  [[ ${#name} -ge 4 && ${#name} -le 253 ]] || return 1
  [[ $name =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$ ]]
}

load_env_keys() {
  local file="$1"; shift
  [[ -f $file ]] || return 0
  local -A allow=()
  local key
  for key in "$@"; do allow[$key]=1; done
  local line k v
  while IFS= read -r line || [[ -n $line ]]; do
    [[ $line =~ ^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]] || continue
    k="${BASH_REMATCH[1]}"
    v="${BASH_REMATCH[2]%$'\r'}"
    [[ -n ${allow[$k]:-} ]] || continue
    if [[ ${#v} -ge 2 && ( ${v:0:1} == '"' || ${v:0:1} == "'" ) && ${v: -1} == "${v:0:1}" ]]; then
      v="${v:1:${#v}-2}"
    fi
    printf -v "$k" '%s' "$v"
  done < "$file"
  return 0
}

port_busy() {
  local n="${2:-tcp}" flag
  [[ $n == udp ]] && flag=u || flag=t
  ss -H "-ln$flag" "sport = :$1" 2>/dev/null | grep -q .
}

free_port() {
  local p low="${1:-20000}"
  for _ in $(seq 1 100); do
    p=$(shuf -i "$low-65000" -n 1)
    port_busy "$p" tcp || { printf '%s' "$p"; return 0; }
  done
  die "Не нашёл свободный порт"
}

_tty_read() {
  local __qd_var="$1" __qd_prompt="$2"
  if [[ -t 0 ]]; then
    IFS= read -r -p "$__qd_prompt" "$__qd_var" || printf -v "$__qd_var" '%s' ''
  elif (: </dev/tty) 2>/dev/null; then
    IFS= read -r -p "$__qd_prompt" "$__qd_var" </dev/tty || printf -v "$__qd_var" '%s' ''
  else
    IFS= read -r "$__qd_var" || printf -v "$__qd_var" '%s' ''
  fi
}

ask() {
  local __qd_var="$1" __qd_prompt="$2" __qd_def="${3:-}" __qd_hint=""
  [[ -n $__qd_def ]] && __qd_hint=" ${C_D}[$__qd_def]${C_N}"
  _tty_read "$__qd_var" "${__qd_prompt}${__qd_hint}: "
  if [[ -z ${!__qd_var} ]]; then printf -v "$__qd_var" '%s' "$__qd_def"; fi
  return 0
}

ask_yesno() {
  local __def="${2:-yes}" __ans __hint="Y/n"
  [[ $__def == no ]] && __hint="y/N"
  ask __ans "$1" "$__def"
  case "${__ans,,}" in
    y|yes|д|да) return 0 ;;
    n|no|н|нет) return 1 ;;
    *) [[ $__def == yes ]] && return 0 || return 1 ;;
  esac
}

ask_choice() {
  local __var="$1" __prompt="$2" __arrname="$3" __def="${4:-1}"
  local -n __opts="$__arrname"
  local i __ans
  printf '\n%s\n' "${C_B}$__prompt${C_N}"
  for i in "${!__opts[@]}"; do
    printf '  %s%d%s) %s\n' "$C_C" "$((i + 1))" "$C_N" "${__opts[$i]}"
  done
  while true; do
    ask __ans "Выбор" "$__def"
    [[ $__ans =~ ^[0-9]+$ ]] && (( __ans >= 1 && __ans <= ${#__opts[@]} )) && break
    warn "Введите число от 1 до ${#__opts[@]}"
  done
  printf -v "$__var" '%s' "$(( __ans - 1 ))"
}

ask_multiselect() {
  local __var="$1" __prompt="$2" __arrname="$3" __def="${4:-}"
  local -n __opts="$__arrname"
  local i __ans __pick
  local -a __sel=()
  printf '\n%s\n' "${C_B}$__prompt${C_N}"
  for i in "${!__opts[@]}"; do
    local mark=" "
    [[ " $__def " == *" $i "* ]] && mark="*"
    printf '  [%s] %s%d%s) %s\n' "$mark" "$C_C" "$((i + 1))" "$C_N" "${__opts[$i]}"
  done
  dim "Номера через запятую (например 1,3,4). Enter – отмеченные [*]. 'all' – все, 'none' – ничего."
  ask __ans "Выбор" ""
  if [[ -z $__ans ]]; then
    read -ra __sel <<<"$__def"
  elif [[ ${__ans,,} == all ]]; then
    for i in "${!__opts[@]}"; do __sel+=("$i"); done
  elif [[ ${__ans,,} == none ]]; then
    __sel=()
  else
    IFS=',' read -ra __pick <<<"$__ans"
    for __p in "${__pick[@]}"; do
      __p="$(tr -d ' ' <<<"$__p")"
      [[ $__p =~ ^[0-9]+$ ]] && (( __p >= 1 && __p <= ${#__opts[@]} )) && __sel+=("$(( __p - 1 ))")
    done
  fi
  printf -v "$__var" '%s' "${__sel[*]}"
}

confirm() {
  ask_yesno "$1" "yes"
}