#!/usr/bin/env bash
set -euo pipefail

# =========================================================
# INSTALATLS — CONFIGURAÇÃO INICIAL / CAMINHOS / CONSTANTES
# =========================================================

PDV_OUT_DB="${PDV_OUT_DB:-/opt/checkout/pdv_out.db}"
DB_IN="${DB_IN:-/opt/checkout/pdv_in.db}"
CONFITLS_INI="${CONFITLS_INI:-/opt/checkout/CONFITLS.INI}"
CONFITLS_BKP_INI="${CONFITLS_BKP_INI:-/opt/checkout/CONFITLS_BKP.INI}"
readonly SERVICE_NAME="clisitef-socket.service"
readonly MYSQL_TABLE="pdvctr"
readonly MYSQL_COL_CNPJ="ctremprcgc"
readonly MYSQL_COL_IDLOJA_TEF="ctrcodemptef"
readonly CNPJ_SH_FIX="03082643000110"
readonly TLS_TABLE="pdvtls"
readonly TLS_COL_CAIXA="tlscaixa"
readonly TLS_COL_TOKEN="tlstoken"
readonly HOST_DEFAULT="127.0.0.1"
readonly PORT_DEFAULT="8765"
readonly OPERADOR="999 HIPCOM"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
umask 077

# ---------- proteção contra execução simultânea ----------
readonly LOCK_FILE="${SCRIPT_DIR}/.InstalaTLS.lock"
exec 9>"$LOCK_FILE" 2>/dev/null || {
  printf 'ERRO FATAL: não foi possível criar arquivo de lock: %s\n' "$LOCK_FILE" >&2
  exit 1
}
if ! flock -n 9 2>/dev/null; then
  printf 'ERRO: outra instância do InstalaTLS já está em execução (%s). Aguarde o término antes de reiniciar.\n' "$LOCK_FILE" >&2
  exec 9>&-
  exit 1
fi
# O lock é liberado automaticamente quando o FD 9 é fechado (exit, exec 9>&-, ou fim do processo).
# ---------------------------------------------------------

AUDIT_TMP="$(mktemp "${SCRIPT_DIR}/.InstalaTLS.audit.XXXXXX" 2>/dev/null)" || {
  printf 'ERRO FATAL: mktemp falhou (disco cheio ou /tmp sem escrita?)\n' >&2
  exit 1
}
chmod 600 "$AUDIT_TMP" 2>/dev/null || true
# Register an early minimal EXIT trap so AUDIT_TMP is always removed even if
# the script aborts before the full cleanup() trap is set up below.
trap 'rm -f "${AUDIT_TMP:-}" 2>/dev/null || true' EXIT
# Block signals until the real traps are registered below (after die/cleanup/on_signal
# are defined).  This prevents a signal arriving before the full INT/TERM trap is in
# place from killing the script without cleanup.
trap '' INT TERM
LAST_UI_LOOP_PCT=""
UI_TEST_LABEL="Testando Comunicação"
ORIG_SQLITE_FLAG=""
ORIG_TOKEN_EXISTS=0
ORIG_TOKEN_VALUE=""
ORIG_CONFITLS_EXISTS=0
ORIG_CONFITLS_BACKUP=""
ORIG_CTRL_EXISTS=0
ORIG_CTRL_IS_DIR=0
ORIG_CTRL_BACKUP=""
ROLLBACK_ENABLED=0
SKIP_ROLLBACK=0
LAST_SOCKET_MSG=""
LAST_USEFUL_SOCKET_MSG=""
UI_STEP_MIN_SECONDS="${UI_STEP_MIN_SECONDS:-0}"
ZENITY_ENTRY_WIDTH=420
ZENITY_ENTRY_HEIGHT=220
GUI_DETECTED=0
SQLITE_BUSY_TIMEOUT_MS=3000
SQLITE_RETRY_COUNT=3
SQLITE_RETRY_SLEEP=1
DEBUG_LOG="${DEBUG_LOG:-0}"
TOKEN_ATUAL_BANCO=""
MODO_TESTE_TOKEN_ATUAL=0
MAX_LOOPS=160
SLEEP_SEC=0.25
STATE_HEARTBEAT_EVERY=20
GUI_USER=""
GUI_HOME=""
GUI_DISPLAY=""
GUI_XAUTH=""
UI_OK=0
UI_FD=""
ZENITY_PID=""
MYSQL_HOST=""
MYSQL_PORT=""
MYSQL_PASS=""
IP_BD=""
NOME_BD=""
USUARIO_BD=""
SENHA_B64=""
NUM_CAIXA=""
CNPJ_LOJA=""
IDLOJA_TEF=""
LOJA_EXIBICAO=""
TOKEN_TLS=""
TEST_RESULT_MSG=""
LAST_STATE_SNAPSHOT=""
FINAL_MODE_TEST_OK=0
FINAL_MODE_TEST_MSG=""
HOST=""
PORT=""
IDTERM=""
IDLOJA=""
PARMS=""
DATAFISC=""
HORAFISC=""
CUPOM=""
TMP_INITIAL_INFO_FILE=""

# =========================================================
# HELPERS GERAIS / DATA / LOG / FORMATAÇÃO
# =========================================================

ts(){ date '+%F %T'; }

log(){
  # Guard against writing to a nonexistent or empty AUDIT_TMP (e.g., if the
  # file was already removed by cleanup or if mktemp failed and we fell back).
  [[ -n "${AUDIT_TMP:-}" ]] && printf '[%s] %s\n' "$(ts)" "$*" >>"$AUDIT_TMP" || true
}

debug_log(){
  # (( expr )) returns exit code 1 when expr == 0, which would cause set -e to
  # abort the script if debug_log is ever called in a plain statement context.
  # The explicit return 0 makes the function always succeed regardless of
  # DEBUG_LOG value, matching the caller's expectation that a no-op log call
  # cannot fail.
  (( DEBUG_LOG == 1 )) && log "$@"
  return 0
}

log_sep(){
  log "----------------------------------------------------------------"
}

log_kv(){
  local k="$1" v="${2:-}"
  log "$k=$v"
}

log_kv_masked(){
  local k="$1" v="${2:-}"
  log_kv "$k" "$(mask_secret "$v")"
}

trim(){ sed 's/^[[:space:]]*//;s/[[:space:]]*$//'; }

decode_b64(){
  local v="$1" out rc
  out="$(printf '%s' "$v" | base64 -d 2>/dev/null)"
  rc=$?
  if (( rc != 0 )); then
    # base64 -d falhou: dado corrompido no banco. Não fazer fallback silencioso —
    # retornar vazio para que a validação downstream (MYSQL_PASS vazio) aborte com
    # mensagem de erro clara em vez de tentar autenticar com dado inválido.
    log "WARN: decode_b64 falhou (rc=${rc}); dado base64 inválido na coluna senha"
    printf ''
    return 1
  fi
  printf '%s' "$out"
}

mysql_escape(){
  printf '%s' "$1" | sed "s/'/''/g"
}

sqlite_has_table() {
  local db="$1" table="$2" out rc
  out="$(sqlite3 "$db" ".timeout ${SQLITE_BUSY_TIMEOUT_MS}" \
    "SELECT 1 FROM sqlite_master WHERE type='table' AND name='${table}' LIMIT 1;" \
    2>>"$AUDIT_TMP")"
  rc=$?
  (( rc == 0 )) && [[ "$out" == "1" ]]
}

pad_left() {
  local s="$1" w="$2"
  [[ "$s" =~ ^[0-9]+$ ]] || return 1
  printf "%0${w}d" "$((10#$s))"
}

normalize_socket_message(){
  local msg="${1:-}"
  msg="$(printf '%s' "$msg" | tr -d '\r' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  printf '%s\n' "$msg"
}

mask_secret(){
  local v="${1:-}"
  if [[ -z "$v" ]] || (( ${#v} <= 4 )); then
    printf '%s' "****"
  else
    printf '%s' "${v:0:2}****${v: -2}"
  fi
}

extract_int() { sed -n 's/.*"'"$1"'":[^0-9-]*\(-\{0,1\}[0-9]\+\).*/\1/p'; }
extract_str() { sed -n 's/.*"'"$1"'":"\([^"]*\)".*/\1/p'; }

cleanup_sensitive_artifacts(){
  if [[ -n "${ORIG_CONFITLS_BACKUP:-}" && -f "${ORIG_CONFITLS_BACKUP:-}" ]]; then
    rm -f "${ORIG_CONFITLS_BACKUP}" 2>/dev/null || true
  fi

  if [[ -n "${ORIG_CTRL_BACKUP:-}" && -d "${ORIG_CTRL_BACKUP:-}" ]]; then
    rm -rf "${ORIG_CTRL_BACKUP}" 2>/dev/null || true
  fi
}

# =========================================================
# LOG DE ETAPAS / CONTROLE DE EXECUÇÃO
# =========================================================

step_enter(){
  log_sep
  log "ENTER: $1"
}

step_ok(){
  log "OK: $1"
}

step_fail(){
  log "FAIL: $1"
}

log_socket_call(){
  local tag="$1"
  local payload="$2"
  local response="$3"

  log "SOCKET_CALL_${tag}_PAYLOAD: $payload"
  log "SOCKET_CALL_${tag}_RESPONSE: $response"
}

state_maybe_log() {
  local loop="$1" res="$2" cmd="$3" tipo="$4" tmin="$5" tmax="$6"
  local cur="res=$res cmd=$cmd tipo=$tipo tmin=$tmin tmax=$tmax"

  if [[ "${cur:-}" != "${LAST_STATE_SNAPSHOT:-}" ]]; then
    LAST_STATE_SNAPSHOT="$cur"
    log "SOCKET_STATE: ($loop) $cur"
  elif (( STATE_HEARTBEAT_EVERY > 0 )) && (( loop % STATE_HEARTBEAT_EVERY == 0 )); then
    log "SOCKET_STATE: ($loop) $cur (heartbeat)"
  fi
}

# =========================================================
# BOOTSTRAP DE DEPENDÊNCIAS
# =========================================================

bootstrap_dependencies(){
  local missing=0
  local use_gauge=0
  local fifo=""
  local gauge_pid=""

  command -v zenity >/dev/null 2>&1 || missing=1
  command -v sqlite3 >/dev/null 2>&1 || missing=1
  command -v mysql  >/dev/null 2>&1 || missing=1

  # (( missing == 0 )) would return exit code 1 when missing=1 (i.e. some dep
  # is absent), and set -e would abort the script before the install block
  # runs.  Use an explicit if/return instead.
  if (( missing == 0 )); then
    return 0
  fi

  command -v apt-get >/dev/null 2>&1 || {
    printf 'ERRO: apt-get não encontrado.\n' >&2
    exit 1
  }

  export DEBIAN_FRONTEND=noninteractive
  export NEWT_COLORS='
root=white,black
roottext=white,black
window=blue,gray
border=blue,black
title=blue,gray
textbox=blue,gray
label=blue,gray
button=black,cyan
actbutton=black,cyan
emptyscale=gray,black
fullscale=cyan,black
'

  bootstrap_progress_reader() {
    local pct=0

    while IFS= read -r line; do
      case "$line" in
        START)            pct=5   ;;
        CHECK_APT)        pct=12  ;;
        UPDATE)           pct=30  ;;
        RESOLVE_PACKAGES) pct=45  ;;
        INSTALL_ZENITY)   pct=58  ;;
        INSTALL_SQLITE)   pct=68  ;;
        INSTALL_MYSQL)    pct=78  ;;
        VALIDATE)         pct=92  ;;
        DONE)             pct=100 ;;
        '') continue ;;
        *)
          if [[ "$line" =~ ^[0-9]+$ ]]; then
            pct="$line"
          else
            continue
          fi
          ;;
      esac

      echo "$pct"
    done
  }

  run_with_smooth_progress() {
    local fifo_path="$1"
    local start_pct="$2"
    local end_pct="$3"
    shift 3

    "$@" >/dev/null 2>&1 &
    local cmd_pid=$!
    local pct="$start_pct"

    while kill -0 "$cmd_pid" 2>/dev/null; do
      printf '%s\n' "$pct" > "$fifo_path"
      sleep 0.4
      if (( pct < end_pct - 1 )); then
        ((pct++))
      fi
    done

    local rc
    wait "$cmd_pid"
    rc=$?

    printf '%s\n' "$end_pct" > "$fifo_path"
    return "$rc"
  }

  if command -v whiptail >/dev/null 2>&1; then
    use_gauge=1
    # mktemp -u followed by mkfifo is a TOCTOU race; use a mktemp-generated
    # directory to hold the FIFO so the name is unguessable and pre-created.
    local _fifo_dir
    _fifo_dir="$(mktemp -d 2>/dev/null)" || { use_gauge=0; _fifo_dir=""; }
    if [[ -n "$_fifo_dir" ]]; then
      fifo="${_fifo_dir}/progress.fifo"
      mkfifo "$fifo" || { use_gauge=0; rm -rf "$_fifo_dir" 2>/dev/null || true; _fifo_dir=""; }
    fi

    bootstrap_progress_reader < "$fifo" | whiptail \
      --title "TLS" \
      --gauge "          Por favor aguarde, preparando o ambiente para a primeira execucao." \
      18 90 0 &
    gauge_pid=$!
  else
    printf '\nPor favor aguarde, preparando o ambiente para a primeira execucao.\n'
  fi

  if (( use_gauge == 1 )); then
    {
      echo START
      sleep 1

      echo CHECK_APT
      command -v apt-get >/dev/null 2>&1
      sleep 1

      echo UPDATE
      run_with_smooth_progress "$fifo" 30 42 apt-get update -y || exit 1

      echo RESOLVE_PACKAGES
      run_with_smooth_progress "$fifo" 45 54 apt-get install -y --simulate zenity sqlite3 mysql-client || exit 1

      echo INSTALL_ZENITY
      run_with_smooth_progress "$fifo" 58 66 apt-get install -y zenity || exit 1

      echo INSTALL_SQLITE
      run_with_smooth_progress "$fifo" 68 76 apt-get install -y sqlite3 || exit 1

      echo INSTALL_MYSQL
      run_with_smooth_progress "$fifo" 78 88 apt-get install -y mysql-client || exit 1

      echo VALIDATE
      command -v zenity  >/dev/null 2>&1
      command -v sqlite3 >/dev/null 2>&1
      command -v mysql   >/dev/null 2>&1
      sleep 1

      echo DONE
      sleep 1
    } > "$fifo"
    local _bs_rc
    _bs_rc=$?

    [[ -n "$gauge_pid" ]] && wait "$gauge_pid" 2>/dev/null || true
    rm -f "$fifo" 2>/dev/null || true
    # Remove the temp directory created to avoid the mktemp -u TOCTOU race.
    [[ -n "${_fifo_dir:-}" ]] && rm -rf "$_fifo_dir" 2>/dev/null || true

    if (( _bs_rc != 0 )); then
      printf 'ERRO: falha durante instalação de dependências (rc=%d).\n' "$_bs_rc" >&2
      exit 1
    fi
  else
    apt-get update -y >/dev/null 2>&1 || exit 1
    apt-get install -y zenity sqlite3 mysql-client >/dev/null 2>&1 || exit 1
  fi

  command -v zenity  >/dev/null 2>&1 || { printf 'ERRO: zenity não instalado.\n' >&2; exit 1; }
  command -v sqlite3 >/dev/null 2>&1 || { printf 'ERRO: sqlite3 não instalado.\n' >&2; exit 1; }
  command -v mysql   >/dev/null 2>&1 || { printf 'ERRO: mysql-client não instalado.\n' >&2; exit 1; }
}

need_cmd(){
  step_enter "Verificando dependência: $1"
  if command -v "$1" >/dev/null 2>&1; then
    step_ok "Dependência encontrada: $1 -> $(command -v "$1")"
  else
    step_fail "Dependência ausente: $1"
    die "comando ausente: $1"
  fi
}

# =========================================================
# GUI / ZENITY / PROGRESSO
# =========================================================

