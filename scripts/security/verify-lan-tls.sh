#!/usr/bin/env bash
# Verifica una puerta Caddy LAN ya iniciada; no instala certificados ni toca la base.
set -euo pipefail
saludu_host="${SALUDU_LAN_HOST:-127.0.0.1}"
saludu_http="${SALUDU_HTTP_PORT:-8088}"
saludu_https="${SALUDU_HTTPS_PORT:-8443}"
saludu_ca="${SALUDU_CA_FILE:?Indica el certificado público de la CA interna}"
[[ -f "$saludu_ca" ]] || { printf 'No existe el certificado CA.\n' >&2; exit 2; }
saludu_url="https://$saludu_host:$saludu_https"
saludu_redirect=$(curl --noproxy '*' -sS -o /dev/null -w '%{http_code} %{redirect_url}' "http://$saludu_host:$saludu_http/iniciar-sesion")
[[ "$saludu_redirect" == "301 $saludu_url/iniciar-sesion" ]] || { printf 'Redirección inesperada: %s\n' "$saludu_redirect" >&2; exit 1; }
printf 'Redirección: %s\n' "$saludu_redirect"
saludu_verify=(-verify_hostname "$saludu_host")
if [[ "$saludu_host" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then saludu_verify=(-verify_ip "$saludu_host"); fi
for saludu_version in tls1_2 tls1_3; do
  printf '\nProtocolo %s:\n' "$saludu_version"
  openssl s_client -connect "$saludu_host:$saludu_https" -servername "$saludu_host" -"$saludu_version" -CAfile "$saludu_ca" "${saludu_verify[@]}" -verify_return_error -brief </dev/null 2>&1
 done
printf '\nRechazo de TLS 1.1 por el servidor:\n'
if saludu_old=$(openssl s_client -connect "$saludu_host:$saludu_https" -tls1_1 -cipher 'DEFAULT:@SECLEVEL=0' -brief </dev/null 2>&1); then
  printf 'TLS 1.1 fue aceptado inesperadamente.\n' >&2; exit 1
fi
printf '%s\n' "$saludu_old"
[[ "$saludu_old" == *"alert protocol version"* ]] || { printf 'No se pudo confirmar el rechazo por el servidor.\n' >&2; exit 1; }
printf '\nEncabezados HTTPS:\n'
saludu_headers=$(curl --noproxy '*' --cacert "$saludu_ca" -fsSI "$saludu_url/iniciar-sesion")
printf '%s\n' "$saludu_headers"
for saludu_required in 'strict-transport-security:' 'x-content-type-options:' 'x-frame-options:' 'content-security-policy:' 'referrer-policy:'; do
  [[ "${saludu_headers,,}" == *"$saludu_required"* ]] || { printf 'Falta %s\n' "$saludu_required" >&2; exit 1; }
done
printf '\nReadiness:\n'
curl --noproxy '*' --cacert "$saludu_ca" -fsS "$saludu_url/actuator/health/readiness"
printf '\nAPI a través de Next:\n'
curl --noproxy '*' --cacert "$saludu_ca" -fsS "$saludu_url/api/health"
printf '\nVerificación de cliente y CA aprobada.\n'
