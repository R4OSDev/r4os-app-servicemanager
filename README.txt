SERVMAN.R4X
===========

SERVMAN.R4X ist der terminalbasierte Service Manager fuer R4OS.

Projektstruktur seit 0.51.18:
- `build.zig` baut die App als eigenes SDK-Projekt.
- `build.zig.zon` bindet `r4os_sdk` als Paket.
- `module.R4MF` beschreibt Artefakt, Zielpfad und Contract.

Build:

    cd Code\System\Software\ServiceManager
    ..\..\..\DevTools\Zig\zig.exe build

Ergebnis:

    Code\System\Software\ServiceManager\zig-out\SERVMAN.R4X

Contract:
- R4XStart-Entry: `servman_main`
- App-Klasse: `console`
- Zielpfad im Image: `C:\R4OS\SOFTWARE\TERMINAL\SERVMAN.R4X`

Seit 0.52.6 fragt `SERVMAN STATUS name` bei laufenden Services mit
registriertem Endpoint zusaetzlich Operation `1` mit Payload `STATUS` ab.
Kurze printable Antworten werden als `Endpoint: ...` ausgegeben. SSHD nutzt
diesen Pfad fuer Sessions, Auth-Counter und Passwortdiagnose.

Seit 0.53.16 zeigt `SERVMAN LIST`, `SERVMAN STATUS` und `SERVMAN DIAG`
zusaetzlich die queue-basierten Endpoint-Felder aus `ServiceInfo`: Queue-
Tiefe, belegte Slots, High-Water, aktive Worker, offene Handles, Busy,
Timeouts und Cancels. SERVMAN setzt dabei keine Kernel-Policy; echte Worker-
und Session-Grenzen bleiben bei den Diensten.

Seit 0.55.7 zeigt `SERVMAN DIAG` zusaetzlich die Connectivity-Endpoints
`TCPSVC`, `SSHD` und `RDPSVC` in einer kompakten Uebersicht. Seit 0.55.12 ist
auch `FTPSVC` in dieser Uebersicht enthalten. Sichtbar sind
Endpoint-Status, Queue-Status, Worker, offene Handles, Busy-/Timeout-/Cancel-
Zaehler und der letzte Fehlercode.