detect_gui_user() {
  if (( GUI_DETECTED == 1 )); then
    return 0
  fi

  step_enter "Detectando usuário gráfico"

  local u="" home="" disp="" xauth="" uid=""

  if [[ -n "${SUDO_USER:-}" ]]; then
    u="$SUDO_USER"
    log "GUI: usando SUDO_USER=$u"
  else
    u="$(who 2>/dev/null | awk '$2 ~ /^:[0-9]+$/ {print $1; exit}')"
    log "GUI: usuário vindo do who='$u'"
  fi
  [[ -n "$u" ]] || u="pdv"

  home="$(getent passwd "$u" 2>/dev/null | cut -d: -f6 || true)"
  [[ -n "$home" ]] || home="/home/$u"

  disp="${DISPLAY:-}"
  if [[ -z "$disp" ]]; then
    disp="$(who 2>/dev/null | awk '$2 ~ /^:[0-9]+$/ {print $2; exit}')"
    log "GUI: DISPLAY vindo do who='$disp'"
  fi
  [[ -n "$disp" ]] || disp=":0"

  xauth="${XAUTHORITY:-}"
  if [[ -z "$xauth" ]]; then
    if [[ -f "$home/.Xauthority" ]]; then
      xauth="$home/.Xauthority"
    else
      uid="$(id -u "$u" 2>/dev/null || true)"
      if [[ -n "$uid" && -f "/run/user/$uid/gdm/Xauthority" ]]; then
        xauth="/run/user/$uid/gdm/Xauthority"
      elif [[ -n "$uid" ]]; then
        xauth="$(find "/run/user/$uid" -name Xauthority 2>/dev/null | head -n1 || true)"
        [[ -n "$xauth" ]] || xauth="$home/.Xauthority"
      else
        xauth="$home/.Xauthority"
      fi
    fi
  fi

  GUI_USER="$u"
  GUI_HOME="$home"
  GUI_DISPLAY="$disp"
  GUI_XAUTH="$xauth"
  GUI_DETECTED=1

  log_kv "GUI_USER" "$GUI_USER"
  log_kv "GUI_HOME" "$GUI_HOME"
  log_kv "GUI_DISPLAY" "$GUI_DISPLAY"
  log_kv "GUI_XAUTH" "$GUI_XAUTH"

  step_ok "Detectando usuário gráfico"
  
}

run_zenity() {
  detect_gui_user
  [[ -f "$GUI_XAUTH" ]] || return 1

  debug_log "ZENITY: executando como usuário '$GUI_USER' no DISPLAY '$GUI_DISPLAY'"
  sudo -u "$GUI_USER" env \
    DISPLAY="$GUI_DISPLAY" \
    XAUTHORITY="$GUI_XAUTH" \
    zenity "$@" 2>>"$AUDIT_TMP"
}

check_gui_requirements(){
  step_enter "Validando requisitos de GUI"

  detect_gui_user
  command -v zenity >/dev/null 2>&1 || die "zenity não encontrado"
  [[ -n "$GUI_DISPLAY" ]] || die "DISPLAY indisponível"
  [[ -f "$GUI_XAUTH" ]] || die "XAUTHORITY não encontrado: $GUI_XAUTH"

  step_ok "Validando requisitos de GUI"
}

ui_send(){
  (( UI_OK == 1 )) || return 0
  echo "# $1" >&"$UI_FD" 2>>"$AUDIT_TMP" || true
  log "UI_MSG=$1"
}

ui_progress(){
  local pct="$1"
  local msg="${2:-}"

  (( UI_OK == 1 )) || return 0

  [[ "$pct" =~ ^[0-9]+$ ]] || pct=0
  # Use if/assignment instead of (( expr )) && pct=N to avoid set -e aborting
  # the script when the condition is false (exit code 1 from (( ))).
  if (( pct < 0 )); then pct=0; fi
  if (( pct > 100 )); then pct=100; fi

  if [[ -n "$msg" ]]; then
    {
      echo "$pct"
      echo "# $msg"
    } >&"$UI_FD" 2>>"$AUDIT_TMP" || true
    log "UI_PROGRESS=${pct}% MSG=$msg"
  else
    echo "$pct" >&"$UI_FD" 2>>"$AUDIT_TMP" || true
    log "UI_PROGRESS=${pct}%"
  fi
}

ui_start(){
  step_enter "Iniciando barra de progresso"

  command -v zenity >/dev/null || return 0
  detect_gui_user
  [[ -f "$GUI_XAUTH" ]] || return 0

  # Reset coproc-related globals before launch so stale values from a previous
  # (hypothetical) call do not mislead the liveness checks below.
  ZENITY_PID=""
  UI_FD=""
  UI_OK=0

  coproc ZENITY {
    exec sudo -u "$GUI_USER" env \
      DISPLAY="$GUI_DISPLAY" \
      XAUTHORITY="$GUI_XAUTH" \
      zenity --progress \
        --title="TLS" \
        --text="${UI_TEST_LABEL:-Testando Comunicação}" \
        --percentage=0 \
        --width="$ZENITY_ENTRY_WIDTH" \
        --height="$ZENITY_ENTRY_HEIGHT"
  }
  # Bash sets ZENITY_PID from the coproc declaration; capture it defensively.
  # If the coproc failed to start (e.g. sudo/zenity not found), the variable
  # may be unset; the kill -0 check below will handle that case.
  ZENITY_PID="${ZENITY_PID:-}"

  sleep 0.15
  if [[ -n "${ZENITY_PID:-}" ]] && kill -0 "${ZENITY_PID}" 2>/dev/null; then
    # Also verify the write FD is actually open before trusting UI_OK=1.
    if [[ -n "${ZENITY[1]:-}" ]]; then
      UI_OK=1
      UI_FD="${ZENITY[1]}"
      ui_progress 0 "${UI_TEST_LABEL:-Testando Comunicação}"
      step_ok "Iniciando barra de progresso"
    else
      UI_OK=0
      log "WARN: coproc PID vivo mas FD de escrita não disponível; fluxo seguirá sem barra"
    fi
  else
    UI_OK=0
    log "WARN: barra de progresso não foi iniciada (PID=${ZENITY_PID:-<vazio>}); fluxo seguirá sem barra"
  fi
}

ui_finish_progress(){
  (( UI_OK == 1 )) || return 0
  ui_progress 99 "${UI_TEST_LABEL:-Testando Comunicação}"
  sleep 0.10
}

ui_finish_as_final_screen(){
  local msg="$1"

  (( UI_OK == 1 )) || return 0

  # Se o zenity já encerrou (ex.: usuário fechou a janela após o teste mas antes
  # da tela final), exibe um diálogo --info separado para que o operador
  # sempre veja o resultado final.
  if [[ -n "${ZENITY_PID:-}" ]] && ! kill -0 "${ZENITY_PID}" 2>/dev/null; then
    log "UI_FINAL_SCREEN_FALLBACK: zenity encerrado prematuramente; exibindo diálogo separado"
    if [[ -n "${UI_FD:-}" ]]; then exec {UI_FD}>&- 2>/dev/null || true; UI_FD=""; fi
    UI_OK=0
    ZENITY_PID=""
    set +e
    run_zenity --info --title="TLS" --text="$msg" --ok-label="OK" \
      --width="$ZENITY_ENTRY_WIDTH" --height="$ZENITY_ENTRY_HEIGHT" >/dev/null 2>/dev/null
    set -e
    log "UI_FINAL_SCREEN=$msg"
    return 0
  fi

  {
    echo "100"
    echo "# $msg"
  } >&"$UI_FD" 2>>"$AUDIT_TMP" || true

  log "UI_FINAL_SCREEN=$msg"

  if [[ -n "${UI_FD:-}" ]]; then
    exec {UI_FD}>&- 2>/dev/null || true
    UI_FD=""
  fi

  [[ -n "${ZENITY_PID:-}" ]] && wait "$ZENITY_PID" 2>/dev/null || true

  UI_OK=0
  ZENITY_PID=""
}

ui_entry(){
  detect_gui_user
  [[ -f "$GUI_XAUTH" ]] || return 10

  log "UI_ENTRY_TEXT=$1"

  run_zenity \
    --entry \
    --title="TLS" \
    --text="$1" \
    --entry-text="" \
    --width="$ZENITY_ENTRY_WIDTH" \
    --height="$ZENITY_ENTRY_HEIGHT"
}

ui_step_min(){
  local msg="$1"; shift
  local t0 rc dt

  t0="$(date +%s)"

  ui_send "$msg"
  log "INICIO: $msg"

  set +e
  "$@" >>"$AUDIT_TMP" 2>&1
  rc=$?
  set -e

  dt=$(( $(date +%s) - t0 ))
  # Use if to avoid (( expr )) && cmd returning exit code 1 (from set -e)
  # when the condition is false — which is the common case (dt >= min seconds).
  if (( dt < UI_STEP_MIN_SECONDS )); then sleep $((UI_STEP_MIN_SECONDS - dt)); fi

  if (( rc == 0 )); then
    log "OK: $msg"
  else
    log "FALHA: $msg (rc=$rc)"
  fi

  return "$rc"
}

ui_progress_test_loop(){
  local loop="$1"
  local base="${2:-10}"
  local max_pct="${3:-90}"

  (( UI_OK == 1 )) || return 0
  [[ "$loop" =~ ^[0-9]+$ ]] || return 0
  [[ "$MAX_LOOPS" =~ ^[0-9]+$ ]] || return 0
  (( MAX_LOOPS > 0 )) || return 0

  # Progressão ease-out quadrática: f(t) = 2t − t²  (t = loop/MAX_LOOPS)
  # Move rápido no início (maioria dos testes termina cedo) e desacelera
  # perto do max_pct, evitando a sensação de "trava" próxima ao fim.
  # Fórmula inteira: base + range*(2*loop*MAX_LOOPS − loop²) / MAX_LOOPS²
  # Overflow seguro para MAX_LOOPS ≤ 1000 e range ≤ 100.
  local pct range
  range=$(( max_pct - base ))
  pct=$(( base + range * (2 * loop * MAX_LOOPS - loop * loop) / (MAX_LOOPS * MAX_LOOPS) ))

  # Use if/assignment to avoid (( expr )) && var=N causing set -e to abort
  # when the condition is false (exit code 1 from (( ))).
  if (( pct < base )); then pct="$base"; fi
  if (( pct > max_pct )); then pct="$max_pct"; fi

  if [[ "${LAST_UI_LOOP_PCT:-}" != "$pct" ]]; then
    LAST_UI_LOOP_PCT="$pct"
    ui_progress "$pct" "${UI_TEST_LABEL:-Testando Comunicação}"
  fi
}

ui_end_fail(){
  step_enter "Finalização com falha"
  ui_send "$1"
  sleep 1
  step_fail "Finalização com falha"
}

ui_cancel_and_exit(){
  log "INFO: operação cancelada pelo usuário"

  run_rollback

  if (( UI_OK == 1 )); then
    ui_send "Processo cancelado. Ambiente restaurado."
    sleep 1
  fi

  # Close the progress FD before killing zenity to avoid a broken-pipe signal.
  if [[ -n "${UI_FD:-}" ]]; then
    exec {UI_FD}>&- 2>/dev/null || true
    UI_FD=""
  fi
  [[ -n "${ZENITY_PID:-}" ]] && { kill "$ZENITY_PID" 2>/dev/null || true; ZENITY_PID=""; }
  ui_show_final_actions
  ui_ask_extract_log
  exit 0
}

# _handle_user_abort
# Chamado quando o usuário clica em "Cancelar/Abortar" na barra de progresso
# durante o loop de teste. A janela zenity já está morta; fecha o FD quebrado,
# executa rollback se aplicável, exibe diálogo informativo e encerra o script.
_handle_user_abort(){
  log "ABORTO: cancelamento solicitado pelo usuário via botão de progresso"

  # Fecha FD da barra (já está quebrado — zenity encerrou).
  if [[ -n "${UI_FD:-}" ]]; then
    exec {UI_FD}>&- 2>/dev/null || true
    UI_FD=""
  fi
  UI_OK=0
  ZENITY_PID=""

  # Rollback apenas se o snapshot foi capturado e o rollback não foi suprimido.
  if (( ROLLBACK_ENABLED == 1 && SKIP_ROLLBACK == 0 )); then
    log "ABORTO: executando rollback"
    run_rollback || true
  else
    log "ABORTO: rollback ignorado (ROLLBACK_ENABLED=${ROLLBACK_ENABLED} SKIP_ROLLBACK=${SKIP_ROLLBACK})"
  fi

  # Exibe diálogo standalone (barra já fechada).
  set +e
  run_zenity \
    --info \
    --title="TLS" \
    --text="Operação cancelada pelo usuário." \
    --ok-label="OK" \
    --width="$ZENITY_ENTRY_WIDTH" \
    --height="160" >/dev/null 2>/dev/null
  set -e

  ui_show_final_actions
  ui_ask_extract_log

  exit 0
}

ui_show_initial_info(){
  step_enter "Exibindo identificação inicial do PDV"

  detect_gui_user
  [[ -f "$GUI_XAUTH" ]] || return 10

  local rc tmp_pdv_info

  tmp_pdv_info="$(mktemp "${SCRIPT_DIR}/.pdv_info.XXXXXX" 2>/dev/null)" || {
    step_fail "Falha ao criar arquivo temporário para identificação PDV"
    return 1
  }
  TMP_INITIAL_INFO_FILE="$tmp_pdv_info"

  cat > "$tmp_pdv_info" <<EOF
Loja: ${LOJA_EXIBICAO:- }
Caixa: ${NUM_CAIXA:-<vazio>}
Número na Fiserv: ${IDLOJA_TEF:-<vazio>}

CNPJ:
${CNPJ_LOJA:-<vazio>}
EOF

  chmod 644 "$tmp_pdv_info" 2>/dev/null || true

  echo "DEBUG_UI loja='${LOJA_EXIBICAO:-<vazia>}' caixa='${NUM_CAIXA:-<vazio>}' idloja='${IDLOJA_TEF:-<vazio>}' cnpj='${CNPJ_LOJA:-<vazio>}'" >>"$AUDIT_TMP"
  echo "DEBUG_UI arquivo=$tmp_pdv_info" >>"$AUDIT_TMP"
  echo "DEBUG_UI tamanho=$(wc -c < "$tmp_pdv_info" 2>/dev/null || echo 0)" >>"$AUDIT_TMP"
  echo "DEBUG_UI conteudo_inicio" >>"$AUDIT_TMP"
  sed -n '1,20p' "$tmp_pdv_info" >>"$AUDIT_TMP" 2>/dev/null || true
  echo "DEBUG_UI conteudo_fim" >>"$AUDIT_TMP"

  set +e
  run_zenity \
    --text-info \
    --title="Identificação do PDV" \
    --filename="$tmp_pdv_info" \
    --ok-label="Continuar" \
    --cancel-label="Cancelar" \
    --width="$ZENITY_ENTRY_WIDTH" \
    --height="$ZENITY_ENTRY_HEIGHT" >/dev/null
  rc=$?
  set -e

  rm -f "$tmp_pdv_info" 2>/dev/null || true
  TMP_INITIAL_INFO_FILE=""

  log_kv "UI_IDENTIFICACAO_RC" "$rc"

  if (( rc == 10 )); then
    log "ERRO: interface gráfica indisponível para identificação do PDV"
    return 1
  fi

  if (( rc != 0 )); then
    ui_cancel_and_exit
  fi

  step_ok "Exibindo identificação inicial do PDV"
  return 0
}

