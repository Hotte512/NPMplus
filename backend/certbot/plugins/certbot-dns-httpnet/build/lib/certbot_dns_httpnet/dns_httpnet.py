"""DNS Authenticator for http.net, limited to an allowlist of zones."""

import logging
import re
from typing import Any, Callable, Optional

import requests
from certbot import errors
from certbot.plugins import dns_common
from certbot.plugins.dns_common import CredentialsConfiguration

logger = logging.getLogger(__name__)

DEFAULT_API_URL = "https://partner.http.net/api/dns/v1/json"
TTL = 60


def parse_zones(value: Optional[str]) -> list[str]:
    """Split a comma and/or whitespace separated zone list into normalised names."""
    return [z.strip().strip(".").lower() for z in re.split(r"[\s,]+", value or "") if z.strip().strip(".")]


def in_zones(domain: str, zones: list[str]) -> bool:
    """True if domain is one of zones or a subdomain of one of them."""
    domain = domain.strip(".").lower()
    return any(domain == z or domain.endswith("." + z) for z in zones)


class Authenticator(dns_common.DNSAuthenticator):
    """DNS Authenticator for http.net

    Only domains inside dns_httpnet_allowed_zones are touched, everything else is refused
    before any API call is made.
    """

    description = "Obtain certificates using a DNS TXT record (if you are using http.net for DNS)."

    def __init__(self, *args: Any, **kwargs: Any) -> None:
        super().__init__(*args, **kwargs)
        self.credentials: Optional[CredentialsConfiguration] = None

    @classmethod
    def add_parser_arguments(cls, add: Callable[..., None], default_propagation_seconds: int = 120) -> None:
        super().add_parser_arguments(add, default_propagation_seconds)
        add("credentials", help="http.net credentials INI file.")

    def more_info(self) -> str:
        return "This plugin configures a DNS TXT record to respond to a dns-01 challenge using the http.net DNS API."

    def _validate_credentials(self, credentials: CredentialsConfiguration) -> None:
        if not parse_zones(credentials.conf("allowed_zones")):
            raise errors.PluginError(
                f"{credentials.confobj.filename}: dns_httpnet_allowed_zones must list at least one zone "
                "(e.g. dns_httpnet_allowed_zones = example.com, example.org)"
            )

    def _setup_credentials(self) -> None:
        self.credentials = self._configure_credentials(
            "credentials",
            "http.net credentials INI file",
            {"api_token": "API key of the http.net account", "allowed_zones": "zones this key may change"},
            self._validate_credentials,
        )

    def _perform(self, domain: str, validation_name: str, validation: str) -> None:
        self._get_client().add_txt_record(domain, validation_name, validation)

    def _cleanup(self, domain: str, validation_name: str, validation: str) -> None:
        self._get_client().del_txt_record(domain, validation_name, validation)

    def _get_client(self) -> "HttpNetClient":
        if not self.credentials:  # pragma: no cover
            raise errors.Error("Plugin has not been prepared.")
        return HttpNetClient(
            self.credentials.conf("api_token"),
            parse_zones(self.credentials.conf("allowed_zones")),
            self.credentials.conf("api_url") or DEFAULT_API_URL,
        )


class HttpNetClient:
    """Minimal client for the http.net DNS API."""

    def __init__(self, api_token: str, allowed_zones: list[str], api_url: str = DEFAULT_API_URL) -> None:
        self.api_token = api_token
        self.allowed_zones = allowed_zones
        self.api_url = api_url.rstrip("/")
        self.session = requests.Session()

    def _call(self, method: str, payload: dict) -> dict:
        try:
            r = self.session.post(f"{self.api_url}/{method}", json={"authToken": self.api_token, **payload}, timeout=60)
            r.raise_for_status()
            data = r.json()
        except (requests.RequestException, ValueError) as e:
            raise errors.PluginError(f"http.net API {method} failed: {e}")
        if data.get("status") not in ("success", "pending"):
            msgs = "; ".join(f"{e.get('code')}: {e.get('text')}" for e in data.get("errors") or []) or "unknown error"
            raise errors.PluginError(f"http.net API {method} failed: {msgs}")
        return data

    def _check_allowed(self, domain: str, validation_name: str) -> None:
        for name in (domain, validation_name):
            if not in_zones(name, self.allowed_zones):
                raise errors.PluginError(
                    f"{name} is not inside the allowed zones ({', '.join(self.allowed_zones)}), refusing to change it"
                )

    def _find_zone(self, domain: str) -> tuple[str, str]:
        """Returns (zoneConfigId, zone name) of the closest allowed zone containing domain."""
        for guess in dns_common.base_domain_name_guesses(domain):
            if not in_zones(guess, self.allowed_zones):
                continue
            data = self._call("zoneConfigsFind", {"filter": {"field": "ZoneName", "value": guess}, "limit": 1})
            zones = data.get("response", {}).get("data") or []
            if zones:
                return zones[0]["id"], guess
        raise errors.PluginError(f"no http.net zone found for {domain} within the allowed zones")

    def _update(self, zone_id: str, add: list, delete: list) -> None:
        self._call(
            "recordsUpdate",
            {"zoneConfigId": zone_id, "recordsToAdd": add, "recordsToModify": [], "recordsToDelete": delete},
        )

    def add_txt_record(self, domain: str, validation_name: str, validation: str) -> None:
        self._check_allowed(domain, validation_name)
        zone_id, zone = self._find_zone(domain)
        logger.debug("adding TXT %s in zone %s", validation_name, zone)
        self._update(zone_id, [{"name": validation_name, "type": "TXT", "content": validation, "ttl": TTL}], [])

    def del_txt_record(self, domain: str, validation_name: str, validation: str) -> None:
        try:
            self._check_allowed(domain, validation_name)
            zone_id, _ = self._find_zone(domain)
            data = self._call(
                "recordsFind",
                {
                    "filter": {
                        "subFilterConnective": "AND",
                        "subFilter": [
                            {"field": "ZoneConfigId", "value": zone_id},
                            {"field": "RecordName", "value": validation_name},
                            {"field": "RecordType", "value": "TXT"},
                        ],
                    },
                    "limit": 100,
                },
            )
            records = [
                {"id": rec["id"], "name": rec["name"], "type": "TXT", "content": rec["content"]}
                for rec in data.get("response", {}).get("data") or []
                if rec.get("content", "").strip('"') == validation
            ]
            if records:
                self._update(zone_id, [], records)
        except errors.PluginError as e:
            logger.warning("could not remove TXT record %s: %s", validation_name, e)
