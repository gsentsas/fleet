# GST Fleetbase — S98-R12 Plesk privacy shadow gate

Candidate source SHA: 573689e53a7fc0ab6c90e7901c3fd58d596c2376.
This plan lives on an isolated test branch, not the candidate PR #11.

## Current confirmed risk
The three Plesk vhosts fleet.globalsentransport.fr, api-fleet.globalsentransport.fr and ws-fleet.globalsentransport.fr have default Nginx combined access logging. Their HTTP-to-HTTPS redirect preserves the query string; Navigator pairing has a bearer token in the query. This is a configuration exposure RISK, not a confirmed real secret leak. No real log entries were read.

## Shadow generator
Run scripts/rc1-s98-r12-plesk-logging-shadow.py with --out set to a newly created EMPTY directory under /tmp on the authorized Plesk host. It never installs anything, never reconfigures Plesk or reloads Nginx, and fails on an unfamiliar Plesk default template SHA or an existing custom template.

The outputs in that temporary directory are:

- templates/custom/domain/nginxDomainVirtualHost.php: optional future persistent Plesk custom template; chooses a queryless access_log format only for the three Fleetbase hostnames and returns 403 rather than redirecting a plaintext Navigator bearer-token URL.
- conf.d/aa900_gst_fleet_safe_logging.conf: queryless Nginx log_format in http context, using method, normalized URI path, response status, size and duration, excluding args and Referer.
- vhosts/<domain>/vhost_nginx.conf: additional exact HTTPS Navigator route with per-location error log guard. Its ACL allow/deny, upstream, headers and timeouts are cloned exactly from the original location, so the new location cannot silently bypass preproduction access restrictions.
- report.txt: read-only evidence and hashes.

## Before applying anything to active Plesk

The entire shadow output must be independently reviewed. Copying a custom Plesk domain template can affect ALL domains when Plesk regenerates configuration. Back up current generated configs, default and any custom templates, current nginx -T, and all three vhost configs. Perform a non-active Plesk rendering proof, PHP syntax checks and Nginx syntax checks. Use SYNTHETIC unique bearer markers to test HTTP and HTTPS proxy access/error logs (including upstream errors) and preserve all access restrictions. Confirm non-Fleetbase vhosts unchanged; check TLS, standard redirects, WebSocket upgrade, uptime, Host forwarding and logging observability. Obtain an explicit infrastructure GO before any install or reconfigure. Do not edit Plesk-generated nginx.conf directly.

If user approval for infrastructure change is granted after these gates: use a documented Plesk-supported persistent custom template mechanism and staged per-domain reconfigure only as permitted; verify effective config; keep the restoration plan. A successful php -l or nginx -t does not prove safe real log behavior.

Current decision: PLESK_ACTIVE_CONFIG_UNCHANGED; HTTP/HTTPS_LOG_PRIVACY_NOT_PROVEN; MOBILE/FCM_NOT_PROVEN; PRODUCTION_NO_GO.

Official references:
- https://docs.plesk.com/en-US/obsidian/advanced-administration-guide-linux/virtual-hosts-configuration/changing-virtual-hosts-settings-using-configuration-templates.68693/
- https://nginx.org/en/docs/http/ngx_http_log_module.html