ui_choose_existing_or_new_token(){
  step_enter "Escolhendo entre testar token atual ou cadastrar novo"

  detect_gui_user
  [[ -f "$GUI_XAUTH" ]] || return 10

  local escolha rc
  local msg="Token atual: ${TOKEN_ATUAL_BANCO}"

  set +e
  escolha="$(
    run_zenity \
      --list \
      --title="TLS" \
      --text="$msg" \
      --column="Opção" \
      "Cadastrar novo token" \
      "Testar token atual" \
      --hide-header \
      --width="$ZENITY_ENTRY_WIDTH" \
      --height="$ZENITY_ENTRY_HEIGHT"
  )"
  rc=$?
  set -e

  log_kv "TOKEN_ESCOLHA_RC" "$rc"
  log_kv "TOKEN_ESCOLHA_VALOR" "$escolha"

  if (( rc == 10 )); then
    log "ERRO: interface gráfica indisponível para escolha do token"
    return 1
  fi

  if (( rc != 0 )); then
    ui_cancel_and_exit
  fi

  case "$escolha" in
    "Cadastrar novo token")
      log "ESCOLHA_TOKEN=cadastrar_novo"
      MODO_TESTE_TOKEN_ATUAL=0
      TOKEN_TLS=""
      ;;
    "Testar token atual")
      TOKEN_TLS="$TOKEN_ATUAL_BANCO"
      MODO_TESTE_TOKEN_ATUAL=1
      log "ESCOLHA_TOKEN=usar_token_atual"
      log_kv_masked "TOKEN_TLS_MASKED" "$TOKEN_TLS"
      ;;
    *)
      ui_cancel_and_exit
      ;;
  esac

  step_ok "Escolhendo entre testar token atual ou cadastrar novo"
  return 0
}

step_ask_token(){
  step_enter "Solicitando token TLS ao usuário"

  local out rc

  while true; do
    set +e
    out="$(ui_entry "Cole o Token TLS (0000-0000-0000-0000):")"
    rc=$?
    set -e

    log_kv "TOKEN_DIALOG_RC" "$rc"

    if (( rc == 10 )); then
      step_fail "Interface gráfica indisponível para token"
      return 1
    fi

    if (( rc != 0 )); then
      log "USUARIO: cancelou entrada do token"
      ui_cancel_and_exit
    fi

    TOKEN_TLS="$(printf '%s' "$out" | tr -d '[:space:]')"
    log_kv_masked "TOKEN_TLS_MASKED" "$TOKEN_TLS"

    if [[ "$TOKEN_TLS" =~ ^[0-9]{4}(-[0-9]{4}){3}$ ]]; then
      step_ok "Solicitando token TLS ao usuário"
      return 0
    fi

    log_kv_masked "TOKEN_INVALIDO_FORMATO_MASKED" "$TOKEN_TLS"

    set +e
    run_zenity \
      --error \
      --title="TLS" \
      --text="Token no formato inválido, tente novamente." \
      --ok-label="OK" \
      --width="$ZENITY_ENTRY_WIDTH" \
      --height="160" >/dev/null
    rc=$?
    set -e

    log_kv "TOKEN_INVALIDO_ALERTA_RC" "$rc"

    if (( rc == 10 )); then
      step_fail "Interface gráfica indisponível para alerta de token inválido"
      return 1
    fi
  done
}

ui_ask_return_to_gsurf(){
  step_enter "Perguntando se deseja retornar para GSurf"

  detect_gui_user
  [[ -f "$GUI_XAUTH" ]] || return 10

  local rc
  local status_text="${1:-Resultado final}"

  set +e
  run_zenity \
    --question \
    --title="TLS" \
    --text="${status_text}\n\nDeseja retornar o método de transação para GSurf?" \
    --ok-label="Sim" \
    --cancel-label="Não" \
    --width="$ZENITY_ENTRY_WIDTH" \
    --height="$ZENITY_ENTRY_HEIGHT"
  rc=$?
  set -e

  log_kv "RETORNO_GSURF_RC" "$rc"

  if (( rc == 10 )); then
    log "ERRO: interface gráfica indisponível para retorno GSurf"
    return 1
  fi

  if (( rc == 0 )); then
    log "RETORNO_GSURF=sim"
    step_ok "Perguntando se deseja retornar para GSurf"
    return 0
  fi

  log "RETORNO_GSURF=nao"
  step_ok "Perguntando se deseja retornar para GSurf"
  return 1
}

ui_ask_extract_log(){
  if [[ -n "${AUDIT_TMP:-}" && -f "${AUDIT_TMP:-}" ]]; then
    rm -f "$AUDIT_TMP" 2>/dev/null || true
  fi
  return 0
}

ui_show_final_actions(){
  if [[ -n "${AUDIT_TMP:-}" && -f "${AUDIT_TMP:-}" ]]; then
    rm -f "$AUDIT_TMP" 2>/dev/null || true
  fi
  return 0
}

# ui_show_final_result MSG
# Convenience: finish progress bar with MSG, run final-actions, offer log extraction.
ui_show_final_result(){
  local msg="${1:-}"
  ui_finish_as_final_screen "$msg"
  ui_show_final_actions
  ui_ask_extract_log
}

# =========================================================
# BANCO / SQLITE / MYSQL
# =========================================================

sqlite_exec_retry(){
  local sql="$1"
  local i

  debug_log "SQLITE_DB=$PDV_OUT_DB"
  debug_log "SQLITE_SQL=<omitida_por_seguranca>"

  # Defensive clamp: SQLITE_RETRY_COUNT=0 would skip the loop entirely and
  # return 1 immediately.  Ensure at least 1 attempt is made.
  local _retry_count="$SQLITE_RETRY_COUNT"
  if [[ ! "$_retry_count" =~ ^[0-9]+$ ]] || (( _retry_count < 1 )); then
    _retry_count=1
  fi

  for (( i=1; i<=_retry_count; i++ )); do
    debug_log "SQLITE_TENTATIVA=${i}/${_retry_count}"
    if sqlite3 "$PDV_OUT_DB" ".timeout ${SQLITE_BUSY_TIMEOUT_MS}" "$sql" >>"$AUDIT_TMP" 2>&1; then
      return 0
    fi
    debug_log "SQLITE: tentativa ${i} falhou"
    # (( expr )) returns exit code 1 when expr is 0 (i.e. last attempt).
    # The || true prevents set -e from treating the non-sleep case as failure.
    (( i < _retry_count )) && sleep "$SQLITE_RETRY_SLEEP" || true
  done

  return 1
}

sqlite_scalar(){
  local sql="$1" out="" i rc _sq_tmp

  debug_log "SQLITE_DB=$PDV_OUT_DB"
  debug_log "SQLITE_SQL=<omitida_por_seguranca>"

  # Defensive clamp: same as sqlite_exec_retry.
  local _retry_count="$SQLITE_RETRY_COUNT"
  if [[ ! "$_retry_count" =~ ^[0-9]+$ ]] || (( _retry_count < 1 )); then
    _retry_count=1
  fi

  for (( i=1; i<=_retry_count; i++ )); do
    # Capture the sqlite3 exit code directly (not through a pipeline) to avoid
    # the pipeline masking a sqlite3 error behind head's rc=0.
    _sq_tmp="$(mktemp 2>/dev/null)" || _sq_tmp="/dev/null"
    sqlite3 "$PDV_OUT_DB" ".timeout ${SQLITE_BUSY_TIMEOUT_MS}" "$sql" >"$_sq_tmp" 2>>"$AUDIT_TMP"
    rc=$?
    if (( rc == 0 )); then
      out="$(head -n1 "$_sq_tmp" 2>/dev/null || true)"
      [[ "$_sq_tmp" != "/dev/null" ]] && rm -f "$_sq_tmp" 2>/dev/null || true
      debug_log "SQLITE_RESULT=$out"
      printf '%s\n' "$out"
      return 0
    fi
    [[ "$_sq_tmp" != "/dev/null" ]] && rm -f "$_sq_tmp" 2>/dev/null || true
    debug_log "SQLITE: tentativa de leitura ${i}/${_retry_count} falhou (rc=${rc})"
    # (( expr )) returns exit code 1 when expr is 0 (i.e. last attempt).
    # The || true prevents set -e from treating the non-sleep case as failure.
    (( i < _retry_count )) && sleep "$SQLITE_RETRY_SLEEP" || true
  done

  return 1
}

_debug_mysql_context(){
  debug_log "MYSQL_HOST=$MYSQL_HOST"
  debug_log "MYSQL_PORT=$MYSQL_PORT"
  debug_log "MYSQL_DB=$NOME_BD"
  debug_log "MYSQL_USER=$USUARIO_BD"
  debug_log "MYSQL_PASS_MASKED=$(mask_secret "$MYSQL_PASS")"
  debug_log "MYSQL_SQL=<omitida_por_seguranca>"
}

mysql_exec(){
  local sql="$1" _mysql_err_tmp _mysql_rc

  _debug_mysql_context

  _mysql_err_tmp="$(mktemp 2>/dev/null)" || _mysql_err_tmp="/dev/null"
  MYSQL_PWD="$MYSQL_PASS" mysql \
    --protocol=TCP \
    --connect-timeout=5 \
    -h "$MYSQL_HOST" \
    -P "$MYSQL_PORT" \
    -u "$USUARIO_BD" \
    "$NOME_BD" \
    -Nse "$sql" >>"$AUDIT_TMP" 2>"$_mysql_err_tmp"
  _mysql_rc=$?
  if (( _mysql_rc != 0 )); then
    log "MYSQL_EXEC_ERROR (rc=${_mysql_rc}): $(cat "$_mysql_err_tmp" 2>/dev/null)"
  fi
  rm -f "$_mysql_err_tmp" 2>/dev/null || true
  return "$_mysql_rc"
}

mysql_scalar(){
  local sql="$1" out="" _mysql_err_tmp _mysql_rc

  _debug_mysql_context

  _mysql_err_tmp="$(mktemp 2>/dev/null)" || _mysql_err_tmp="/dev/null"
  # Use a temp file for mysql output so we capture mysql's exit code directly
  # rather than the exit code of head (which would mask mysql errors).
  local _mysql_out_tmp
  _mysql_out_tmp="$(mktemp 2>/dev/null)" || _mysql_out_tmp="/dev/null"
  MYSQL_PWD="$MYSQL_PASS" mysql \
    --protocol=TCP \
    --connect-timeout=5 \
    -h "$MYSQL_HOST" \
    -P "$MYSQL_PORT" \
    -u "$USUARIO_BD" \
    "$NOME_BD" \
    -Nse "$sql" >"$_mysql_out_tmp" 2>"$_mysql_err_tmp"
  _mysql_rc=$?
  out="$(head -n1 "$_mysql_out_tmp" 2>/dev/null || true)"
  if (( _mysql_rc != 0 )); then
    log "MYSQL_SCALAR_ERROR (rc=${_mysql_rc}): $(head -n3 "$_mysql_err_tmp" 2>/dev/null | tr '\n' ' ')"
  fi
  [[ "$_mysql_out_tmp" != "/dev/null" ]] && rm -f "$_mysql_out_tmp" 2>/dev/null || true
  [[ "$_mysql_err_tmp" != "/dev/null" ]] && rm -f "$_mysql_err_tmp" 2>/dev/null || true

  debug_log "MYSQL_RESULT=$out"
  printf '%s\n' "$out"
  return "$_mysql_rc"
}

check_sqlite_integrity(){
  step_enter "Validando integridade do SQLite"

  local r
  if [[ ! -r "$PDV_OUT_DB" ]]; then
    step_fail "PDV_OUT_DB não legível: $PDV_OUT_DB"
    return 1
  fi

  local _sq_int_tmp _sq_int_rc
  _sq_int_tmp="$(mktemp 2>/dev/null)" || _sq_int_tmp="/dev/null"
  sqlite3 "$PDV_OUT_DB" ".timeout ${SQLITE_BUSY_TIMEOUT_MS}" "PRAGMA integrity_check;" \
    >"$_sq_int_tmp" 2>>"$AUDIT_TMP"
  _sq_int_rc=$?
  # Read first line; any value other than "ok" (including multi-line output)
  # indicates corruption.
  r="$(head -n1 "$_sq_int_tmp" 2>/dev/null || true)"
  [[ "$_sq_int_tmp" != "/dev/null" ]] && rm -f "$_sq_int_tmp" 2>/dev/null || true
  log_kv "SQLITE_INTEGRITY_RESULT" "$r"
  log_kv "SQLITE_INTEGRITY_RC" "$_sq_int_rc"

  if (( _sq_int_rc != 0 )); then
    step_fail "PRAGMA integrity_check falhou com rc=${_sq_int_rc}"
    return 1
  fi

  if [[ "$r" != "ok" ]]; then
    step_fail "Integridade SQLite falhou: $r"
    return 1
  fi

  step_ok "Validando integridade do SQLite"
}

check_required_schema(){
  step_enter "Validando estrutura de banco"

  local t

  t="$(sqlite_scalar "SELECT name FROM sqlite_master WHERE type='table' AND name='configuracao_pdv';")"
  log_kv "SQLITE_TABLE_configuracao_pdv" "$t"
  [[ "$t" == "configuracao_pdv" ]] || return 1

  t="$(mysql_scalar "SHOW TABLES LIKE 'pdvctr';")"
  log_kv "MYSQL_TABLE_pdvctr" "$t"
  [[ "$t" == "pdvctr" ]] || return 1

  t="$(mysql_scalar "SHOW TABLES LIKE 'pdvtls';")"
  log_kv "MYSQL_TABLE_pdvtls" "$t"
  [[ "$t" == "pdvtls" ]] || return 1

  step_ok "Validando estrutura de banco"
}

step_collect_cfg(){
  step_enter "Coletando configuração do PDV"

  local row

  [[ -r "$PDV_OUT_DB" ]] || {
    step_fail "PDV_OUT_DB sem leitura: $PDV_OUT_DB"
    return 1
  }

  # Seleciona cada coluna individualmente para evitar que um valor com '|'
  # quebre o parse IFS-based. sqlite3 sem separador explícito usa '|', portanto
  # campos com pipe literal corromperiam a linha composta.
  IP_BD="$(sqlite_scalar     "SELECT ip_bd       FROM configuracao_pdv LIMIT 1;")" || { step_fail "Falha ao ler ip_bd";       return 1; }
  NOME_BD="$(sqlite_scalar   "SELECT nome_bd     FROM configuracao_pdv LIMIT 1;")" || { step_fail "Falha ao ler nome_bd";     return 1; }
  USUARIO_BD="$(sqlite_scalar "SELECT usuario_bd FROM configuracao_pdv LIMIT 1;")" || { step_fail "Falha ao ler usuario_bd";  return 1; }
  SENHA_B64="$(sqlite_scalar "SELECT senha       FROM configuracao_pdv LIMIT 1;")" || { step_fail "Falha ao ler senha";       return 1; }
  NUM_CAIXA="$(sqlite_scalar "SELECT numero_caixa FROM configuracao_pdv LIMIT 1;")" || { step_fail "Falha ao ler numero_caixa"; return 1; }

  log "ROW_BRUTA=<omitida_por_seguranca>"
  [[ -n "$IP_BD" && -n "$NOME_BD" && -n "$USUARIO_BD" && -n "$SENHA_B64" && -n "$NUM_CAIXA" ]] || {
    step_fail "Um ou mais campos obrigatórios estão vazios em configuracao_pdv"
    return 1
  }

  IP_BD="$(printf '%s' "$IP_BD" | trim)"
  NOME_BD="$(printf '%s' "$NOME_BD" | trim)"
  USUARIO_BD="$(printf '%s' "$USUARIO_BD" | trim)"
  SENHA_B64="$(printf '%s' "$SENHA_B64" | trim)"
  NUM_CAIXA="$(printf '%s' "$NUM_CAIXA" | trim)"

  log_kv "IP_BD_RAW" "$IP_BD"
  log_kv "NOME_BD" "$NOME_BD"
  log_kv "USUARIO_BD" "$USUARIO_BD"
  log_kv_masked "SENHA_B64_MASKED" "$SENHA_B64"
  log_kv "NUM_CAIXA" "$NUM_CAIXA"

  if [[ "$IP_BD" == *:* ]]; then
    MYSQL_HOST="${IP_BD%:*}"
    MYSQL_PORT="${IP_BD##*:}"
  else
    MYSQL_HOST="$IP_BD"
    MYSQL_PORT="3306"
  fi

  [[ -n "$MYSQL_HOST" ]] || {
    step_fail "MYSQL_HOST vazio"
    return 1
  }
  [[ "$MYSQL_PORT" =~ ^[0-9]+$ ]] || MYSQL_PORT="3306"

  MYSQL_PASS="$(decode_b64 "$SENHA_B64")" || {
    step_fail "Falha ao decodificar senha base64 (dado corrompido em configuracao_pdv)"
    return 1
  }

  [[ -n "$NOME_BD" ]] || return 1
  [[ -n "$USUARIO_BD" ]] || return 1
  [[ -n "$MYSQL_PASS" ]] || return 1
  [[ "$NUM_CAIXA" =~ ^[0-9]+$ ]] || return 1

  log_kv "MYSQL_HOST" "$MYSQL_HOST"
  log_kv "MYSQL_PORT" "$MYSQL_PORT"
  log_kv_masked "MYSQL_PASS_MASKED" "$MYSQL_PASS"

  step_ok "Coletando configuração do PDV"
}

