# stakeless-cpanel

Installationsskript för [Stakeless](https://github.com/CZ140/Stakeless) (casino med låtsaspengar) på en cPanel/WHM-server, för **casino.labnat.se**.

## Installera / uppdatera skriptet på servern

```bash
curl -fsSL https://raw.githubusercontent.com/scoutante112/stakeless-cpanel/main/install-stakeless-cpanel.sh -o install-stakeless-cpanel.sh
chmod +x install-stakeless-cpanel.sh
```

## Kommandon

| Kommando | Vad det gör |
|---|---|
| `./install-stakeless-cpanel.sh` | Installerar allt (Docker, app, subdomän, Apache-proxy, AutoSSL) |
| `./install-stakeless-cpanel.sh update` | Hämtar senaste Stakeless och bygger om |
| `./install-stakeless-cpanel.sh admin <namn>` | Gör en användare till admin |
| `./install-stakeless-cpanel.sh chips <namn> <antal>` | Ger (eller tar) chips |
| `./install-stakeless-cpanel.sh lock` / `unlock` | Låser sidan så bara du kommer in / öppnar igen |
| `./install-stakeless-cpanel.sh proxy` | Skriver om Apache-proxyn |
| `./install-stakeless-cpanel.sh logs` / `stop` | Loggar / stoppa |

## chips-admin.php

En enkel PHP-sida för att dela ut chips. Lägg den t.ex. i `public_html/chips/index.php` på labnat-kontot och logga in med ditt admin-konto från casinot.

> Alla chips är låtsaspengar utan värde. De kan inte köpas eller växlas in.
