# Manette Wii U Pro sur Mac

Application qui connecte une manette Wii U Pro au Mac par le **Bluetooth interne** (sans dongle, sans pilote, sans Dolphin). La manette contrôle ensuite le **clavier et la souris** : chaque bouton tape la touche de votre choix et le stick droit déplace la souris.

Pourquoi clavier/souris et pas une « vraie » manette : macOS ne laisse créer une manette virtuelle qu'avec une autorisation spéciale d'Apple (entitlement `com.apple.developer.hid.virtual.device`), impossible avec un compte développeur gratuit (vérifié : `IOHIDUserDeviceCreate` est refusé, même lancé avec `sudo`). Voir [AUDIT-2026-10-28.md](AUDIT-2026-10-28.md).

## Compiler

```bash
./build.sh
```

Les Command Line Tools suffisent (Xcode non requis). Produit `build/WiiU Pro.app` (et l'outil `build/wiiu-pro-dsu`, voir plus bas).

Pour l'avoir dans le Launchpad : `cp -R "build/WiiU Pro.app" /Applications/`

## Utilisation

```bash
open "build/WiiU Pro.app"
```

1. **Autoriser** (une seule fois) : cliquez sur « Autoriser… », puis cochez « WiiU Pro » dans Réglages Système → Confidentialité et sécurité → **Accessibilité**. Le bandeau orange disparaît tout seul.
   *Après chaque recompilation (`./build.sh`), macOS considère l'app comme nouvelle : il faut la décocher puis la recocher.*
2. **Connecter la manette** : cliquez sur le bouton, puis appuyez sur **SYNC** (petit bouton rouge à l'arrière). Les appareils vus s'affichent dans « Appareils trouvés » ; si la manette y apparaît sans se connecter, cliquez sur « Connecter » à côté.
3. **Choisir les touches** : cliquez sur un bouton dans « Manette en direct » et choisissez la touche, le clic ou « Rien ». Les choix sont mémorisés.

Touches par défaut :

| Manette | Mac |
|---|---|
| A / B / X / Y | Entrée / Échap / Espace / Tab |
| L / R | Q / E |
| ZL / ZR | Clic droit / Clic gauche |
| − / + | Effacer / P |
| Croix et stick gauche | Flèches |
| Stick droit | Souris |

## En cas de problème

Le journal est aussi écrit dans `~/Library/Logs/WiiUPro.log` (recréé à chaque lancement). Cochez « Détails techniques » avant de refaire l'essai pour plus d'informations.

## Outil en ligne de commande (optionnel, pour Dolphin)

`build/wiiu-pro-dsu` publie la manette au format DSU (cemuhook) sur `127.0.0.1:26760`, lisible par Dolphin (Contrôleurs → Sources d'entrée alternatives → DSU Client). Ne pas le lancer en même temps que l'app.

```bash
./build/wiiu-pro-dsu --verbose
```

## Pas encore vérifié

- Connexion réelle à la manette et ordre des octets des boutons (repris du pilote Linux `hid-wiimote`).
- Reconnexion après extinction de la manette ; lancement automatique à l'ouverture de session.
