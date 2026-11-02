# shellcheck shell=bash

ISIPSAFE_ENV_KEYS=" ISIPSAFE_API_KEY ISIPSAFE_REPORT ISIPSAFE_BLOCKLIST ISIPSAFE_BLOCKLIST_CONFIDENCE ISIPSAFE_BLOCKLIST_DAYS ISIPSAFE_BLOCKLIST_LIMIT ISIPSAFE_BLOCKLIST_EXCEPT_COUNTRIES ISIPSAFE_ALLOW_IPS ISIPSAFE_BASE_URL "

isipsafe_load_env() {
  local file="$1" key value
  [ -r "$file" ] || return 0
  while IFS='=' read -r key value || [ -n "$key" ]; do
    key="${key//[[:space:]]/}"
    case "$ISIPSAFE_ENV_KEYS" in
      *" $key "*) ;;
      *) continue ;;
    esac
    value="${value%$'\r'}"
    value="${value#[\"\']}"
    value="${value%[\"\']}"
    if [ -z "${!key:-}" ]; then
      export "$key=$value"
    fi
  done <"$file"
}

isipsafe_enabled() {
  case "${1:-yes}" in
    no | NO | false | 0 | off) return 1 ;;
    *) return 0 ;;
  esac
}