step_collect_identification(){
  step_enter "Coletando identificação do PDV"

  local loja_raw="" _raw_cnpj="" _raw_idloja=""

  _raw_cnpj="$(mysql_scalar "SELECT ${MYSQL_COL_CNPJ} FROM ${MYSQL_TABLE} LIMIT 1;")" || {
    step_fail "Falha ao consultar ${MYSQL_COL_CNPJ} em ${MYSQL_TABLE}"
    return 1
  }
  CNPJ_LOJA="$(printf '%s' "$_raw_cnpj" | tr -dc '0-9')"

  _raw_idloja="$(mysql_scalar "SELECT ${MYSQL_COL_IDLOJA_TEF} FROM ${MYSQL_TABLE} LIMIT 1;")" || {
    step_fail "Falha ao consultar ${MYSQL_COL_IDLOJA_TEF} em ${MYSQL_TABLE}"
    return 1
  }
  IDLOJA_TEF="$(printf '%s' "$_raw_idloja" | tr -dc '0-9')"

  loja_raw="$(mysql_scalar "SELECT lojfantas FROM hiploj LIMIT 1;" || true)"

  LOJA_EXIBICAO="$(printf '%s' "$loja_raw" \
    | sed 's/[[:space:]]*(.*$//; s/[[:space:]]\+/ /g; s/^[[:space:]]*//; s/[[:space:]]*$//' \
    | tr '[:lower:]' '[:upper:]')"

  [[ -n "${CNPJ_LOJA:-}" ]] || {
    step_fail "CNPJ_LOJA vazio"
    return 1
  }

  [[ -n "${IDLOJA_TEF:-}" ]] || {
    step_fail "IDLOJA_TEF vazio"
    return 1
  }

  log_kv "CNPJ_LOJA" "$CNPJ_LOJA"
  log_kv "IDLOJA_TEF" "$IDLOJA_TEF"

  if [[ -n "$LOJA_EXIBICAO" ]]; then
    log_kv "LOJA_EXIBICAO" "$LOJA_EXIBICAO"
  else
    log "LOJA_EXIBICAO=<vazia>"
  fi

  step_ok "Coletando identificação do PDV"
}

step_collect_existing_token(){
  step_enter "Verificando token atual no banco"

  # A missing token row is not an error — use || true so the script continues.
  # IMPORTANT: if MySQL is down here, mysql_scalar returns rc!=0 and emits a
  # MYSQL_SCALAR_ERROR log line; the || true suppresses the exit but the TOKEN
  # will be empty.  We distinguish "no row" from "MySQL error" via the logged
  # rc in mysql_scalar.  The operator must check MYSQL_SCALAR_ERROR in the log
  # if TOKEN_ATUAL_BANCO is unexpectedly empty.
  local _raw_token
  _raw_token="$(mysql_scalar "SELECT ${TLS_COL_TOKEN} FROM ${TLS_TABLE} WHERE tlsloja=0 AND ${TLS_COL_CAIXA}=${NUM_CAIXA} LIMIT 1;" 2>/dev/null || true)"
  TOKEN_ATUAL_BANCO="$(printf '%s' "${_raw_token:-}" | tr -d '[:space:]')"

  if [[ -n "$TOKEN_ATUAL_BANCO" ]]; then
    log "TOKEN_ATUAL_ENCONTRADO_MASKED=$(mask_secret "$TOKEN_ATUAL_BANCO")"
  else
    # Log explicitly whether this is "row not found" or potentially a MySQL
    # connectivity problem (MYSQL_SCALAR_ERROR will appear above this line if
    # the latter).
    log "TOKEN_ATUAL_ENCONTRADO=<nenhum> (linha ausente ou falha de conexão — ver MYSQL_SCALAR_ERROR acima se houver)"
  fi

  step_ok "Verificando token atual no banco"
}

# =========================================================
# SNAPSHOT / ROLLBACK / LIMPEZA
# =========================================================

# capture_original_state
#
# Tira snapshot atômico de todos os artefatos que serão modificados pelo fluxo.
# DEVE ser chamada antes de qualquer escrita. Se falhar em qualquer passo,
# o rollback não pode ser considerado seguro — por isso a função retorna 1 e
# o chamador chama die(), que executa run_rollback() apenas se ROLLBACK_ENABLED=1.
# Como ROLLBACK_ENABLED só é definido no final desta função (após snapshot completo),
# um die() anterior ao snapshot não executa rollback. Esse invariante é intencional.
#
# Artefatos capturados:
#   ORIG_SQLITE_FLAG      — valor de habilita_tef_confiTLS em configuracao_pdv
#   ORIG_TOKEN_EXISTS/VALUE — linha em pdvtls para o caixa atual
#   ORIG_CONFITLS_BACKUP  — cópia de CONFITLS.INI (se existir)
#   ORIG_CTRL_BACKUP      — cópia de NaoExcluirControleCliSiTef (se existir)
#
# Nota: NaoExcluirControleCliSiTef é capturado mas NÃO restaurado no rollback
# por regra operacional (step_reset_tls_control é unidirecional).
capture_original_state(){
  step_enter "Capturando estado original do sistema"

  local ctrl="/opt/checkout/clisitef/NaoExcluirControleCliSiTef"

  # CRÍTICO: se sqlite_scalar falhar (BUSY, LOCKED, coluna ausente), abortar
  # imediatamente — sem snapshot completo não há rollback seguro.
  ORIG_SQLITE_FLAG="$(sqlite_scalar "SELECT habilita_tef_confiTLS FROM configuracao_pdv LIMIT 1;")" || {
    step_fail "Falha ao ler habilita_tef_confiTLS do SQLite durante snapshot (BUSY/LOCKED?)"
    return 1
  }
  if [[ -z "${ORIG_SQLITE_FLAG:-}" ]]; then
    step_fail "ORIG_SQLITE_FLAG vazio após leitura SQLite bem-sucedida (coluna ausente ou NULL?); snapshot inválido"
    return 1
  fi
  log_kv "ORIG_SQLITE_FLAG" "${ORIG_SQLITE_FLAG}"

  # CRÍTICO: se MySQL estiver inacessível durante snapshot, abortar.
  # Usar || true aqui causaria rollback que apaga token em vez de restaurá-lo.
  local _orig_token_raw
  if ! _orig_token_raw="$(mysql_scalar "SELECT ${TLS_COL_TOKEN} FROM ${TLS_TABLE} WHERE tlsloja=0 AND ${TLS_COL_CAIXA}=${NUM_CAIXA} LIMIT 1;")"; then
    step_fail "Falha ao consultar token original no MySQL durante snapshot (MySQL inacessível?); snapshot inválido"
    return 1
  fi
  ORIG_TOKEN_VALUE="$(printf '%s' "${_orig_token_raw:-}" | tr -d '[:space:]')"
  if [[ -n "${ORIG_TOKEN_VALUE:-}" ]]; then
    ORIG_TOKEN_EXISTS=1
    log_kv_masked "ORIG_TOKEN_VALUE_MASKED" "$ORIG_TOKEN_VALUE"
  else
    ORIG_TOKEN_EXISTS=0
  fi
  log_kv "ORIG_TOKEN_EXISTS" "$ORIG_TOKEN_EXISTS"

  if [[ -f "$CONFITLS_INI" ]]; then
    ORIG_CONFITLS_EXISTS=1
    ORIG_CONFITLS_BACKUP="$(mktemp "${SCRIPT_DIR}/.CONFITLS.INI.backup.XXXXXX" 2>/dev/null)" || {
      step_fail "Falha ao criar backup temporário de CONFITLS.INI (disco cheio?)"
      return 1
    }
    cp -a "$CONFITLS_INI" "$ORIG_CONFITLS_BACKUP" || {
      rm -f "$ORIG_CONFITLS_BACKUP" 2>/dev/null || true
      ORIG_CONFITLS_BACKUP=""
      step_fail "Falha ao copiar CONFITLS.INI para backup"
      return 1
    }
    chmod 600 "$ORIG_CONFITLS_BACKUP" 2>/dev/null || true
    log_kv "ORIG_CONFITLS_BACKUP" "$ORIG_CONFITLS_BACKUP"
  else
    ORIG_CONFITLS_EXISTS=0
  fi
  log_kv "ORIG_CONFITLS_EXISTS" "$ORIG_CONFITLS_EXISTS"

  if [[ -e "$ctrl" ]]; then
    ORIG_CTRL_EXISTS=1
    ORIG_CTRL_BACKUP="$(mktemp -d "${SCRIPT_DIR}/.tls_ctrl_backup.XXXXXX" 2>/dev/null)" || {
      step_fail "Falha ao criar diretório de backup para controle TLS (disco cheio?)"
      return 1
    }
    if [[ -d "$ctrl" ]]; then
      ORIG_CTRL_IS_DIR=1
      cp -a "$ctrl" "${ORIG_CTRL_BACKUP}/" || {
        rm -rf "$ORIG_CTRL_BACKUP" 2>/dev/null || true
        ORIG_CTRL_BACKUP=""
        step_fail "Falha ao copiar diretório de controle TLS para backup"
        return 1
      }
      log_kv "ORIG_CTRL_TYPE" "diretorio"
    else
      ORIG_CTRL_IS_DIR=0
      cp -a "$ctrl" "${ORIG_CTRL_BACKUP}/" || {
        rm -rf "$ORIG_CTRL_BACKUP" 2>/dev/null || true
        ORIG_CTRL_BACKUP=""
        step_fail "Falha ao copiar arquivo de controle TLS para backup"
        return 1
      }
      log_kv "ORIG_CTRL_TYPE" "arquivo"
    fi
    log_kv "ORIG_CTRL_BACKUP" "$ORIG_CTRL_BACKUP"
  else
    ORIG_CTRL_EXISTS=0
  fi
  log_kv "ORIG_CTRL_EXISTS" "$ORIG_CTRL_EXISTS"

  ROLLBACK_ENABLED=1
  step_ok "Capturando estado original do sistema"
}

# restore_original_state
#
# Restaura todos os artefatos capturados por capture_original_state.
# Executa sob set +e: cada passo falho é logado como WARN mas não interrompe
# os passos subsequentes — é melhor restaurar parcialmente do que parar no
# primeiro erro e deixar o sistema em estado misto.
# INT/TERM são bloqueados durante a restauração para evitar reentrada.
restore_original_state(){
  step_enter "Restaurando estado original do sistema"

  # Block INT/TERM for the duration of the restore so a signal arriving while
  # restoring does not partially re-enter rollback or skip remaining steps.
  trap '' INT TERM

  # Note: ROLLBACK_ENABLED is cleared by run_rollback() before calling here;
  # this check guards direct calls.
  local token_esc=""
  local _rc_sqlite=0 _rc_mysql=0 _rc_conf=0 _rc_svc=0

  # Run all restore steps under set +e so a single failure does not skip the
  # remaining steps.
  set +e

  if [[ -n "${ORIG_SQLITE_FLAG:-}" ]]; then
    # Validate that the captured flag is a safe integer before embedding in SQL.
    local _flag_val
    if [[ "$ORIG_SQLITE_FLAG" =~ ^[0-9]+$ ]]; then
      _flag_val="$ORIG_SQLITE_FLAG"
    else
      log "WARN: ORIG_SQLITE_FLAG tem valor inesperado ('${ORIG_SQLITE_FLAG}'); restaurando para 0"
      _flag_val="0"
    fi
    sqlite_exec_retry "UPDATE configuracao_pdv SET habilita_tef_confiTLS=${_flag_val};"
    _rc_sqlite=$?
    log_kv "RESTORE_SQLITE_FLAG_ALVO" "$_flag_val"
    log_kv "RESTORE_SQLITE_RC" "$_rc_sqlite"
    if (( _rc_sqlite != 0 )); then
      log "WARN: falha ao restaurar flag SQLite durante rollback (rc=${_rc_sqlite})"
    else
      # Confirm the value was actually written: rc=0 does not guarantee
      # the table had any rows (UPDATE affecting 0 rows returns rc=0 in SQLite).
      local _sqlite_confirm
      _sqlite_confirm="$(sqlite3 "$PDV_OUT_DB" ".timeout ${SQLITE_BUSY_TIMEOUT_MS}" \
        "SELECT habilita_tef_confiTLS FROM configuracao_pdv LIMIT 1;" 2>/dev/null || true)"
      log_kv "RESTORE_SQLITE_FLAG_CONFIRMADO" "${_sqlite_confirm:-<leitura_falhou>}"
      if [[ "${_sqlite_confirm:-}" != "${_flag_val}" ]]; then
        log "WARN: RESTORE_SQLITE_FLAG_MISMATCH: esperado=${_flag_val} atual=${_sqlite_confirm:-<vazio>}"
        _rc_sqlite=1
      fi
    fi
  fi

  if (( ORIG_TOKEN_EXISTS == 1 )); then
    token_esc="$(mysql_escape "$ORIG_TOKEN_VALUE")"
    # Guard: NUM_CAIXA must be a valid integer before embedding in SQL.
    if [[ "${NUM_CAIXA:-}" =~ ^[0-9]+$ ]]; then
      # Verifica ROW_COUNT após UPDATE: rc=0 com 0 linhas afetadas ainda é
      # uma falha de rollback — o token não foi restaurado.
      mysql_exec "UPDATE ${TLS_TABLE} SET ${TLS_COL_TOKEN}='${token_esc}' WHERE tlsloja=0 AND ${TLS_COL_CAIXA}=${NUM_CAIXA};"
      _rc_mysql=$?
      if (( _rc_mysql == 0 )); then
        local _upd_rows
        _upd_rows="$(mysql_scalar "SELECT ROW_COUNT();")" || _upd_rows=""
        if [[ "${_upd_rows:-0}" == "0" ]]; then
          log "WARN: UPDATE token retornou rc=0 mas ROW_COUNT()=0; token pode não ter sido restaurado (linha ausente?)"
        fi
      fi
    else
      log "WARN: NUM_CAIXA inválido ('${NUM_CAIXA:-}') durante rollback de token; UPDATE ignorado"
      _rc_mysql=1
    fi
    log_kv "RESTORE_TOKEN" "original"
    log_kv "RESTORE_MYSQL_RC" "$_rc_mysql"
    (( _rc_mysql != 0 )) && log "WARN: falha ao restaurar token MySQL durante rollback (rc=${_rc_mysql})"
  else
    if [[ "${NUM_CAIXA:-}" =~ ^[0-9]+$ ]]; then
      mysql_exec "DELETE FROM ${TLS_TABLE} WHERE tlsloja=0 AND ${TLS_COL_CAIXA}=${NUM_CAIXA};"
      _rc_mysql=$?
    else
      log "WARN: NUM_CAIXA inválido ('${NUM_CAIXA:-}') durante rollback de token; DELETE ignorado"
      _rc_mysql=1
    fi
    log_kv "RESTORE_TOKEN" "deleted"
    log_kv "RESTORE_MYSQL_RC" "$_rc_mysql"
    (( _rc_mysql != 0 )) && log "WARN: falha ao deletar token MySQL durante rollback (rc=${_rc_mysql})"
  fi

  if (( ORIG_CONFITLS_EXISTS == 1 )) && [[ -f "${ORIG_CONFITLS_BACKUP:-}" ]]; then
    # Use an atomic rename so a disk-full condition cannot leave CONFITLS_INI
    # in a zero-byte or truncated state.
    local _tmp_restore_ini
    _tmp_restore_ini="$(mktemp "${CONFITLS_INI}.restoreXXXXXX" 2>/dev/null)" || _tmp_restore_ini=""
    if [[ -n "$_tmp_restore_ini" ]]; then
      cp -a "$ORIG_CONFITLS_BACKUP" "$_tmp_restore_ini" && \
        mv -f "$_tmp_restore_ini" "$CONFITLS_INI"
      _rc_conf=$?
      [[ -f "$_tmp_restore_ini" ]] && rm -f "$_tmp_restore_ini" 2>/dev/null || true
    else
      cp -a "$ORIG_CONFITLS_BACKUP" "$CONFITLS_INI"
      _rc_conf=$?
    fi
    chmod 0644 "$CONFITLS_INI" 2>/dev/null || true
    log_kv "RESTORE_CONFITLS" "restaurado"
    log_kv "RESTORE_CONFITLS_RC" "$_rc_conf"
    (( _rc_conf != 0 )) && log "WARN: falha ao restaurar CONFITLS.INI durante rollback (rc=${_rc_conf})"
  else
    rm -f "$CONFITLS_INI" 2>/dev/null || true
    log "RESTORE_CONFITLS=removido"
  fi

  # Controle TLS não é restaurado no rollback por regra operacional.
  log "RESTORE_CTRL=ignorado_por_regra"

  # Restart service; _restart_service uses a 60-second timeout guard.
  _restart_service
  _rc_svc=$?
  log_kv "RESTORE_SERVICE" "restart"
  log_kv "RESTORE_SERVICE_RC" "$_rc_svc"
  if (( _rc_svc != 0 )); then
    log "WARN: falha ao reiniciar ${SERVICE_NAME} durante rollback (rc=${_rc_svc})"
  else
    # Verify the service actually reached active state after restart.
    # rc!=0 from _restart_service only means systemctl restart failed;
    # rc=0 does NOT guarantee the service is running (it could have exited
    # immediately after being started). Poll is_active for up to 10 seconds.
    local _svc_active=0
    local _svc_check
    for _svc_check in 1 2 3 4 5 6 7 8 9 10; do
      if systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
        _svc_active=1
        break
      fi
      sleep 1
    done
    if (( _svc_active == 0 )); then
      log "WARN: ${SERVICE_NAME} não ficou ativo após rollback-restart (10 s de espera esgotados)"
      _rc_svc=1
    else
      log "RESTORE_SERVICE_ACTIVE=1"
    fi
  fi

  # Emit a single aggregated rollback-result line so operators can grep for
  # ROLLBACK_RESULT without reading individual WARN lines.
  local _any_fail=0
  (( _rc_sqlite != 0 )) && _any_fail=1
  (( _rc_mysql  != 0 )) && _any_fail=1
  (( _rc_conf   != 0 )) && _any_fail=1
  (( _rc_svc    != 0 )) && _any_fail=1
  if (( _any_fail == 1 )); then
    log "ROLLBACK_RESULT=PARCIAL (sqlite_rc=${_rc_sqlite} mysql_rc=${_rc_mysql} conf_rc=${_rc_conf} svc_rc=${_rc_svc})"
  else
    log "ROLLBACK_RESULT=COMPLETO"
  fi

  set -e

  # Restore signal handlers now that the critical restore section is done.
  trap on_signal INT TERM

  if (( _any_fail == 1 )); then
    # Log as failure so the audit trail is accurate, but do not propagate the
    # error — caller uses "|| true" so partial rollback does not abort die().
    step_fail "Restaurando estado original do sistema (rollback parcial)"
  else
    step_ok "Restaurando estado original do sistema"
  fi
}

