# GST Fleetbase RC1 — S98-R9: proxy token-log privacy

**State:** Docker ingress source-level hardening prepared. Plesk remains unsafe until independently remediated and tested. PRODUCTION = NO-GO.

## Read-only audit

On fleet.globalsentransport.fr, api-fleet.globalsentransport.fr and ws-fleet.globalsentransport.fr, generated Plesk nginx.conf enables access_log without an explicit format. Nginx 1.30.6 effective configuration contains no explicit log_format. Its standard combined format can record the full HTTP request and Referer, including a query such as a Navigator redemption token. HTTP-to-HTTPS redirects use request_uri, preserving query parameters. The RC1 Docker HTTPD image used default logging, and Console inherited default Nginx logging. No real tokens or log entries were read; this is an identified configuration risk, not proof of compromise.

## Changes on candidate branch

- Docker HTTPD: queryless format gst_fleet_safe records method, normalized path, protocol, status, bytes and duration, not request target, args or Referer.
- Docker HTTPD: exact Navigator link-app location suppresses Nginx error log request lines for that bearer-capability endpoint; queryless access log still records status and timing. The pairing proxy uses the exact same upstream and Host forwarding as the default proxy route.
- Console Nginx: same queryless access log format.
- Static security test: scripts/rc1-s98-r9-proxy-log-safety-proof.py, run by the locked RC1 security workflow whenever either ingress config changes.

These changes create a NEW source commit and invalidate previously built image artifacts under cc959ac. Previous artifacts remain historical evidence only, not production release images.

## Plesk host-level remediation — still required

Do not edit generated Plesk nginx.conf in place. Use Plesk-supported persistent customization/templates reviewed for this Plesk version. The HTTPS proxy uses a custom location from vhost_nginx.conf; the generated HTTP server separately redirects using request_uri. Both need privacy-safe access and error logging. A log_format must be defined in http context and the effective access_log chosen at the correct server/location scope. Adding a second access_log at the same level may duplicate rather than override logs. Ensure the default combined logger does not survive for the Navigator endpoint.

The security requirements for all Fleetbase traffic ingress are:
1. Access logs retain status and timing but do not include request, request_uri, args, query_string, Referer, Authorization, cookies, mobile deep-link keys or unredacted query values.
2. The exact Navigator redemption route must not write query-bearing error log request lines during upstream failures. Preserve safe status observability without leaking bearer URLs.
3. Review HTTP redirect behavior. Do not send bearer links over plaintext HTTP. Do not blindly change redirect semantics for unrelated applications or break legitimate query-dependent operations.
4. Before any Plesk reload, back up the effective configuration, validate Nginx syntax, and test synthetic token probes on both HTTP and HTTPS plus upstream-error paths. Check every Plesk, Docker and app log sink for the synthetic marker **without displaying any real secrets**.
5. Validate the usual routes, auth, Host headers, websocket upgrades and status/error observability in QA. Document tested configuration and exact rollback. Do not purge historical logs or rotate actual keys without incident-response authorization.

**Gate:** Docker static log safety can pass while Plesk remains blocked. PLESK_PROXY_REDACTION=NOT_PROVEN; MOBILE/FCM=NOT_PROVEN; QA E2E=NOT_RUN; PRODUCTION=NO-GO.
