import SwiftUI

/// User guide in English and French, opened from Help › Idiophile One Help.
struct HelpView: View {
    enum Language: String, CaseIterable, Identifiable {
        case english = "en", french = "fr"
        var id: String { rawValue }
        var name: String { self == .english ? "English" : "Français" }
    }

    @AppStorage("helpLanguage") private var language: Language =
        Locale.current.language.languageCode?.identifier == "fr" ? .french : .english
    @State private var selection: String?

    var body: some View {
        let guide = language == .english ? HelpContent.english : HelpContent.french
        NavigationSplitView {
            List(guide.sections, selection: $selection) { section in
                Label(section.title, systemImage: section.icon).tag(section.id)
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 210)
        } detail: {
            ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    Text(guide.title).font(.largeTitle.weight(.semibold))
                    Text(guide.intro).font(.title3).foregroundStyle(.secondary)
                    ForEach(guide.sections) { section in
                        VStack(alignment: .leading, spacing: 10) {
                            Label(section.title, systemImage: section.icon).font(.title2.weight(.semibold))
                            ForEach(section.items, id: \.self) { item in
                                Text(LocalizedStringKey(item))
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .id(section.id)
                    }
                }
                .padding(32)
                .frame(maxWidth: 760, alignment: .leading)
                .textSelection(.enabled)
            }
            .onChange(of: selection) { _, id in
                guard let id else { return }
                withAnimation { proxy.scrollTo(id, anchor: .top) }
            }
            }
        }
        .toolbar {
            Picker("Language", selection: $language) {
                ForEach(Language.allCases) { Text($0.name).tag($0) }
            }
            .pickerStyle(.segmented)
        }
        .frame(minWidth: 760, minHeight: 520)
    }
}

struct HelpGuide {
    struct Section: Identifiable {
        let id: String
        let icon: String
        let title: String
        let items: [String]
    }

    let title: String
    let intro: String
    let sections: [Section]
}