run_rollback(){
  # Guard against running twice in the same process.
  (( ROLLBACK_ENABLED == 1 )) || {
    log "ROLLBACK: já executado ou não habilitado, ignorando chamada duplicada"
    return 0
  }

  log_sep
  log "INICIANDO ROLLBACK"

  # Disable before executing so a recursive call (e.g. from a trap inside
  # restore) cannot re-enter.
  ROLLBACK_ENABLED=0

  restore_original_state || true

  log "ROLLBACK_CONCLUIDO"
}

cleanup(){
  # Suppress signals during cleanup to avoid re-entrant invocation from EXIT trap
  # being fired while INT/TERM is also being handled.
  trap '' INT TERM EXIT

  if [[ -n "${UI_FD:-}" ]]; then
    exec {UI_FD}>&- 2>/dev/null || true
    UI_FD=""
  fi

  if [[ -n "${ZENITY_PID:-}" ]]; then
    kill "$ZENITY_PID" 2>/dev/null || true
    ZENITY_PID=""
  fi

  if [[ -n "${TMP_INITIAL_INFO_FILE:-}" && -f "${TMP_INITIAL_INFO_FILE:-}" ]]; then
    rm -f "${TMP_INITIAL_INFO_FILE}" 2>/dev/null || true
    TMP_INITIAL_INFO_FILE=""
  fi

  if [[ -n "${AUDIT_TMP:-}" && -f "${AUDIT_TMP:-}" ]]; then
    rm -f "$AUDIT_TMP" 2>/dev/null || true
  fi

  cleanup_sensitive_artifacts

  # Fecha explicitamente o FD do lockfile para liberar o flock antes do
  # processo terminar. O kernel liberaria de qualquer forma no exit, mas o
  # fechamento explícito é mais claro e garante a liberação imediata mesmo em
  # cenários de fork ou exec posterior.
  exec 9>&- 2>/dev/null || true

  MYSQL_PASS=""
  SENHA_B64=""
  TOKEN_TLS=""
  TOKEN_ATUAL_BANCO=""
  ORIG_TOKEN_VALUE=""
}

on_signal(){
  # Block further INT/TERM so that a second signal arriving while rollback or
  # cleanup runs does not re-enter this handler (which would call run_rollback
  # a second time on a potentially half-restored system).
  trap '' INT TERM
  log "SINAL: interrupção recebida (INT/TERM)"
  if (( ROLLBACK_ENABLED == 1 && SKIP_ROLLBACK == 0 )); then
    log "SINAL: iniciando rollback por sinal"
    run_rollback || true
  fi
  set +e
  ui_show_final_actions
  ui_ask_extract_log
  # cleanup() will be called via EXIT trap after exit
  exit 130
}

trap cleanup EXIT
trap on_signal INT TERM
# Ignore SIGPIPE so that writing to the zenity coproc FD when zenity has already
# exited (broken pipe) does not kill the script.  The individual write calls
# use "|| true" as well, but the signal itself would terminate the process
# before the shell evaluates the || clause.
trap '' PIPE

# die MSG...
#
# Termina o script com erro, executando rollback e finalizando a UI.
# Comportamento bifurcado por SKIP_ROLLBACK:
#   SKIP_ROLLBACK=0 (padrão): rollback + mensagem de erro + exit 1
#   SKIP_ROLLBACK=1 (set pelo run_test_once em caso de resultado definitivo):
#     não faz rollback; oferece ao operador a escolha de retornar ao GSurf
#     ou permanecer no modo TLS com o status atual.
die(){
  # Disable set -e for the entire die() body: any non-fatal error inside
  # rollback or UI shutdown must not silently abort via set -e before exit 1.
  set +e
  log "ERRO_FATAL: $*"
  log "ERRO_CONTEXTO: ROLLBACK_ENABLED=${ROLLBACK_ENABLED} SKIP_ROLLBACK=${SKIP_ROLLBACK} MODE=${MODO_TESTE_TOKEN_ATUAL}"

  if (( SKIP_ROLLBACK == 0 )); then
    run_rollback
    ui_end_fail "$*"
    ui_show_final_result "Erro: $*"
    exit 1
  fi

  log "ROLLBACK: ignorado (erro de comunicação)"

  if ui_ask_return_to_gsurf "${TEST_RESULT_MSG:-Erro de comunicação}"; then
    ui_progress 60 "Retornando para GSurf"
    step_switch_to_gsurf || log "WARN: falha ao alterar para GSurf"
    ui_progress 64 "Iniciando teste GSurf"

    UI_TEST_LABEL="Testando Comunicação | Gsurf"
    ui_step_min "Testando comunicação via GSurf" step_validate_final_mode GSURF || true

    log "RESULTADO_FINAL: modo=GSurf ok=${FINAL_MODE_TEST_OK:-0} msg=${FINAL_MODE_TEST_MSG:-}"

    if [[ "${FINAL_MODE_TEST_OK:-0}" == "1" ]]; then
      ui_show_final_result "Teste de comunicação OK | ${FINAL_MODE_TEST_MSG:-Sem retorno} | modo GSurf"
    else
      ui_show_final_result "Teste de comunicação falhou | ${FINAL_MODE_TEST_MSG:-Sem retorno} | modo GSurf"
    fi
  else
    log "RESULTADO_FINAL: modo=TLS (sem retorno para GSurf) msg=${TEST_RESULT_MSG:-}"
    if [[ "${TEST_RESULT_MSG:-}" == "Servidor Ativo" ]]; then
      ui_show_final_result "Teste de comunicação OK | ${TEST_RESULT_MSG:-Sem retorno} | modo TLS"
    else
      ui_show_final_result "Teste de comunicação falhou | PDV não está com o modo TLS ativo (tls-prod.fiservapp.com)"
    fi
  fi

  exit 1
}

# =========================================================
# CONTEXTO TLS / ESCRITA / SERVIÇO / MODO
# =========================================================

step_finalize_tls_context(){
  step_enter "Finalizando contexto TLS"

  step_collect_identification || {
    step_fail "Falha ao coletar identificação do PDV"
    return 1
  }

  pick_socket_host_port || {
    step_fail "Falha ao configurar socket"
    return 1
  }

  derive_idterm || {
    step_fail "Falha ao derivar IDTERM"
    return 1
  }

  derive_idloja_fmt || {
    step_fail "Falha ao formatar IDLOJA"
    return 1
  }

  derive_parmsclient || {
    step_fail "Falha ao montar PARMSCLIENT"
    return 1
  }

  DATAFISC="$(date +%Y%m%d)"
  HORAFISC="$(date +%H%M%S)"
  CUPOM="$HORAFISC"

  log_kv "CACHE_NUM_CAIXA" "$NUM_CAIXA"
  log_kv "CACHE_CNPJ_LOJA" "$CNPJ_LOJA"
  log_kv "CACHE_IDLOJA_TEF" "$IDLOJA_TEF"
  log_kv "CACHE_IDTERM" "$IDTERM"
  log_kv "CACHE_IDLOJA" "$IDLOJA"
  log_kv "CACHE_PARMS" "$PARMS"
  log_kv "CACHE_DATAFISC" "$DATAFISC"
  log_kv "CACHE_HORAFISC" "$HORAFISC"
  log_kv "CACHE_CUPOM" "$CUPOM"

  step_ok "Finalizando contexto TLS"
}

step_set_flag_tls(){
  step_enter "Habilitando flag TLS no SQLite"

  local res
  sqlite_exec_retry "UPDATE configuracao_pdv SET habilita_tef_confiTLS=1;" || {
    step_fail "UPDATE habilita_tef_confiTLS"
    return 1
  }

  res="$(sqlite_scalar "SELECT habilita_tef_confiTLS FROM configuracao_pdv LIMIT 1;")"
  log_kv "habilita_tef_confiTLS" "$res"

  [[ "$res" == "1" ]] || {
    step_fail "Flag TLS não confirmada"
    return 1
  }

  step_ok "Habilitando flag TLS no SQLite"
}

step_write_mysql(){
  step_enter "Gravando token no MySQL"

  local cnt token_esc

  cnt="$(mysql_scalar "SELECT COUNT(*) FROM ${TLS_TABLE} WHERE tlsloja=0 AND ${TLS_COL_CAIXA}=${NUM_CAIXA};")" || {
    step_fail "Falha ao consultar registros em pdvtls (MySQL inacessível?)"
    return 1
  }
  cnt="${cnt:-0}"
  [[ "$cnt" =~ ^[0-9]+$ ]] || {
    step_fail "COUNT inválido em pdvtls"
    return 1
  }

  log_kv "PDVTLS_COUNT" "$cnt"
  token_esc="$(mysql_escape "$TOKEN_TLS")"
  log_kv_masked "TOKEN_TLS_MASKED" "$TOKEN_TLS"

  if (( cnt > 1 )); then
    log "WARN: registros duplicados em pdvtls para caixa ${NUM_CAIXA}"
  fi

  log "AÇÃO: saneando pdvtls para caixa ${NUM_CAIXA} em transação"
  log_kv "MYSQL_TRANSACTION_CAIXA" "$NUM_CAIXA"
  log_kv "MYSQL_TRANSACTION_TABELA" "$TLS_TABLE"

  local _mysql_rc
  set +e
  mysql_exec "
START TRANSACTION;
DELETE FROM ${TLS_TABLE} WHERE tlsloja=0 AND ${TLS_COL_CAIXA}=${NUM_CAIXA};
INSERT INTO ${TLS_TABLE} (tlsloja, ${TLS_COL_CAIXA}, ${TLS_COL_TOKEN})
VALUES (0, ${NUM_CAIXA}, '${token_esc}');
COMMIT;
"
  _mysql_rc=$?
  set -e

  log_kv "MYSQL_TRANSACTION_RC" "$_mysql_rc"

  if (( _mysql_rc != 0 )); then
    log 'AÇÃO_FALHOU: erro durante saneamento/INSERT em pdvtls'
    set +e
    mysql_exec "ROLLBACK;" || true
    set -e
    step_fail "Gravando token no MySQL"
    return 1
  fi

  local verify_cnt
  verify_cnt="$(mysql_scalar "SELECT COUNT(*) FROM ${TLS_TABLE} WHERE tlsloja=0 AND ${TLS_COL_CAIXA}=${NUM_CAIXA} AND ${TLS_COL_TOKEN}='${token_esc}';")" || {
    step_fail "Falha ao validar token gravado em pdvtls"
    return 1
  }
  verify_cnt="${verify_cnt:-0}"
  log_kv "MYSQL_POST_INSERT_VERIFY_COUNT" "$verify_cnt"

  if [[ ! "$verify_cnt" =~ ^[0-9]+$ ]] || (( verify_cnt < 1 )); then
    log 'AÇÃO_FALHOU: verificação pós-INSERT não encontrou o token em pdvtls'
    step_fail "Gravando token no MySQL (verificação pós-commit)"
    return 1
  fi

  log "AÇÃO_CONCLUÍDA: saneamento + INSERT pdvtls verificado"
  step_ok "Gravando token no MySQL"
}
write_confitls_ini(){
  step_enter "Gerando CONFITLS.INI"

  local tmp_ini
  local _confitls_dir
  _confitls_dir="$(dirname "$CONFITLS_INI")"
  if [[ ! -d "$_confitls_dir" ]]; then
    step_fail "Diretório de CONFITLS.INI não existe: $_confitls_dir"
    return 1
  fi
  tmp_ini="$(mktemp "${CONFITLS_INI}.XXXXXX" 2>/dev/null)" || {
    step_fail "Não foi possível criar arquivo temporário para CONFITLS.INI (disco cheio ou sem permissão?)"
    return 1
  }
  chmod 0644 "$tmp_ini" 2>/dev/null || true

  cat > "$tmp_ini" <<EOF
[ConfiguracaoTLS]
TipoComunicacaoExterna=TLSGWP
URLTLS=tls-prod.fiservapp.com
TokenRegistro=$TOKEN_TLS
EOF

  mv -f "$tmp_ini" "$CONFITLS_INI" || {
    rm -f "$tmp_ini" 2>/dev/null || true
    step_fail "Falha ao mover arquivo temporário para $CONFITLS_INI"
    return 1
  }

  log_kv "CONFITLS_INI" "$CONFITLS_INI"
  log_kv_masked "TOKEN_TLS_MASKED" "$TOKEN_TLS"

  step_ok "Gerando CONFITLS.INI"
}

