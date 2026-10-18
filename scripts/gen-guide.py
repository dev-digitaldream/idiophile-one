#!/usr/bin/env python3
"""Writes docs/USER-GUIDE.md and docs/USER-GUIDE.fr.md from the in-app help (App/Help/HelpView.swift),
so the online guide and the Help window never disagree."""
import re
from pathlib import Path

root = Path(__file__).resolve().parent.parent
swift = (root / "App/Help/HelpView.swift").read_text()
string = r'"((?:[^"\\]|\\.)*)"'


# Screenshots (docs/images) shown under each section, by section id: (file, caption EN, caption FR)
IMAGES = {
    "start": [("library-songs.png", "The library: songs view.", "La bibliothèque : vue Morceaux.")],
    "rack": [("rack-blue-glass.png", "The full rack, Blue Glass finish.", "La chaîne complète, finition Blue Glass."),
             ("finishes.png", "The three finishes: Champagne, Black, Blue Glass.", "Les trois finitions : Champagne, Black, Blue Glass."),
             ("compact.png", "The compact player.", "Le mini-lecteur.")],
    "sources": [("library-radio.png", "Internet radio: streams grouped by station, best quality chosen for you.",
                 "Radio internet : flux regroupés par station, meilleure qualité choisie pour vous."),
                ("network.png", "A DLNA / UPnP server browsed from the Network source.",
                 "Un serveur DLNA / UPnP parcouru depuis la source Network.")],
    "quality": [("audio-path-live.png", "Audio Path: every step from file to DAC, read live.",
                 "Audio Path : chaque étape du fichier au DAC, lue en direct.")],
    "eq": [("eq-editor.png", "The parametric editor with the Compare (A/B) bar.", "L'éditeur paramétrique avec la barre Compare (A/B).")],
    "analysis": [("audio-path.png", "Audio Path with the equalizer and the DAC volume in play.",
                  "Audio Path avec l'égaliseur et le volume du DAC en jeu.")],
    "trouble": [("help.png", "The built-in help (Help › Idiophile One Help), in English and French.",
                 "L'aide intégrée (Help › Idiophile One Help), en anglais et en français.")],
}

MENUS_EN = (
    "Menus", [
        "**File**: Open… (⌘O) · Library (⌘L) · Close (⌘W) · Close All (⌥⌘W)",
        "**View**: Full Rack (⌘1) · Amplifier Only (⌘2) · Compact Player (⌥⌘M) · Network Player (⌘3) · Equalizer (⌘4) · Amplifier (⌘5) · Animate VU Meters · Animate Spectrum Analyzer · Small (⌘-) / Medium (⌘0) / Large (⌘=) · Fit Screen (⌃⌘F) · Finish ▸ Champagne, Black, Blue Glass",
        "**Output**: Output Device ▸ (System Default and every device found) · Lock Output · Rate Change Delay ▸ · Volume Limit ▸ · Invert Polarity of This Track (⌥⌘I) / of All Tracks · Measure Library Loudness · ReplayGain ▸ Off, Track, Album · Equalizer Editor… (⌥⌘E) · Audio Path… (⌥⌘A) · Scan True Resolution… · Verify Bit-Perfect Path… (⌥⌘V) · Direct (⇧⌘B)",
        "**Playback**: Source ▸ Library (⌃1), Internet Radio (⌃2), Network (⌃3) · Play / Pause (Space) · Next Track (⌘→) · Previous Track (⌘←) · Mute (⇧⌘M) · Power Off (⇧⌘P) · Dimmer (⇧⌘D)",
        "**Window**: Compact Player · Library · Equalizer · Audio Path",
        "**Help**: Idiophile One Help (⌘?)",
        "**Right-click** on the rack or the compact player: the same playback, source, output, sound, appearance and analysis commands in one menu.",
    ])
MENUS_FR = (
    "Menus", [
        "**File** : Open… (⌘O) · Library (⌘L) · Close (⌘W) · Close All (⌥⌘W)",
        "**View** : Full Rack (⌘1) · Amplifier Only (⌘2) · Compact Player (⌥⌘M) · Network Player (⌘3) · Equalizer (⌘4) · Amplifier (⌘5) · Animate VU Meters · Animate Spectrum Analyzer · Small (⌘-) / Medium (⌘0) / Large (⌘=) · Fit Screen (⌃⌘F) · Finish ▸ Champagne, Black, Blue Glass",
        "**Output** : Output Device ▸ (System Default et chaque appareil trouvé) · Lock Output · Rate Change Delay ▸ · Volume Limit ▸ · Invert Polarity of This Track (⌥⌘I) / of All Tracks · Measure Library Loudness · ReplayGain ▸ Off, Track, Album · Equalizer Editor… (⌥⌘E) · Audio Path… (⌥⌘A) · Scan True Resolution… · Verify Bit-Perfect Path… (⌥⌘V) · Direct (⇧⌘B)",
        "**Playback** : Source ▸ Library (⌃1), Internet Radio (⌃2), Network (⌃3) · Play / Pause (Espace) · Next Track (⌘→) · Previous Track (⌘←) · Mute (⇧⌘M) · Power Off (⇧⌘P) · Dimmer (⇧⌘D)",
        "**Window** : Compact Player · Library · Equalizer · Audio Path",
        "**Help** : Idiophile One Help (⌘?)",
        "**Clic droit** sur la chaîne ou le mini-lecteur : les mêmes commandes de lecture, source, sortie, son, apparence et analyse dans un seul menu.",
    ])


def guide(name):
    body = swift[swift.index(f"static let {name} = HelpGuide("):]
    body = body[: body.index("\n    )\n")]
    title = re.search(r"title: " + string, body).group(1)
    intro = re.search(r"intro: " + string, body).group(1)
    sections = []
    for m in re.finditer(r'\.init\(id: "([^"]+)", icon: "[^"]+", title: ' + string + r", items: \[(.*?)\]\),", body, re.S):
        sections.append((m.group(2), [s.replace('\\"', '"') for s in re.findall(string, m.group(3))], m.group(1)))
    return title, intro, sections


def write(name, path, heading, note, menus, lang):
    title, intro, sections = guide(name)
    sections = sections + [(menus[0], menus[1], "menus")]
    out = [f"# {title} — {heading}", "", f"> {note}", "", intro, ""]
    out += [f"- [{t}](#{re.sub(r'[^a-z0-9 -]', '', t.lower()).replace(' ', '-')})" for t, _, _ in sections] + [""]
    for t, items, sid in sections:
        out += [f"## {t}", ""] + [f"- {i}" for i in items] + [""]
        for file, en, fr in IMAGES.get(sid, []):
            caption = en if lang == "en" else fr
            out += [f"![{caption}](images/{file})", f"*{caption}*", ""]
    (root / path).write_text("\n".join(out))


write("english", "docs/USER-GUIDE.md", "User Guide",
      "Generated from the in-app help (Help › Idiophile One Help) by `scripts/gen-guide.py`. Version française : [USER-GUIDE.fr.md](USER-GUIDE.fr.md).", MENUS_EN, "en")
write("french", "docs/USER-GUIDE.fr.md", "Guide d'utilisation",
      "Généré depuis l'aide intégrée (Help › Idiophile One Help) par `scripts/gen-guide.py`. English version: [USER-GUIDE.md](USER-GUIDE.md).", MENUS_FR, "fr")
