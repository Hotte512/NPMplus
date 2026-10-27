# certbot-dns-httpnet

Certbot DNS-01 authenticator for the [http.net DNS API](https://www.http.net/docs/api/), installed by NPMplus from
this directory when "http.net" is chosen as DNS provider.

```ini
dns_httpnet_api_token = YOUR_HTTP_NET_API_KEY
# required: only these zones (and their subdomains) may be changed
dns_httpnet_allowed_zones = example.com, example.org
# optional, default https://partner.http.net/api/dns/v1/json
# dns_httpnet_api_url = https://partner.http.net/api/dns/v1/json
```

Every domain is checked against `dns_httpnet_allowed_zones` before any API call, other domains are refused.
Additionally create a dedicated API key in the http.net panel that only has the DNS rights
`zoneConfigsFind`, `recordsFind` and `recordsUpdate` and, if possible, restrict it to the public IP of NPMplus.