validate_all(){
  step_enter "Validando gravações finais"

  local cnt flag token_esc conf_token conf_secao conf_tipo conf_url

  token_esc="$(mysql_escape "$TOKEN_TLS")"

  # Captura explícita do rc: sem || {}, falha de conexão MySQL abortaria via set -e
  # sem mensagem de erro útil.
  cnt="$(mysql_scalar "SELECT COUNT(*) FROM ${TLS_TABLE} WHERE tlsloja=0 AND ${TLS_COL_CAIXA}=${NUM_CAIXA} AND ${TLS_COL_TOKEN}='${token_esc}';")" || {
    step_fail "Falha ao consultar pdvtls na validação (MySQL inacessível?)"
    return 1
  }
  cnt="${cnt:-0}"
  log_kv "VALIDATE_PDVTLS_COUNT" "$cnt"

  [[ "$cnt" =~ ^[0-9]+$ ]] || {
    step_fail "COUNT inválido na validação MySQL"
    return 1
  }

  (( cnt >= 1 )) || {
    step_fail "Token não encontrado em pdvtls"
    return 1
  }

  if (( cnt > 1 )); then
    log "WARN: VALIDATE_PDVTLS_DUPLICATES encontrados: cnt=$cnt para caixa=${NUM_CAIXA}"
  fi

  flag="$(sqlite_scalar "SELECT habilita_tef_confiTLS FROM configuracao_pdv LIMIT 1;")"
  log_kv "VALIDATE_SQLITE_FLAG" "$flag"

  [[ "$flag" == "1" ]] || {
    step_fail "Flag TLS não está em 1"
    return 1
  }

  [[ -f "$CONFITLS_INI" ]] || {
    step_fail "CONFITLS.INI não existe"
    return 1
  }

  conf_secao="$(grep -Fx '[ConfiguracaoTLS]' "$CONFITLS_INI" | head -n1 || true)"
  conf_tipo="$(sed -n 's/^TipoComunicacaoExterna=//p' "$CONFITLS_INI" | head -n1 | tr -d '[:space:]')"
  conf_url="$(sed -n 's/^URLTLS=//p' "$CONFITLS_INI" | head -n1 | tr -d '[:space:]')"
  conf_token="$(sed -n 's/^TokenRegistro=//p' "$CONFITLS_INI" | head -n1 | tr -d '[:space:]')"

  log_kv "VALIDATE_CONFITLS_SECAO_OK" "$([[ "$conf_secao" == "[ConfiguracaoTLS]" ]] && echo 1 || echo 0)"
  log_kv "VALIDATE_CONFITLS_TIPO" "$conf_tipo"
  log_kv "VALIDATE_CONFITLS_URL" "$conf_url"
  log_kv "VALIDATE_CONFITLS_TOKEN_MASKED" "$(mask_secret "$conf_token")"

  [[ "$conf_secao" == "[ConfiguracaoTLS]" ]] || {
    step_fail "Seção do CONFITLS.INI inválida"
    return 1
  }

  [[ "$conf_tipo" == "TLSGWP" ]] || {
    step_fail "TipoComunicacaoExterna inválido no CONFITLS.INI"
    return 1
  }

  [[ "$conf_url" == "tls-prod.fiservapp.com" ]] || {
    step_fail "URLTLS inválida no CONFITLS.INI"
    return 1
  }

  [[ "$conf_token" == "$TOKEN_TLS" ]] || {
    step_fail "Token do CONFITLS.INI diferente do token atual"
    return 1
  }

  step_ok "Validando gravações finais"
}

# Run systemctl restart $SERVICE_NAME with a 60-second timeout guard.
# Returns the exit code of systemctl / timeout.
_restart_service(){
  log "AÇÃO: systemctl restart $SERVICE_NAME"
  if command -v timeout >/dev/null 2>&1; then
    timeout 60 systemctl restart "$SERVICE_NAME" >>"$AUDIT_TMP" 2>&1
  else
    systemctl restart "$SERVICE_NAME" >>"$AUDIT_TMP" 2>&1
  fi
}

restart_and_wait_service(){
  step_enter "Reiniciando serviço TEF"

  local active_state sub_state
  log_kv "SERVICE_NAME" "$SERVICE_NAME"

  local _svc_restart_rc
  _restart_service
  _svc_restart_rc=$?
  if (( _svc_restart_rc != 0 )); then
    step_fail "Falha no systemctl restart (rc=${_svc_restart_rc})"
    return 1
  fi

  for _ in {1..20}; do
    if systemctl is-active --quiet "$SERVICE_NAME"; then
      active_state="$(systemctl show -p ActiveState --value "$SERVICE_NAME" 2>>"$AUDIT_TMP" || true)"
      sub_state="$(systemctl show -p SubState --value "$SERVICE_NAME" 2>>"$AUDIT_TMP" || true)"
      log_kv "SERVICE_ACTIVE_STATE" "$active_state"
      log_kv "SERVICE_SUB_STATE" "$sub_state"
      step_ok "Reiniciando serviço TEF"
      return 0
    fi

    if systemctl is-failed --quiet "$SERVICE_NAME"; then
      log "SERVICE: estado failed"
      systemctl status "$SERVICE_NAME" --no-pager >>"$AUDIT_TMP" 2>&1 || true
      step_fail "Reiniciando serviço TEF"
      return 1
    fi

    sleep 1
  done

  active_state="$(systemctl show -p ActiveState --value "$SERVICE_NAME" 2>>"$AUDIT_TMP" || true)"
  sub_state="$(systemctl show -p SubState --value "$SERVICE_NAME" 2>>"$AUDIT_TMP" || true)"
  log_kv "SERVICE_ACTIVE_STATE_FINAL" "$active_state"
  log_kv "SERVICE_SUB_STATE_FINAL" "$sub_state"
  systemctl status "$SERVICE_NAME" --no-pager >>"$AUDIT_TMP" 2>&1 || true

  step_fail "Reiniciando serviço TEF"
  return 1
}

step_prepare_tls_runtime_for_test(){
  step_enter "Preparando ambiente TLS para teste"

  validate_all || {
    step_fail "Validação final do ambiente TLS falhou"
    return 1
  }

  restart_and_wait_service || {
    step_fail "Falha ao reiniciar serviço TEF"
    return 1
  }

  step_ok "Preparando ambiente TLS para teste"
}

step_reset_tls_control(){
  step_enter "Removendo controle TLS anterior"

  local ctrl="/opt/checkout/clisitef/NaoExcluirControleCliSiTef"

  if [[ -e "$ctrl" ]]; then
    log_kv "TLS_CONTROL_ANTES" "$ctrl"

    if [[ -d "$ctrl" ]]; then
      log "TLS_CONTROL_TIPO=diretorio"
      rm -rf "$ctrl" >>"$AUDIT_TMP" 2>&1 || {
        step_fail "Não foi possível remover diretório de controle TLS anterior"
        return 1
      }
      log "TLS_CONTROL_REMOVIDO_TIPO=diretorio"
    else
      log "TLS_CONTROL_TIPO=arquivo"
      rm -f "$ctrl" >>"$AUDIT_TMP" 2>&1 || {
        step_fail "Não foi possível remover arquivo de controle TLS anterior"
        return 1
      }
      log "TLS_CONTROL_REMOVIDO_TIPO=arquivo"
    fi
  else
    log "TLS_CONTROL_INEXISTENTE=1"
  fi

  if [[ -e "$ctrl" ]]; then
    step_fail "Controle TLS ainda existe após remoção"
    return 1
  fi

  step_ok "Removendo controle TLS anterior"
}

step_restart_socket_after_control_reset(){
  step_enter "Reiniciando serviço socket após remover controle"

  local _svc_ctrl_rc
  _restart_service
  _svc_ctrl_rc=$?
  if (( _svc_ctrl_rc != 0 )); then
    step_fail "Falha ao reiniciar serviço socket após remover controle (rc=${_svc_ctrl_rc})"
    return 1
  fi

  wait_socket_ready "$HOST_DEFAULT" "$PORT_DEFAULT" 15 1 || {
    step_fail "Socket não ficou disponível após reinício"
    return 1
  }

  step_ok "Reiniciando serviço socket após remover controle"
}

step_prepare_tls_runtime_for_new_token(){
  step_enter "Preparando ambiente TLS para novo token"

  step_prepare_tls_runtime_for_test || {
    step_fail "Falha na preparação base do ambiente TLS"
    return 1
  }

  step_reset_tls_control || {
    step_fail "Falha ao remover controle TLS anterior"
    return 1
  }

  step_restart_socket_after_control_reset || {
    step_fail "Falha ao subir socket após reset do controle"
    return 1
  }

  step_ok "Preparando ambiente TLS para novo token"
}

step_prepare_tls_for_existing_token_test(){
  step_enter "Preparando ambiente TLS para testar token atual"

  local flag="" token_banco="" conf_token="" conf_tipo="" conf_url="" conf_secao=""

  local _raw_tb=""
  _raw_tb="$(mysql_scalar "SELECT ${TLS_COL_TOKEN} FROM ${TLS_TABLE} WHERE tlsloja=0 AND ${TLS_COL_CAIXA}=${NUM_CAIXA} LIMIT 1;")" || {
    step_fail "Falha ao ler token do banco para validação"
    return 1
  }
  token_banco="$(printf '%s' "$_raw_tb" | tr -d '[:space:]')"

  [[ "$token_banco" =~ ^[0-9]{4}(-[0-9]{4}){3}$ ]] || {
    step_fail "Token do banco em formato inválido"
    return 1
  }

  TOKEN_TLS="$token_banco"
  log_kv_masked "TOKEN_BANCO_MASKED" "$TOKEN_TLS"

  flag="$(sqlite_scalar "SELECT habilita_tef_confiTLS FROM configuracao_pdv LIMIT 1;")"
  log_kv "CHECK_TLS_FLAG_ATUAL" "$flag"

  if [[ "$flag" != "1" ]]; then
    log "AÇÃO: habilitando modo TLS"
    step_set_flag_tls || {
      step_fail "Falha ao habilitar modo TLS"
      return 1
    }
  fi

  if [[ -f "$CONFITLS_INI" ]]; then
    conf_secao="$(grep -Fx '[ConfiguracaoTLS]' "$CONFITLS_INI" | head -n1 || true)"
    conf_tipo="$(sed -n 's/^TipoComunicacaoExterna=//p' "$CONFITLS_INI" | head -n1 | tr -d '[:space:]')"
    conf_url="$(sed -n 's/^URLTLS=//p' "$CONFITLS_INI" | head -n1 | tr -d '[:space:]')"
    conf_token="$(sed -n 's/^TokenRegistro=//p' "$CONFITLS_INI" | head -n1 | tr -d '[:space:]')"
  else
    conf_secao=""
    conf_tipo=""
    conf_url=""
    conf_token=""
  fi

  log_kv "CHECK_CONFITLS_EXISTE" "$([[ -f "$CONFITLS_INI" ]] && echo 1 || echo 0)"
  log_kv "CHECK_CONFITLS_SECAO_OK" "$([[ "$conf_secao" == "[ConfiguracaoTLS]" ]] && echo 1 || echo 0)"
  log_kv "CHECK_CONFITLS_TIPO" "$conf_tipo"
  log_kv "CHECK_CONFITLS_URL" "$conf_url"
  log_kv "CHECK_CONFITLS_TOKEN_MASKED" "$(mask_secret "$conf_token")"

  if [[ ! -f "$CONFITLS_INI" || "$conf_secao" != "[ConfiguracaoTLS]" || "$conf_tipo" != "TLSGWP" || "$conf_url" != "tls-prod.fiservapp.com" || "$conf_token" != "$TOKEN_TLS" ]]; then
    log "AÇÃO: recriando CONFITLS.INI com conteúdo íntegro"
    write_confitls_ini || {
      step_fail "Falha ao recriar CONFITLS.INI"
      return 1
    }
  fi

  step_prepare_tls_runtime_for_test || return 1

  step_ok "Preparando ambiente TLS para testar token atual"
}

step_switch_to_gsurf(){
  step_enter "Retornando modo de transação para GSurf"

  local res tmp_bkp tmp_ini

  # Atomically write CONFITLS_BKP.INI (copy of current or empty sentinel).
  tmp_bkp="$(mktemp "${CONFITLS_BKP_INI}.XXXXXX")" || {
    step_fail "Falha ao criar temporário para CONFITLS_BKP.INI"
    return 1
  }
  chmod 0644 "$tmp_bkp" 2>/dev/null || true

  if [[ -f "$CONFITLS_INI" ]]; then
    cp -a "$CONFITLS_INI" "$tmp_bkp" || {
      rm -f "$tmp_bkp" 2>/dev/null || true
      step_fail "Falha ao copiar CONFITLS.INI para temporário de backup"
      return 1
    }
  fi
  # tmp_bkp is either a copy of CONFITLS_INI or an empty file (sentinel).

  mv -f "$tmp_bkp" "$CONFITLS_BKP_INI" || {
    rm -f "$tmp_bkp" 2>/dev/null || true
    step_fail "Falha ao mover temporário para $CONFITLS_BKP_INI"
    return 1
  }
  chmod 0644 "$CONFITLS_BKP_INI" 2>/dev/null || true
  log "CONFITLS_BKP_GERADO=$CONFITLS_BKP_INI"

  # Atomically replace CONFITLS.INI with an empty file.
  tmp_ini="$(mktemp "${CONFITLS_INI}.XXXXXX")" || {
    step_fail "Falha ao criar temporário para CONFITLS.INI vazio"
    return 1
  }
  chmod 0644 "$tmp_ini" 2>/dev/null || true
  mv -f "$tmp_ini" "$CONFITLS_INI" || {
    rm -f "$tmp_ini" 2>/dev/null || true
    step_fail "Falha ao substituir CONFITLS.INI por arquivo vazio"
    return 1
  }
  chmod 0644 "$CONFITLS_INI" 2>/dev/null || true
  log "CONFITLS_INI_LIMPO=1"

  sqlite_exec_retry "UPDATE configuracao_pdv SET habilita_tef_confiTLS=0;" || {
    step_fail "UPDATE habilita_tef_confiTLS=0"
    return 1
  }

  res="$(sqlite_scalar "SELECT habilita_tef_confiTLS FROM configuracao_pdv LIMIT 1;")"
  log_kv "habilita_tef_confiTLS" "$res"

  [[ "$res" == "0" ]] || {
    step_fail "Flag GSurf não confirmada"
    return 1
  }

  restart_and_wait_service || {
    step_fail "Falha ao reiniciar serviço TEF no modo GSurf"
    return 1
  }

  step_ok "Retornando modo de transação para GSurf"
}

# =========================================================
# SOCKET / TESTE DE COMUNICAÇÃO
# =========================================================

NC_CLOSE_MODE=""
NC_TIMEOUT_SEC="${NC_TIMEOUT_SEC:-10}"

is_transient_socket_message(){
  local msg="${1:-}"

  [[ -z "$msg" ]] && return 0

  case "$msg" in
    "Conectando Servidor") return 0 ;;
    "Servidor Conectado") return 0 ;;
    "v."*"Selecione a opcao desejada") return 0 ;;
    "1:Teste de comunicacao"*) return 0 ;;
  esac

  return 1
}

pick_socket_host_port() {
  step_enter "Configurando socket SiTef"
  HOST="${HOST:-$HOST_DEFAULT}"
  PORT="${PORT:-$PORT_DEFAULT}"
  log_kv "HOST" "$HOST"
  log_kv "PORT" "$PORT"
  step_ok "Configurando socket SiTef"
}

