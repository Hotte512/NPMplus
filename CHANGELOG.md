# Changelog

Alle Änderungen an NPMplus · Hotte. Format angelehnt an [Keep a Changelog](https://keepachangelog.com/de/1.1.0/),
Einträge nach Datum. Upstream-Änderungen stehen im [NPMplus-Repository](https://github.com/ZoeyVid/NPMplus).

## 2026-10-28

### Behoben
- **Sicherheit:** Der UniFi-API-Key konnte im Log (Konsole und Log-Viewer) erscheinen, wenn das Speichern der
  Einstellung an einem Datenbankfehler scheiterte. API-Keys werden jetzt in allen Logzeilen maskiert. Wer den Key
  im Log gesehen hat, sollte ihn im UniFi-Gateway neu erzeugen.

## 2026-10-27

### Neu
- **UniFi Local DNS:** lokale DNS-Einträge für Proxy-Hosts auf einem UniFi-Gateway (Ziel: NPMplus-Adresse,
  Ziel-Host oder eigenes Ziel), Einstellungsseite mit Übersicht aller Einträge und „Jetzt synchronisieren“,
  DNS-Badge in der Host-Liste, Statuszeile im Proxy-Host-Dialog.
- **UniFi Local DNS:** einstellbare TTL, Standard „Auto“ wie in der UniFi-Oberfläche.
- **UniFi Local DNS:** vorhandene identische Einträge werden übernommen statt als Konflikt gemeldet.
- **http.net** als DNS-Anbieter für Let's-Encrypt-DNS-Challenges, beschränkt auf erlaubte Zonen.
- **ACME-Weiterleitung:** eigener Port für Challenges am Ziel-Host.
- **Hotte-Logo** im Header und im Seitentitel.
- **Proxy-Host-Tabelle:** kompakte zweizeilige Darstellung, Spalten ein-/ausblendbar.

### Geändert
- Hotte-Logo neu gestaltet: petrolfarbenes „H“-Monogramm.
- ACME-Weiterleitung an das neue Upstream-Verfahren angepasst: erst das Ziel fragen, bei Fehler antwortet NPMplus.
- Build: baut den Feature-Branch unverändert, Upstream wird gezielt übernommen; wöchentlicher Neubau am Sonntag.

### Behoben
- UniFi Local DNS: Einträge wurden abgelehnt, weil die TTL fehlte.
- Log-Viewer: die eigenen Abfragen des Log-Viewers tauchten im Textfilter auf.

### Upstream
- Basis auf `develop` `50adf2a8` aktualisiert (u. a. zustandslose ACME-Challenges, Dateien unter `/data/nginx`).

## 2026-10-26

### Neu
- **Proxy-Hosts:** Beschreibung, Tags, Sortierung nach Basis-Domain, Gruppierung (Gruppe, Basis-Domain, Ziel, Tag).
- **ACME-Weiterleitung:** http-01-Challenges optional an das Ziel weiterleiten.
- **Log-Viewer** für nginx-, Certbot- und NPMplus-Logs.
- Nächtlicher Build des eigenen Images `ghcr.io/hotte512/npmplus:hotte-main`.