/// Guide text. Items use Markdown (bold, code) rendered by `Text`.
enum HelpContent {
    static let english = HelpGuide(
        title: "Idiophile One",
        intro: "A bit-perfect music player for macOS, built like a hi-fi rack: network player, integrated amplifier and graphic equalizer.",
        sections: [
            .init(id: "start", icon: "play.circle", title: "Getting started", items: [
                "Drop audio files or folders on the rack, or press **⏏** / **⌘O**. Folders are read recursively and sorted by name.",
                "**Space** plays or pauses. **⌘→** / **⌘←** go to the next or previous track. The keyboard media keys, headset buttons and Control Center work too.",
                "Supported: FLAC, ALAC, WAV, AIFF, MP3, AAC. Tags and covers embedded in FLAC files are read; otherwise a `cover.jpg` / `folder.jpg` next to the files is used.",
            ]),
            .init(id: "rack", icon: "rectangle.stack", title: "The rack", items: [
                "**Network player** (top): cover, title, artist, album, the signal path and the next tracks.",
                "**Amplifier** (middle): VU meters, input selector, volume and the panel keys.",
                "**Graphic equalizer** (bottom): ten faders and a spectrum analyser.",
                "Keep only what you want: **⌘3** network player, **⌘5** amplifier and **⌘4** equalizer each show or hide on their own (at least one stays). **View › Animate VU Meters** and **Animate Spectrum Analyzer** freeze the meters at rest while keeping them in view: with both cut the full rack uses about 3 % of a core.",
                "View menu: **⌘1** full rack, **⌘2** amplifier only, **⌘3** / **⌘4** / **⌘5** show or hide each unit. **⌘-** / **⌘0** / **⌘=** small, medium, large; **⌃⌘F** fits the screen.",
                "View › Finish: **Champagne**, **Black** or **Blue Glass**.",
                "Drag the rack by any bare part of a front panel.",
                "**Right-click** anywhere on the rack or the compact player for the full menu: playback, source, output, sound, appearance and analysis.",
                "**Compact Player** (⌥⌘M) is a slim player for when you work. It draws nothing animated and uses about 2 % of a processor core.",
            ]),
            .init(id: "sources", icon: "antenna.radiowaves.left.and.right", title: "Sources and radio", items: [
                "The **INPUT** knob and **Playback › Source** (⌃1 / ⌃2 / ⌃3) really switch the source. **LIB** returns to your library queue where it stopped, **RADIO** plays the last station, **NET** opens your media servers. A source with nothing to play opens its browser instead.",
                "**Internet radio** (Library window › Internet Radio): favourites, popular stations, your country, genres and search. Star a station to keep it; drag favourites to reorder them.",
                "A station often has several streams. Idiophile One groups them and plays the **best one**: it weighs codec and bitrate (AAC 128 beats MP3 128), skips dead or HLS streams when it can, and prefers https. Choose *Best*, *Balanced* (up to 128 kbps) or *Light* (up to 64 kbps), or turn automatic choice off. The **N streams** menu on a row lets you pick one by hand.",
                "Radio goes through the same engine as files, so the meters, the equalizer and the DAC clock apply. It is never bit-perfect.",
                "**Network** (Library window › Network): DLNA / UPnP media servers on your network are found automatically. A server out of reach of discovery (VPN, another subnet) can be added by name or address. Some NAS only serve devices they have allowed: on a QNAP, allow this Mac in DLNA Media Server › Media Receivers.",
            ]),
            .init(id: "amp", icon: "dial.medium", title: "Amplifier controls", items: [
                "**POWER** fades the lamps out and quits. The volume is remembered.",
                "**VOLUME**: turn it by dragging around the knob, with the scroll wheel (up = louder), or with the keyboard volume keys. When the DAC has its own volume control, the knob drives it directly, so the samples stay untouched.",
                "**DIRECT** takes the shortest path: equalizer and ReplayGain out, exclusive access to the DAC (other apps and system sounds are muted on it).",
                "**METER** switches between **VU** (classic 300 ms ballistics) and **PEAK** (fast attack, slow fall).",
                "**DIMMER** sets the backlight: full, warm, or deep.",
                "The **BIT-PERFECT** lamp lights when the file reaches the DAC unaltered.",
            ]),
            .init(id: "quality", icon: "waveform", title: "Sound quality", items: [
                "Choose your DAC in the **Output** menu. A DAC plugged in later appears automatically.",
                "The DAC clock follows each file's sample rate, so nothing is resampled. If the DAC can't play that rate, the player shows **RESAMPLED**.",
                "The DAC is set to its deepest integer format (for example 24-bit) so no bits are lost.",
                "BIT-PERFECT requires: DIRECT on, the same rate and enough bits on the DAC, and the volume on the DAC (or the knob fully up).",
                "The MacBook's built-in speakers apply their own processing: use an external DAC for a true bit-perfect path.",
            ]),
            .init(id: "eq", icon: "slider.vertical.3", title: "Equalizer", items: [
                "Each output device keeps its own equalizer setting: headphones and speakers want different curves. A new device starts flat.",
                "**EDIT** (or Output › Equalizer Editor, ⌥⌘E) opens the **parametric editor**: up to 20 filters (peak, low or high shelf, low or high pass, notch) with frequency, gain and Q, a preamp, and the response curve. **PARAM** switches between the faders and your parametric profile; with the profile in use, the rack shows its curve instead of the faders.",
                "**Headphone correction**: Presets › Headphones (built-in) has ready-made profiles. To add yours, drop one or several AutoEq / Equalizer APO `.txt` files on the editor, use Presets › Import, or copy the filter list and choose **Paste Filters from Clipboard** (`Preamp: -6.2 dB`, `Filter 1: ON PK Fc 100 Hz Gain -3 dB Q 0.7`). Imported files become saved presets. Your own settings can be saved and exported in the same format.",
                "**Compare (A/B)**: in the editor, load a profile in **A** and another in **B**, then switch with **A**, **B**, **Off** (keys 1, 2, 3) while the music plays. **Same loudness** lowers the louder choice to the level of the quieter one, so you judge the curve, not the volume. Switches are ramped: no click.",
                "A boost never clips: the loudest point of the curve is held at 0 dB by an automatic headroom (an AutoEq preamp already provides it). A flat equalizer changes nothing, to the last bit.",
                "Drag a fader or scroll over it; double-click returns it to 0 dB.",
                "**BYPASS** removes the equalizer; **FLAT** resets every band. A pre-gain is applied automatically when you boost, to avoid clipping.",
                "In DIRECT the equalizer is out (**EQ OUT · DIRECT**). Touching a fader or BYPASS leaves DIRECT.",
            ]),
            .init(id: "analysis", icon: "chart.xyaxis.line", title: "Analysis and trust", items: [
                "**Audio Path** (Output › Audio Path, ⌥⌘A) lists every step from file to DAC, read live: each is transparent, alters the signal, or cannot be verified. **Verify** compares the samples sent to Core Audio with the file, one by one.",
                "**True resolution** (Scan in the same panel) reads the spectrum and the bits actually used: it shows a 96 kHz file that is really a 44.1 kHz master, a low-pass typical of MP3/AAC, or 16-bit content in a 24-bit file.",
                "**Loudness** is measured in the background for every track without ReplayGain tags (EBU R128), stored in the library, never written to your files.",
                "**Polarity** (Output): invert one track or all of them. It negates every sample exactly; the path then reads as modified.",
                "**Rate Change Delay** gives a DAC time to settle after a sample-rate change so the start of a track is not lost.",
                "**Lock Output** keeps playback off the speakers if your DAC disappears; it waits and reconnects paused. Each DAC remembers its own volume and limit, and a new one starts quietly.",
            ]),
            .init(id: "rg", icon: "speaker.wave.2", title: "ReplayGain", items: [
                "Output › ReplayGain evens out loudness: **Track** levels every song, **Album** keeps the dynamics of an album.",
                "It needs ReplayGain tags in the files and never pushes peaks past full scale. It is off in DIRECT.",
            ]),
            .init(id: "keys", icon: "keyboard", title: "Keyboard shortcuts", items: [
                "**Space** play/pause · **⌘→** next · **⌘←** previous · **⌘O** open · **⇧⌘M** mute",
                "**⌥⌘M** compact player · **⌥⌘E** equalizer editor · **⌥⌘A** audio path",
                "**⇧⌘B** DIRECT · **⇧⌘D** dimmer · **⇧⌘P** power off",
                "**⌘1–⌘4** rack layout · **⌘- ⌘0 ⌘=** size · **⌃⌘F** fit screen · **⌘?** help",
            ]),
            .init(id: "trouble", icon: "wrench.and.screwdriver", title: "Troubleshooting", items: [
                "**No sound**: check Output, the knob position and the DAC's own volume. Other apps are silent on the DAC while DIRECT is on.",
                "**BIT-PERFECT stays off**: turn DIRECT on, check the signal path on the player for RESAMPLED or a lower bit depth.",
                "**Meters look slow**: press METER for PEAK mode; VU is slow by design.",
            ]),
        ]
    )