derive_idterm() {
  step_enter "Derivando IDTERM"
  local ck
  ck="$(pad_left "$NUM_CAIXA" 6)" || return 1
  IDTERM="CK${ck}"
  log_kv "IDTERM" "$IDTERM"
  step_ok "Derivando IDTERM"
}

derive_idloja_fmt() {
  step_enter "Formatando IDLOJA"
  [[ -n "${IDLOJA_TEF:-}" && "$IDLOJA_TEF" =~ ^[0-9]+$ ]] || return 1
  IDLOJA="$(pad_left "$IDLOJA_TEF" 8)"
  log_kv "IDLOJA" "$IDLOJA"
  step_ok "Formatando IDLOJA"
}

derive_parmsclient() {
  step_enter "Montando PARMSCLIENT"
  [[ -n "${CNPJ_LOJA:-}" && "$CNPJ_LOJA" =~ ^[0-9]{14}$ ]] || return 1
  PARMS="[ParmsClient=1=${CNPJ_LOJA};2=${CNPJ_SH_FIX}]"
  log_kv "PARMS" "$PARMS"
  step_ok "Montando PARMSCLIENT"
}

validate_collected() {
  step_enter "Validando dados do teste TLS"
  [[ -n "${HOST:-}" && -n "${PORT:-}" ]] || return 1
  [[ -n "${IDLOJA:-}" && -n "${IDTERM:-}" && -n "${PARMS:-}" ]] || return 1
  [[ -n "${TOKEN_TLS:-}" ]] || return 1
  step_ok "Validando dados do teste TLS"
}

ensure_operador_fiscal() {
  step_enter "Garantindo fiscal/operador HIPCOM"

  local db="$1"
  [[ -f "$db" ]] || return 1
  sqlite_has_table "$db" "fiscal"   || return 1
  sqlite_has_table "$db" "operador" || return 1

  local attempt
  for ((attempt=1; attempt<=8; attempt++)); do
    if sqlite3 "$db" ".timeout 5000" >>"$AUDIT_TMP" 2>&1 <<'SQL'
BEGIN IMMEDIATE;
INSERT INTO fiscal (codigo, codigoLoja, nome, senha, permiteLeituraX, permiteClienteRestricao, permiteLimiteTrocoUltrapassado, permiteDesconto, permiteCancelarItem, permiteLimiteCompraUltrapassada, percentualDescontoMaximo, permiteCancelarCupom, permiteCancelarUltimoCupom)
SELECT '999', 0, 'HIPCOM', '123789', 1, 1, 0, 0, 1, 0, 0.00, 1, 1 WHERE NOT EXISTS (SELECT 1 FROM fiscal WHERE codigo='999' AND codigoLoja=0 AND nome='HIPCOM');
INSERT INTO operador (codigo, nome, senha, loja, cpf)
SELECT '999', 'HIPCOM', '989', 0, NULL WHERE NOT EXISTS (SELECT 1 FROM operador WHERE codigo='999' AND loja=0 AND nome='HIPCOM');
COMMIT;
SQL
    then
      step_ok "Garantindo fiscal/operador HIPCOM"
      return 0
    fi
    log "WARN: tentativa ${attempt}/8 falhou ao garantir fiscal/operador"
    sleep 0.5
  done

  step_fail "Garantindo fiscal/operador HIPCOM"
  return 1
}

detect_nc_close_mode(){
  local nc_help
  nc_help="$(nc -h 2>&1 || true)"
  NC_CLOSE_MODE=""
  if printf '%s\n' "$nc_help" | grep -qE '(^|[[:space:]])-N([[:space:]]|,|$)'; then
    NC_CLOSE_MODE="-N"
  elif printf '%s\n' "$nc_help" | grep -qE '(^|[[:space:]])-q([[:space:]]|,|$)'; then
    NC_CLOSE_MODE="-q 0"
  fi
  log "NC_CLOSE_MODE=${NC_CLOSE_MODE:-(vazio - sem flag de fechamento automatico)}"
}

jcall() {
  local host="$1" port="$2" method="$3" id="$4" params="$5"
  local payload out rc
  payload='{"method":"'"$method"'","id":"'"$id"'","params":'"$params"'}'

  # shellcheck disable=SC2086
  # Separate stdout from stderr so nc diagnostic messages do not get parsed as
  # JSON.  A /dev/null fallback for mktemp protects against disk-full.
  local _nc_err_tmp
  _nc_err_tmp="$(mktemp 2>/dev/null)" || _nc_err_tmp="/dev/null"
  out="$(printf '%s' "$payload" | nc -w "${NC_TIMEOUT_SEC}" ${NC_CLOSE_MODE} "${host}" "${port}" 2>"$_nc_err_tmp")"
  rc=$?
  if (( rc != 0 )); then
    local _nc_err_msg
    _nc_err_msg="$(head -n3 "$_nc_err_tmp" 2>/dev/null | tr '\n' ' ')"
    [[ "$_nc_err_tmp" != "/dev/null" ]] && rm -f "$_nc_err_tmp" 2>/dev/null || true
    log "JCALL_ERROR: method=${method} id=${id} rc=${rc} stderr=${_nc_err_msg}"
    printf 'nc_fail: %s' "$_nc_err_msg"
    return 2
  fi
  [[ "$_nc_err_tmp" != "/dev/null" ]] && rm -f "$_nc_err_tmp" 2>/dev/null || true

  # Guard: rc==0 but empty response is still a failure for JSON callers.
  if [[ -z "$out" ]]; then
    log "JCALL_EMPTY_RESPONSE: method=${method} id=${id} rc=0 but output was empty"
    printf 'nc_fail: empty response'
    return 2
  fi

  printf '%s' "$out"
}

set_buf0() { local h="$1" p="$2"; jcall "$h" "$p" "setString" "set0" '{"index":0,"value":"'"$3"'"}' >/dev/null || true; }
clr_buf()  { local h="$1" p="$2"; jcall "$h" "$p" "clearBuffer" "clr" '{}' >/dev/null || true; }
buf_get0() { local h="$1" p="$2"; jcall "$h" "$p" "bufferGet" "bg0" '{"index":0}' | extract_str result | head -n1 || true; }

finaliza() {
  local h="$1" p="$2" confirma="$3"
  log "SOCKET: finalizaFuncaoSiTefInterativo(confirma=$confirma)"

  jcall "$h" "$p" "finalizaFuncaoSiTefInterativo" "fin" \
'{"horaFiscal":"'"$HORAFISC"'","confirma":'"$confirma"',"dataFiscal":"'"$DATAFISC"'","paramAdic":"","cupomFiscal":"'"$CUPOM"'"}' >/dev/null || true
}

prepare_test_context(){
  step_enter "Preparando contexto do teste TLS"

  pick_socket_host_port || return 1
  derive_idterm || return 1
  derive_idloja_fmt || return 1
  derive_parmsclient || return 1

  DATAFISC="$(date +%Y%m%d)"
  HORAFISC="$(date +%H%M%S)"
  CUPOM="$HORAFISC"

  ensure_operador_fiscal "$DB_IN" || return 1
  validate_collected || return 1

  step_ok "Preparando contexto do teste TLS"
}

wait_socket_ready(){
  step_enter "Aguardando socket SiTef ficar disponível"

  local host="$1" port="$2" tries="${3:-30}" delay="${4:-1}"
  local i

  for ((i=1; i<=tries; i++)); do
    if nc -z -w "${NC_TIMEOUT_SEC}" "$host" "$port" >/dev/null 2>&1; then
      log "SOCKET_READY: disponível em $host:$port na tentativa $i/$tries"
      step_ok "Aguardando socket SiTef ficar disponível"
      return 0
    fi

    log "SOCKET_READY: indisponível em $host:$port na tentativa $i/$tries"
    sleep "$delay"
  done

  step_fail "Aguardando socket SiTef ficar disponível"
  return 1
}

# Resolve TEST_RESULT_MSG from the last useful or raw socket message.
# Accepts an optional fallback string as $1.
_resolve_test_result_msg(){
  local fallback="${1:-Falha na comunicação TLS}"
  if [[ -n "$LAST_USEFUL_SOCKET_MSG" ]]; then
    TEST_RESULT_MSG="$LAST_USEFUL_SOCKET_MSG"
  elif [[ -n "$LAST_SOCKET_MSG" ]]; then
    TEST_RESULT_MSG="$LAST_SOCKET_MSG"
  else
    TEST_RESULT_MSG="$fallback"
  fi
}

# run_test_once MODO HOST PORT [INITIAL_PCT]
#
# Executa um ciclo completo de teste SiTef no modo informado (TLS ou GSURF).
# Define TEST_RESULT_MSG com a mensagem final do socket.
# Define SKIP_ROLLBACK=1 quando o resultado é definitivo (res<0 ou timeout) —
# sinaliza ao die() que o rollback não deve ser executado e que o operador
# deve decidir entre manter TLS ou voltar para GSurf.
#
# Códigos de retorno:
#   0  — sucesso (res=0, TEST_RESULT_MSG="Servidor Ativo")
#  10  — socket indisponível antes do teste
#  11  — configuraIntSiTefInterativoEx falhou
#  12  — iniciaFuncaoSiTefInterativo falhou
#  13  — 5 leituras inválidas consecutivas do socket
#  21  — resultado negativo (res<0) do servidor
#  40  — timeout (MAX_LOOPS esgotado)

run_test_once() {
  local modo="$1"
  local host="$2" port="$3"
  local initial_pct="${4:-5}"
  local socket_ready_pct=$(( initial_pct + 5 ))

  step_enter "Executando teste real de comunicação ${modo}"
  ui_progress "$initial_pct" "${UI_TEST_LABEL:-Testando Comunicação}"

  LAST_SOCKET_MSG=""
  LAST_USEFUL_SOCKET_MSG=""
  SKIP_ROLLBACK=0
  LAST_UI_LOOP_PCT=""

  log_kv "MAX_LOOPS" "$MAX_LOOPS"
  log_kv "SLEEP_SEC" "$SLEEP_SEC"
  log_kv "NC_TIMEOUT_SEC" "$NC_TIMEOUT_SEC"
  log_kv "TEST_TIMEOUT_MIN_ESTIMADO_SEG" "$(echo "$MAX_LOOPS $SLEEP_SEC" | awk '{printf "%d", $1 * $2}')"
  log_kv "TEST_TIMEOUT_MAX_ESTIMADO_SEG" "$(echo "$MAX_LOOPS $SLEEP_SEC $NC_TIMEOUT_SEC" | awk '{printf "%d", $1 * ($2 + $3)}')"

  if ! wait_socket_ready "$host" "$port" 10 1; then
    log "SOCKET: indisponível em $host:$port após aguardar readiness"
    TEST_RESULT_MSG="Socket não responde"
    ui_finish_progress
    step_fail "Executando teste real de comunicação ${modo}"
    return 10
  fi

  log "SOCKET: porta respondeu em $host:$port"
  ui_progress "$socket_ready_pct" "${UI_TEST_LABEL:-Testando Comunicação}"

  local cfg_payload
  cfg_payload='{"reservado":0,"parametrosAdicionais":"'"$PARMS"'","idTerminal":"'"$IDTERM"'","ipSiTef":"'"$host"'","idLoja":"'"$IDLOJA"'"}'

  local CFG_REPLY cfg_success cfg_result
  CFG_REPLY="$(jcall "$host" "$port" "configuraIntSiTefInterativoEx" "cfg" "$cfg_payload" || true)"
  log_socket_call "CONFIGURA" "$cfg_payload" "$CFG_REPLY"

  cfg_success="$(printf '%s\n' "$CFG_REPLY" | sed -n 's/.*"success":\([^,}]*\).*/\1/p' | head -n1 | tr -d '[:space:]')"
  cfg_result="$(printf '%s\n' "$CFG_REPLY" | extract_int result | head -n1 || true)"

  [[ "$cfg_success" == "true" && "$cfg_result" == "0" ]] || {
    log "SOCKET_CONFIGURA_INVALIDA=1"
    log "SOCKET_CONFIGURA_SUCCESS=$cfg_success"
    log "SOCKET_CONFIGURA_RESULT=$cfg_result"
    TEST_RESULT_MSG="Falha ao configurar comunicação SiTef"
    ui_finish_progress
    step_fail "Executando teste real de comunicação ${modo}"
    return 11
  }

  local ini_payload
  ini_payload='{"funcao":110,"horaFiscal":"'"$HORAFISC"'","paramAdic":"{DevolveStringQRCode=1}","cupomFiscal":"'"$CUPOM"'","valor":"0","dataFiscal":"'"$DATAFISC"'","operador":"'"$OPERADOR"'"}'

  local INI_REPLY ini_success ini_result
  INI_REPLY="$(jcall "$host" "$port" "iniciaFuncaoSiTefInterativo" "ini" "$ini_payload" || true)"
  log_socket_call "INICIA" "$ini_payload" "$INI_REPLY"

  ini_success="$(printf '%s\n' "$INI_REPLY" | sed -n 's/.*"success":\([^,}]*\).*/\1/p' | head -n1 | tr -d '[:space:]')"
  ini_result="$(printf '%s\n' "$INI_REPLY" | extract_int result | head -n1 || true)"

  [[ "$ini_success" == "true" && "$ini_result" =~ ^-?[0-9]+$ ]] || {
    log "SOCKET_INICIA_INVALIDA=1"
    log "SOCKET_INICIA_SUCCESS=$ini_success"
    log "SOCKET_INICIA_RESULT=$ini_result"
    TEST_RESULT_MSG="Falha ao iniciar função SiTef"
    ui_finish_progress
    step_fail "Executando teste real de comunicação ${modo}"
    return 12
  }

  local cmd=0 tipo=0 tmin=0 tmax=0
  local selected_menu_test=0
  local loops=0
  local invalid_reads=0
  local gsurf_retry_visual=0
  local loop_base_pct="$socket_ready_pct"
  local loop_max_pct=90

  if [[ "$modo" == "GSURF" ]]; then
    loop_max_pct=95
  else
    loop_max_pct=85
  fi

  LAST_STATE_SNAPSHOT=""

  local i cont_payload cont_reply res msg
  local next_res next_cmd next_tipo next_tmin next_tmax

  for ((i=1; i<=MAX_LOOPS; i++)); do
    loops="$i"

    # Verifica se o usuário clicou em "Cancelar/Abortar" na barra de progresso.
    # kill -0 falha se o processo já morreu, indicando que o usuário abortou.
    if (( UI_OK == 1 )) && [[ -n "${ZENITY_PID:-}" ]] && ! kill -0 "${ZENITY_PID}" 2>/dev/null; then
      log "ABORTO_USUARIO: janela de progresso fechada durante loop ${loops} do modo ${modo}"
      _handle_user_abort
      # _handle_user_abort chama exit; esta linha nunca é atingida.
    fi

    ui_progress_test_loop "$loops" "$loop_base_pct" "$loop_max_pct"
    sleep "$SLEEP_SEC"

    cont_payload='{"tamMaximo":{"value":'"${tmax:-0}"'},"comando":{"value":'"${cmd:-0}"'},"tamMinimo":{"value":'"${tmin:-0}"'},"continua":0,"tamBuffer":1024,"tipoCampo":{"value":'"${tipo:-0}"'}}'

    cont_reply="$(jcall "$host" "$port" "continuaFuncaoSiTefInterativo" "cont" "$cont_payload" || true)"
    log_socket_call "CONTINUA_LOOP_${loops}" "$cont_payload" "$cont_reply"

    next_res="$(printf '%s\n' "$cont_reply" | extract_int result | head -n1 || true)"
    next_cmd="$(printf '%s\n' "$cont_reply" | extract_int comando | head -n1 || true)"
    next_tipo="$(printf '%s\n' "$cont_reply" | extract_int tipoCampo | head -n1 || true)"
    next_tmin="$(printf '%s\n' "$cont_reply" | extract_int tamMinimo | head -n1 || true)"
    next_tmax="$(printf '%s\n' "$cont_reply" | extract_int tamMaximo | head -n1 || true)"

    if [[ -z "${next_res:-}" || -z "${next_cmd:-}" || -z "${next_tipo:-}" ]]; then
      invalid_reads=$(( invalid_reads + 1 ))
      log "SOCKET_INVALID_READ_COUNT=$invalid_reads"

      # Mensagem de retry visual — exclusiva para modo GSURF, nas 3 primeiras
      # respostas inválidas/vazias. Não afeta a lógica real do teste.
      if [[ "$modo" == "GSURF" ]]; then
        gsurf_retry_visual=$(( gsurf_retry_visual + 1 ))
        log "GSURF_RETRY_VISUAL=$gsurf_retry_visual"
        if (( gsurf_retry_visual <= 3 )); then
          ui_send "${gsurf_retry_visual} Teste falhou, testando a comunicação novamente..."
        fi
      fi

      if (( invalid_reads >= 5 )); then
        SKIP_ROLLBACK=1
        TEST_RESULT_MSG="Resposta inválida do socket"
        log "SOCKET_RESULT_FINAL=ERRO"
        log "SOCKET_RESULT_FINAL_RES=invalid_read"
        log "SOCKET_LAST_USEFUL_MSG=$LAST_USEFUL_SOCKET_MSG"
        log "SOCKET_LAST_MSG=$LAST_SOCKET_MSG"
        finaliza "$host" "$port" 0
        ui_finish_progress
        step_fail "Executando teste real de comunicação ${modo}"
        return 13
      fi

      continue
    fi

    invalid_reads=0
    res="$next_res"
    cmd="${next_cmd:-0}"
    tipo="${next_tipo:-0}"
    tmin="${next_tmin:-0}"
    tmax="${next_tmax:-0}"

    state_maybe_log "$loops" "${res:-<vazio>}" "${cmd:-<vazio>}" "${tipo:-<vazio>}" "${tmin:-<vazio>}" "${tmax:-<vazio>}"
    log "SOCKET_LOOP_${loops}_STATE: res=${res:-<vazio>} cmd=${cmd:-<vazio>} tipo=${tipo:-<vazio>} tmin=${tmin:-<vazio>} tmax=${tmax:-<vazio>}"

    msg="$(buf_get0 "$host" "$port" || true)"
    msg="${msg:-}"
    msg="$(normalize_socket_message "$msg")"
    log "SOCKET_LOOP_${loops}_MSG: ${msg:-<vazia>}"

    if [[ -n "${msg:-}" ]]; then
      LAST_SOCKET_MSG="$msg"
      log "SOCKET_MSG: $msg"

      if ! is_transient_socket_message "$msg"; then
        LAST_USEFUL_SOCKET_MSG="$msg"
        log "SOCKET_LAST_USEFUL_MSG_AT_LOOP_${loops}: $LAST_USEFUL_SOCKET_MSG"
      elif [[ "$msg" == *"127.0.0.1"* || "$msg" == *"tls-prod.fiservapp.com"* ]]; then
        LAST_USEFUL_SOCKET_MSG="$msg"
        log "SOCKET_LAST_USEFUL_MSG_AT_LOOP_${loops}: $LAST_USEFUL_SOCKET_MSG"
      fi

      if [[ "$selected_menu_test" == "0" ]] && printf '%s\n' "$msg" | grep -q '1:Teste de comunicacao'; then
        log "SOCKET_DECISAO: selecionou menu 'Teste de comunicacao' (opção 1)"
        clr_buf "$host" "$port"
        set_buf0 "$host" "$port" "1"
        selected_menu_test=1
        continue
      fi

      if printf '%s\n' "$msg" | grep -qiE '^Confirma o teste de comunicacao .*fiservapp\.com'; then
        log "SOCKET_MARCO: confirmação do teste TLS detectada"
        clr_buf "$host" "$port"
        set_buf0 "$host" "$port" "0"
        log "SOCKET_DECISAO: confirmação TLS enviada (opção 0)"
        continue
      fi

      if printf '%s\n' "$msg" | grep -qiE '^Confirma o teste de comunicacao .*127\.0\.0\.1'; then
        log "SOCKET_MARCO: confirmação do teste GSURF detectada"
        clr_buf "$host" "$port"
        set_buf0 "$host" "$port" "0"
        log "SOCKET_DECISAO: confirmação GSURF enviada (opção 0)"
        continue
      fi
    fi

    if [[ -n "${res:-}" && "$res" =~ ^-?[0-9]+$ ]]; then
      if (( res == 0 )); then
        log "SOCKET_RESULT_FINAL=SUCESSO"
        log "SOCKET_RESULT_FINAL_RES=$res"
        finaliza "$host" "$port" 1
        TEST_RESULT_MSG="Servidor Ativo"
        ui_finish_progress
        step_ok "Executando teste real de comunicação ${modo}"
        return 0
      fi

      if (( res < 0 )); then
        SKIP_ROLLBACK=1
        log "SOCKET_RESULT_FINAL=ERRO"
        log "SOCKET_RESULT_FINAL_RES=$res"
        log "SOCKET_LAST_USEFUL_MSG=$LAST_USEFUL_SOCKET_MSG"
        log "SOCKET_LAST_MSG=$LAST_SOCKET_MSG"

        finaliza "$host" "$port" 0
        _resolve_test_result_msg "Falha na comunicação TLS"
        ui_finish_progress
        step_fail "Executando teste real de comunicação ${modo}"
        return 21
      fi
    fi
  done

  SKIP_ROLLBACK=1
  log "SOCKET_FINAL: Timeout (MAX_LOOPS=$MAX_LOOPS)"
  log "SOCKET_LAST_USEFUL_MSG=$LAST_USEFUL_SOCKET_MSG"
  log "SOCKET_LAST_MSG=$LAST_SOCKET_MSG"

  finaliza "$host" "$port" 0
  _resolve_test_result_msg "Timeout"
  ui_finish_progress
  step_fail "Executando teste real de comunicação ${modo}"
  return 40
}
run_integrated_tls_test(){
  local initial_pct="${1:-5}"
  step_enter "Executando teste integrado TLS"
  prepare_test_context || return 1
  run_test_once "TLS" "$HOST" "$PORT" "$initial_pct"
}

