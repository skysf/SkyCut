// Deutsch. Die App hat keine deutsche Oberfläche; Schaltflächen stehen mit ihrem englischen Namen im Text.
export default {
  title:'Videos mit Claude Code schneiden: Anleitung für den Mac',
  description:'Claude Code öffnet allein keinen Videoeditor. Mit SkyCut auf dem Mac schneidet, untertitelt und exportiert es auf einer echten Timeline.',
  heading:'Videos mit Claude Code auf dem Mac schneiden',
  answer:'Claude Code kann Videos schneiden, sobald es einen Editor steuern darf. Installiere SkyCut auf dem Mac, trage deinen Sky Studio-Key ein und klicke in den Einstellungen von SkyCut neben Claude Code auf **Connect**. Danach arbeitet Claude über den lokalen MCP-Server von SkyCut auf einer echten Mehrspur-Timeline: Es sieht sich dein Material an, schneidet Sprechpausen heraus, setzt Titel und Untertitel und exportiert das Ergebnis. Du siehst jede Änderung und kannst sie anpassen oder rückgängig machen. SkyCut läuft auf Macs mit Apple-Chip und macOS 15 oder neuer. Eine Version für Windows oder Intel gibt es nicht.',
  sections:[
    {heading:'Was Claude Code mit Video kann und was nicht',blocks:[
      'Claude Code ist ein KI-Agent, der im Terminal arbeitet. Es liest Dateien und führt Befehle aus, kann aber kein Video ansehen, keinen Ton hören und keine Clips anordnen. Zum Schneiden braucht es ein Werkzeug, das diese Dinge übernimmt. Davon gibt es zwei Arten.',
      {list:[
        '**Kommandozeilenwerkzeuge.** Claude schreibt FFmpeg-Befehle oder startet einen Skill, der sie bündelt. Das passt für Dateiaufgaben wie Kürzen, Zusammenfügen und Umwandeln. Jede Änderung rendert eine neue Datei, und es gibt keine Timeline, die du öffnen und von Hand korrigieren könntest.',
        '**Ein Videoeditor, den Claude steuern kann.** Der Editor gibt seine Timeline über MCP frei (Model Context Protocol, der übliche Weg, einem KI-Assistenten Werkzeuge zu geben). Claude ruft diese Werkzeuge auf, und jeder Schnitt landet auf einer Timeline, die du abspielen, durchsehen und selbst ändern kannst.',
      ]},
      'SkyCut gehört zur zweiten Art: ein nativer Mac-Videoeditor mit eingebautem MCP-Server. Der Rest dieser Anleitung nutzt ihn.',
    ]},
    {heading:'Was du brauchst',blocks:[
      {list:[
        'Einen Mac mit Apple-Chip (M1 oder neuer) und macOS 15 oder neuer. Funktionen, die Sprache transkribieren, etwa Pausen schneiden und Untertitel erzeugen, benötigen macOS 26.',
        'SkyCut. Der Download ist kostenlos. Die Oberfläche gibt es auf Englisch, vereinfachtem Chinesisch und Spanisch, nicht auf Deutsch. Die Schaltflächen in dieser Anleitung tragen ihre englischen Namen.',
        'SkyCut Pro. KI-Schnitt ist eine Pro-Funktion. Ein 7-tägiger Pro-Test beginnt, wenn du SkyCut zum ersten Mal mit deinem Sky Studio-Konto verbindest, einmal pro Konto und einmal pro Mac.',
        'Claude Code, installiert und mit deinem eigenen Claude-Tarif angemeldet. SkyCut enthält kein KI-Abo.',
      ]},
      {note:'Claude Desktop und Codex verbindest du an derselben Stelle, und sie funktionieren genauso. Ein normaler ChatGPT-Chat im Browser lässt sich nicht verbinden, weil der MCP-Server von SkyCut lokal auf deinem Mac läuft.'},
    ]},
    {heading:'Einrichtung in fünf Schritten',blocks:[
      {steps:[
        ['SkyCut installieren','Lade SkyCut, öffne das Disk-Image und ziehe SkyCut in den Ordner „Programme“. Die [Einrichtungsanleitung](/de/docs/#video) zeigt diesen Schritt in einem kurzen Video.'],
        ['Sky Studio-Key eintragen','Melde dich bei Sky Studio an, öffne oben rechts deinen Avatar, wähle SkyCut und erstelle einen Key. Öffne in SkyCut die Settings, gehe zu Sky Studio und füge den Key ein. Das schaltet Pro frei und startet den Test.'],
        ['Claude Code verbinden','Öffne in SkyCut **Settings → Connect AI** und klicke neben Claude Code auf **Connect**. SkyCut registriert seinen MCP-Server bei Claude Code, indem es `claude mcp add` für dich ausführt, und erlaubt die Werkzeuge von SkyCut, damit Claude nicht bei jedem einzelnen nachfragt.'],
        ['Neue Claude Code-Sitzung starten','Claude Code lädt MCP-Server beim Start einer Sitzung. Öffne eine neue Sitzung und gib `/mcp` ein. In der Liste sollte `skycut` stehen.'],
        ['Claude dein Material zeigen','Sag Claude, in welchem Ordner deine Clips liegen und was entstehen soll. SkyCut öffnet diesen Ordner, und neue Dateien wie Exporte werden dort gespeichert.'],
      ]},
    ]},
    {heading:'Prompts für den ersten Schnitt',blocks:[
      'Du sprichst mit Claude in normaler Sprache. Jeder dieser Prompts entspricht etwas, das SkyCut kann, und du kannst sie nacheinander im selben Projekt verwenden.',
      {prompt:'Öffne den Ordner ~/Movies/interview in SkyCut. Sieh dir jeden Clip an und sag mir, was darin zu sehen ist.'},
      {prompt:'Lege ein Projekt in 16:9 an und baue aus den drei stärksten Takes einen Rohschnitt.'},
      {prompt:'Entferne die langen Pausen und die Füllwörter aus dem Clip mit der Moderation.'},
      {prompt:'Erzeuge deutsche Untertitel und füge eine englische Übersetzung als zweite Spur hinzu.'},
      {prompt:'Setze in den ersten drei Sekunden den Titel Antarktis ein und exportiere dann ein MP4 in 1080p.'},
      'Claude kann außerdem ein Motiv ins Bild rücken, Musik auf den Beat schneiden, Clips schichten und animieren, einen Sprechertext hinzufügen und das fertige Video auf Probleme prüfen. Wenn du nicht jeden Schritt beschreiben willst, nenne einen Schnittstil wie Dokumentation oder Vlog und lass Claude den Schnitt planen.',
    ]},
    {heading:'Prüfen, was Claude gemacht hat',blocks:[
      'Genau dafür lohnt sich ein echter Editor. Während Claude arbeitet, zeigt SkyCut in der Symbolleiste **AI is editing** und springt zu jeder Änderung, sobald sie passiert. Du kannst jederzeit auf **Stop** klicken.',
      {list:[
        'Jeder Werkzeugaufruf ist ein Schritt im Verlauf. Mit ⌘Z gehst du Claudes Änderungen einzeln zurück.',
        'Wenn Claude fertig ist, setzt **Undo This Round** das Projekt auf den Stand vor Beginn der Runde zurück.',
        'Nichts ist gesperrt. Ziehe einen Clip, verschiebe einen Untertitel oder ändere einen Titel von Hand und bitte Claude dann, von dort weiterzumachen.',
        'SkyCut hat zwei Berechtigungsmodi. **Ask for approval** hält an, bevor Claude über die Standardwerte hinausgeht, zum Beispiel vor dem Löschen einer Datei. **Full access** führt aus und berichtet danach. Tageslimits für kostenpflichtige Generierung gelten in beiden Modi.',
      ]},
    ]},
    {heading:'Was es kostet',blocks:[
      {table:{head:['Was','Preis','Hinweise'],rows:[
        ['SkyCut Free','{{free.price}}','Der vollständige manuelle Editor. Exporte tragen ein Wasserzeichen. Kein KI-Schnitt.'],
        ['SkyCut Pro','{{pro.monthly}} im Monat oder {{pro.yearly}} im Jahr','KI-Schnitt und Exporte ohne Wasserzeichen. Beginnt mit einem 7-tägigen Test, wenn du SkyCut zum ersten Mal verbindest.'],
        ['Claude Code','Dein eigener Claude-Tarif','Zahlst du an Anthropic. Nicht Teil von SkyCut.'],
        ['Cloud-Generierung','Optional','Erzeugte Bilder, Videos, Musik und Stimmen verbrauchen Sky Studio-Credits, die separat gekauft werden.'],
      ]}},
      'Preise verstehen sich ohne Steuern. Was jeder Tarif enthält, steht in der [Preisübersicht](/de/#pricing).',
    ]},
    {heading:'Grenzen, die du vorher kennen solltest',blocks:[
      {list:[
        'Nur Mac: Apple-Chip und macOS 15 oder neuer. SkyCut läuft weder unter Windows noch auf Intel-Macs.',
        'Claude sieht dein Video nicht so wie du. Es nimmt über die Werkzeuge von SkyCut einzelne Bilder, misst Pegel und liest Transkripte. Prüfe den Schnitt deshalb, bevor du ihn veröffentlichst.',
        'Projekt und Material bleiben auf deinem Mac. Claude erhält aber als Teil eurer Unterhaltung, was die Werkzeuge zurückgeben, etwa Bilder und Transkripte.',
      ]},
    ]},
    {heading:'Andere Wege, mit Claude Videos zu schneiden',blocks:[
      'SkyCut ist nicht der einzige Weg, und welcher passt, hängt von der Aufgabe ab.',
      {list:[
        '**Skills auf Basis von FFmpeg.** Quelloffene Skills für Claude Code bündeln FFmpeg und Whisper und laufen im Terminal. Sie eignen sich für Stapelaufgaben an Dateien und brauchen keinen Editor. Eine Timeline zum Prüfen gibt es nicht.',
        '**MCP-Server für andere Editoren.** Ein Community-Projekt steuert DaVinci Resolve über dessen Scripting-API. Es läuft unter macOS, Windows und Linux, und externes Scripting setzt die kostenpflichtige Studio-Version von Resolve voraus.',
      ]},
      'Nimm SkyCut, wenn du am Mac arbeitest und Claude in einem Editor arbeiten soll, den du auch selbst von Hand bedienen kannst.',
    ]},
  ],
  faq:[
    ['Kann Claude Code allein Videos schneiden?','Nein. Claude Code arbeitet mit Text und Befehlen. Um ein Video zu ändern, braucht es FFmpeg oder einen Videoeditor, den es steuern kann, etwa SkyCut.'],
    ['Funktioniert das auch mit Claude Desktop oder Codex?','Ja. Unter **Settings → Connect AI** hat SkyCut je eine Connect-Schaltfläche für Claude Desktop, Claude Code und Codex. Andere Clients funktionieren, wenn sie lokale stdio-MCP-Server unterstützen.'],
    ['Ist das kostenlos?','SkyCut lässt sich kostenlos laden und von Hand bedienen. Damit Claude schneidet, brauchst du SkyCut Pro für {{pro.monthly}} im Monat oder {{pro.yearly}} im Jahr, sobald der 7-tägige Test endet, dazu deinen eigenen Claude-Tarif.'],
    ['Läuft es unter Windows?','Nein. SkyCut läuft nur auf Macs mit Apple-Chip und macOS 15 oder neuer.'],
    ['Wird mein Material hochgeladen?','SkyCut schneidet auf deinem Mac und behält das Projekt dort. Claude erhält, was die Werkzeuge für deine Anfrage zurückgeben, etwa Bilder und Transkripte.'],
  ],
};