    static let french = HelpGuide(
        title: "Idiophile One",
        intro: "Un lecteur audio bit-perfect pour macOS, conçu comme une chaîne hi-fi : lecteur réseau, amplificateur intégré et égaliseur graphique.",
        sections: [
            .init(id: "start", icon: "play.circle", title: "Premiers pas", items: [
                "Glissez des fichiers ou des dossiers sur la chaîne, ou appuyez sur **⏏** / **⌘O**. Les dossiers sont lus en entier et triés par nom.",
                "**Espace** lance ou met en pause. **⌘→** / **⌘←** passent au titre suivant ou précédent. Les touches multimédia du clavier, les boutons du casque et le Centre de contrôle fonctionnent aussi.",
                "Formats : FLAC, ALAC, WAV, AIFF, MP3, AAC. Les tags et pochettes intégrés aux FLAC sont lus ; sinon un `cover.jpg` / `folder.jpg` à côté des fichiers est utilisé.",
            ]),
            .init(id: "rack", icon: "rectangle.stack", title: "La chaîne", items: [
                "**Lecteur réseau** (haut) : pochette, titre, artiste, album, chaîne du signal et titres suivants.",
                "**Amplificateur** (milieu) : vu-mètres, sélecteur d'entrée, volume et touches de façade.",
                "**Égaliseur graphique** (bas) : dix curseurs et un analyseur de spectre.",
                "Gardez seulement ce que vous voulez : **⌘3** lecteur réseau, **⌘5** ampli et **⌘4** égaliseur s'affichent ou se masquent chacun séparément (au moins un reste). **View › Animate VU Meters** et **Animate Spectrum Analyzer** figent les cadrans au repos tout en les laissant visibles : avec les deux coupés, la chaîne complète consomme environ 3 % d'un cœur.",
                "Menu View (présentation) : **⌘1** chaîne complète, **⌘2** ampli seul, **⌘3** / **⌘4** / **⌘5** afficher ou masquer chaque appareil. **⌘-** / **⌘0** / **⌘=** petit, moyen, grand ; **⌃⌘F** remplit l'écran.",
                "View › Finish : **Champagne**, **Black** (noir) ou **Blue Glass** (verre bleu).",
                "Déplacez la chaîne en la saisissant par une zone libre d'une façade.",
                "Un **clic droit** n'importe où sur la chaîne ou sur le mini-lecteur ouvre le menu complet : lecture, source, sortie, son, apparence et analyse.",
                "Le **mini-lecteur** (⌥⌘M) est un lecteur fin pour quand vous travaillez. Rien n'y est animé : environ 2 % d'un cœur de processeur.",
            ]),
            .init(id: "sources", icon: "antenna.radiowaves.left.and.right", title: "Sources et radio", items: [
                "Le bouton **INPUT** et **Playback › Source** (⌃1 / ⌃2 / ⌃3) changent vraiment de source. **LIB** revient à votre file de bibliothèque là où elle s'était arrêtée, **RADIO** joue la dernière station, **NET** ouvre vos serveurs. Une source sans rien à jouer ouvre son navigateur.",
                "**Radio internet** (fenêtre Bibliothèque › Internet Radio) : favoris, stations populaires, votre pays, genres et recherche. Marquez une station d'une étoile pour la garder ; glissez les favoris pour les ordonner.",
                "Une station propose souvent plusieurs flux. Idiophile One les regroupe et joue **le meilleur** : il pèse le codec et le débit (AAC 128 vaut mieux que MP3 128), évite les flux morts ou HLS quand il peut, et préfère le https. Choisissez *Best*, *Balanced* (jusqu'à 128 kb/s) ou *Light* (jusqu'à 64 kb/s), ou désactivez le choix automatique. Le menu **N streams** d'une ligne permet de choisir à la main.",
                "La radio passe par le même moteur que les fichiers : vu-mètres, égaliseur et horloge du DAC s'appliquent. Elle n'est jamais bit-perfect.",
                "**Réseau** (fenêtre Bibliothèque › Network) : les serveurs DLNA / UPnP de votre réseau sont trouvés automatiquement. Un serveur hors de portée de la découverte (VPN, autre sous-réseau) s'ajoute par nom ou adresse. Certains NAS ne servent que les appareils autorisés : sur un QNAP, autorisez ce Mac dans DLNA Media Server › Media Receivers.",
            ]),
            .init(id: "amp", icon: "dial.medium", title: "Commandes de l'ampli", items: [
                "**POWER** éteint les lampes en fondu et quitte. Le volume est mémorisé.",
                "**VOLUME** : tournez-le en glissant autour du bouton, à la molette (vers le haut = plus fort) ou avec les touches de volume du clavier. Si le DAC a son propre volume, le bouton le pilote directement : les échantillons restent intacts.",
                "**DIRECT** prend le chemin le plus court : égaliseur et ReplayGain retirés, accès exclusif au DAC (les autres apps et sons système y sont coupés).",
                "**METER** passe de **VU** (balistique classique de 300 ms) à **PEAK** (attaque rapide, retombée lente).",
                "**DIMMER** règle le rétroéclairage : plein, chaud ou tamisé.",
                "Le voyant **BIT-PERFECT** s'allume quand le fichier arrive au DAC sans aucune modification.",
            ]),
            .init(id: "quality", icon: "waveform", title: "Qualité audio", items: [
                "Choisissez votre DAC dans le menu **Output**. Un DAC branché plus tard apparaît tout seul.",
                "L'horloge du DAC suit la fréquence de chaque fichier : rien n'est rééchantillonné. Si le DAC ne gère pas cette fréquence, le lecteur affiche **RESAMPLED**.",
                "Le DAC est réglé sur son format entier le plus précis (par exemple 24 bits) : aucun bit n'est perdu.",
                "BIT-PERFECT exige : DIRECT activé, même fréquence et assez de bits sur le DAC, et le volume sur le DAC (ou le bouton au maximum).",
                "Les haut-parleurs du MacBook appliquent leur propre traitement : utilisez un DAC externe pour un vrai chemin bit-perfect.",
            ]),
            .init(id: "eq", icon: "slider.vertical.3", title: "Égaliseur", items: [
                "Chaque sortie garde son propre réglage d'égaliseur : un casque et des enceintes demandent des courbes différentes. Une nouvelle sortie démarre à plat.",
                "**EDIT** (ou Output › Equalizer Editor, ⌥⌘E) ouvre l'**éditeur paramétrique** : jusqu'à 20 filtres (cloche, shelf grave ou aigu, passe-haut ou passe-bas, notch) avec fréquence, gain et Q, un préampli et la courbe de réponse. **PARAM** bascule entre les curseurs et votre profil paramétrique ; quand le profil est utilisé, le rack affiche sa courbe à la place des curseurs.",
                "**Correction de casque** : Presets › Headphones (built-in) propose des profils prêts à l'emploi. Pour ajouter les vôtres, déposez un ou plusieurs fichiers `.txt` AutoEq / Equalizer APO sur l'éditeur, passez par Presets › Import, ou copiez la liste de filtres puis **Paste Filters from Clipboard** (`Preamp: -6.2 dB`, `Filter 1: ON PK Fc 100 Hz Gain -3 dB Q 0.7`). Les fichiers importés deviennent des presets. Vos réglages peuvent être enregistrés et exportés dans le même format.",
                "**Comparer (A/B)** : dans l'éditeur, chargez un profil en **A** et un autre en **B**, puis basculez avec **A**, **B**, **Off** (touches 1, 2, 3) pendant l'écoute. **Same loudness** baisse le choix le plus fort au niveau du plus faible : vous jugez la courbe, pas le volume. Les bascules sont progressives : aucun clic.",
                "Une accentuation ne sature jamais : le point le plus fort de la courbe est tenu à 0 dB par une marge automatique (le préampli d'un profil AutoEq la fournit déjà). Un égaliseur à plat ne change rien, au bit près.",
                "Glissez un curseur ou utilisez la molette dessus ; un double-clic le remet à 0 dB.",
                "**BYPASS** retire l'égaliseur ; **FLAT** remet toutes les bandes à zéro. Une atténuation d'entrée s'applique automatiquement quand vous montez une bande, pour éviter la saturation.",
                "En DIRECT, l'égaliseur est retiré (**EQ OUT · DIRECT**). Toucher un curseur ou BYPASS fait sortir de DIRECT.",
            ]),
            .init(id: "analysis", icon: "chart.xyaxis.line", title: "Analyse et confiance", items: [
                "Le **chemin audio** (Output › Audio Path, ⌥⌘A) liste chaque étape du fichier au DAC, lue en direct : transparente, modifie le signal, ou impossible à vérifier. **Verify** compare un à un les échantillons envoyés à Core Audio avec le fichier.",
                "La **résolution réelle** (Scan dans le même panneau) lit le spectre et les bits réellement utilisés : elle révèle un fichier 96 kHz qui est en fait un master 44,1 kHz, un filtre typique du MP3/AAC, ou un contenu 16 bits dans un fichier 24 bits.",
                "Le **volume sonore** est mesuré en arrière-plan (EBU R128) pour chaque titre sans tags ReplayGain, enregistré dans la bibliothèque, jamais dans vos fichiers.",
                "La **polarité** (Output) : inversez un titre ou tous. Chaque échantillon est exactement nié ; le chemin apparaît alors comme modifié.",
                "Le **délai après changement de fréquence** laisse au DAC le temps de se stabiliser pour ne pas perdre le début d'un titre.",
                "**Lock Output** garde la lecture hors des haut-parleurs si votre DAC disparaît ; elle attend et se reconnecte en pause. Chaque DAC retient son volume et sa limite, et un nouveau démarre doucement.",
            ]),
            .init(id: "rg", icon: "speaker.wave.2", title: "ReplayGain", items: [
                "Output › ReplayGain égalise le volume : **Track** aligne chaque morceau, **Album** préserve les nuances d'un album.",
                "Il faut des tags ReplayGain dans les fichiers ; les crêtes ne dépassent jamais le maximum. Désactivé en DIRECT.",
            ]),
            .init(id: "keys", icon: "keyboard", title: "Raccourcis clavier", items: [
                "**Espace** lecture/pause · **⌘→** suivant · **⌘←** précédent · **⌘O** ouvrir · **⇧⌘M** couper le son",
                "**⌥⌘M** mini-lecteur · **⌥⌘E** éditeur d'égaliseur · **⌥⌘A** chemin audio",
                "**⇧⌘B** DIRECT · **⇧⌘D** variateur · **⇧⌘P** éteindre",
                "**⌘1–⌘4** composition de la chaîne · **⌘- ⌘0 ⌘=** taille · **⌃⌘F** plein écran · **⌘?** aide",
            ]),
            .init(id: "trouble", icon: "wrench.and.screwdriver", title: "Dépannage", items: [
                "**Pas de son** : vérifiez Output, la position du bouton et le volume propre du DAC. Les autres apps sont muettes sur le DAC tant que DIRECT est actif.",
                "**BIT-PERFECT reste éteint** : activez DIRECT et regardez la chaîne du signal sur le lecteur (RESAMPLED ou moins de bits).",
                "**Vu-mètres lents** : appuyez sur METER pour le mode PEAK ; le mode VU est lent par conception.",
            ]),
        ]
    )
}