step_validate_final_mode(){
  local modo="$1"
  local host_teste="127.0.0.1"
  local esperado=""
  local msg=""

  FINAL_MODE_TEST_OK=0
  FINAL_MODE_TEST_MSG=""

  step_enter "Validando modo final escolhido"

  case "$modo" in
    GSURF) esperado="127.0.0.1" ;;
    TLS)   esperado="tls-prod.fiservapp.com" ;;
    *)
      step_fail "Modo final inválido: $modo"
      FINAL_MODE_TEST_MSG="Modo final inválido"
      return 1
      ;;
  esac

  LAST_SOCKET_MSG=""
  LAST_USEFUL_SOCKET_MSG=""
  TEST_RESULT_MSG=""

  prepare_test_context || {
    step_fail "Falha ao preparar contexto para validação final"
    FINAL_MODE_TEST_MSG="Falha ao preparar contexto"
    return 1
  }

  if ! run_test_once "$modo" "$host_teste" "$PORT_DEFAULT" 65; then
    msg="${LAST_USEFUL_SOCKET_MSG:-${LAST_SOCKET_MSG:-${TEST_RESULT_MSG:-Sem retorno}}}"
    FINAL_MODE_TEST_MSG="$msg"
    log "VALIDACAO_FINAL_RC_FALHOU: modo=${modo} msg=${msg}"
    step_fail "Falha ao validar modo final escolhido"
    return 1
  fi

  # run_test_once retornou 0 (res=0): TEST_RESULT_MSG é "Servidor Ativo".
  # NÃO usar LAST_USEFUL_SOCKET_MSG aqui — pode ser mensagem intermediária
  # desatualizada (ex.: "Sem conexao Servidor") que não reflete o resultado final.
  msg="${TEST_RESULT_MSG:-Servidor Ativo}"
  log "VALIDACAO_FINAL_RC_OK: modo=${modo} msg=${msg}"

  case "$modo" in
    GSURF)
      [[ "$msg" == *"127.0.0.1"* || "$msg" == "Servidor Ativo" || "$msg" == "Sem conexao Servidor" ]] || {
        FINAL_MODE_TEST_MSG="$msg"
        step_fail "Modo GSurf não confirmado"
        return 1
      }
      ;;
    TLS)
      [[ "$msg" == *"tls-prod.fiservapp.com"* || "$msg" == "Servidor Ativo" ]] || {
        FINAL_MODE_TEST_MSG="$msg"
        step_fail "Modo TLS não confirmado"
        return 1
      }
      ;;
  esac

  FINAL_MODE_TEST_OK=1
  FINAL_MODE_TEST_MSG="$msg"

  log_kv "VALIDACAO_FINAL_MODO" "$modo"
  log_kv "VALIDACAO_FINAL_ESPERADO" "$esperado"
  log_kv "VALIDACAO_FINAL_MSG" "$msg"

  step_ok "Validando modo final escolhido"
}

# =========================================================
# MAIN
# =========================================================

log_sep
log "INICIO DA EXECUÇÃO DO INSTALATLS"
log_kv "SCRIPT_DIR" "$SCRIPT_DIR"
log_kv "PDV_OUT_DB" "$PDV_OUT_DB"
log_kv "DB_IN" "$DB_IN"
log_kv "SERVICE_NAME" "$SERVICE_NAME"
log_kv "USUARIO_EXECUCAO" "$(id -un)"
log_kv "UID_EXECUCAO" "$(id -u)"

bootstrap_dependencies

for c in sqlite3 mysql base64 zenity systemctl sudo getent who awk sed tr head id find mktemp chmod mv rm nc grep cut date; do
  need_cmd "$c"
done

detect_nc_close_mode
check_gui_requirements || die "Ambiente gráfico indisponível"
check_sqlite_integrity || die "Falha de integridade no banco SQLite"

ui_step_min "Coletando dados básicos do PDV" step_collect_cfg || die "Falha ao validar dados do PDV"
ui_step_min "Validando estrutura de banco" check_required_schema || die "Estrutura de banco inválida ou incompleta"
ui_step_min "Coletando e armazenando contexto TLS" step_finalize_tls_context || die "Falha ao coletar contexto TLS"
ui_step_min "Capturando estado original" capture_original_state || die "Falha ao capturar estado original"
ui_step_min "Verificando token existente" step_collect_existing_token || die "Falha ao verificar token existente"

if [[ -n "${TOKEN_ATUAL_BANCO:-}" ]]; then
  ui_choose_existing_or_new_token || die "Falha na seleção do token"
else
  log "FLUXO=sem_token_existente"
fi

if (( MODO_TESTE_TOKEN_ATUAL == 0 )); then
  ui_show_initial_info || die "Falha ao exibir identificação do PDV"
  step_ask_token || die "Token inválido"
fi

UI_TEST_LABEL="Testando Comunicação | TLS"
ui_start

if (( MODO_TESTE_TOKEN_ATUAL == 1 )); then
  # Fluxo: token existente — prepara/valida ambiente e executa teste.
  # Barra:  8% (preparação: leitura banco, flag, CONFITLS, restart)
  #       → 20% (início do loop de teste TLS)
  #       → 25% (socket pronto, imediatamente após wait_socket_ready)
  #       → 85% (fim do loop — ease-out quadrático entre 25%–85%)
  #       → 99% (ui_finish_progress ao fim do run_test_once)
  log "MODO=teste_token_atual_com_prechecagem_tls"
  ui_progress 8 "Preparando ambiente TLS"
  ui_step_min "Preparando ambiente TLS" step_prepare_tls_for_existing_token_test || die "Falha ao preparar ambiente TLS"
  UI_TEST_LABEL="Testando Comunicação | TLS"
  ui_step_min "Executando teste de comunicação" run_integrated_tls_test 20 || die "${TEST_RESULT_MSG:-Teste TLS falhou}"
else
  # Fluxo: novo token — grava flag, token, CONFITLS, reinicia serviço, testa.
  # Barra:  5% (flag SQLite — operação rápida ~100 ms)
  #       → 15% (token MySQL — transação DELETE+INSERT)
  #       → 22% (CONFITLS.INI — gravação atômica via mktemp+mv)
  #       → 28% (2x restart + wait_socket: etapa mais lenta ~10–40 s no total,
  #               pois step_prepare_tls_runtime_for_new_token faz restart +
  #               reset_control + restart novamente)
  #       → 35% (início do loop de teste TLS)
  #       → 40% (socket pronto, imediatamente após wait_socket_ready)
  #       → 85% (fim do loop — ease-out quadrático entre 40%–85%)
  #       → 99% (ui_finish_progress ao fim do run_test_once)
  ui_progress 5 "Ajustando modo TLS"
  ui_step_min "Ajustando modo TLS" step_set_flag_tls || die "Falha ao ajustar modo TLS"
  ui_progress 15 "Registrando Token"
  ui_step_min "Registrando Token" step_write_mysql || die "Falha ao gravar token"
  ui_progress 22 "Gerando arquivo CONFITLS"
  ui_step_min "Gerando arquivo CONFITLS" write_confitls_ini || die "Falha ao gerar o CONFITLS"
  # step_prepare_tls_runtime_for_new_token performs: validate_all + 2 restarts
  # (with wait_socket_ready each), which can take 10–40 s total.  Send two
  # intermediate progress updates so the bar does not stall visually at 28%.
  # The sub-function is called via ui_step_min so its stdout/stderr still go to
  # AUDIT_TMP and the UI message reflects what is happening.
  ui_progress 28 "Reiniciando serviço TEF (1/2)"
  ui_step_min "Preparando ambiente TLS" step_prepare_tls_runtime_for_new_token || die "Falha ao preparar ambiente TLS"
  # Advance to 33% after the prepare phase completes so the operator sees the
  # bar move before the test loop begins at 35%.
  ui_progress 33 "Serviço reiniciado"
  UI_TEST_LABEL="Testando Comunicação | TLS"
  ui_step_min "Testando a comunicação" run_integrated_tls_test 35 || die "${TEST_RESULT_MSG:-Teste TLS falhou}"
fi

ROLLBACK_ENABLED=0

if ui_ask_return_to_gsurf "${TEST_RESULT_MSG:-Resultado final}"; then
  # Fluxo GSurf:
  #   60% — início da fase GSurf (barra "avança" em vez de regredir de 99%→0%)
  #   60–64% — step_switch_to_gsurf (gravação arquivos + restart + wait_socket)
  #   65%    — início do loop de teste GSurf (run_test_once initial_pct=65)
  #   65–95% — ease-out quadrático do loop GSurf
  #   99%    — ui_finish_progress ao fim do run_test_oncef
  ui_progress 60 "Retornando para GSurf"
  ui_step_min "Retornando método de transação para GSurf" step_switch_to_gsurf || die "Falha ao retornar para GSurf"
  # Marca 64% após o switch concluído (restart incluso) para que o operador
  # veja progresso antes do loop de teste começar em 65%.
  ui_progress 64 "Iniciando teste GSurf"
  UI_TEST_LABEL="Testando Comunicação | Gsurf"
  ui_step_min "Testando comunicação via GSurf" step_validate_final_mode GSURF || true

  if [[ "${FINAL_MODE_TEST_OK:-0}" == "1" ]]; then
    ui_show_final_result "Teste de comunicação OK | ${FINAL_MODE_TEST_MSG:-Sem retorno} | modo GSurf"
  else
    ui_show_final_result "Teste de comunicação falhou | ${FINAL_MODE_TEST_MSG:-Sem retorno} | modo GSurf"
  fi
else
  if [[ "${TEST_RESULT_MSG:-}" == "Servidor Ativo" ]]; then
    ui_show_final_result "Teste de comunicação OK | ${TEST_RESULT_MSG:-Sem retorno} | modo TLS"
  else
    ui_show_final_result "Teste de comunicação falhou | PDV não está com o modo TLS ativo (tls-prod.fiservapp.com)"
  fi
fi

exit 0
