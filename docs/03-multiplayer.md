# Multiplayer — what happens when mods are used in co-op

Resolved from the packaged configs, the shipping executable, and the replication metadata in the
`forever-winter-datamine` dumps (CUE4Parse `GetExports` preserves `PropertyFlags`, `RepIndex`,
`RepNotifyFunc`, `FunctionFlags`). The structural evidence is strong and internally consistent,
but note up front: **none of it has been confirmed by a live two-client test** — not here, and as
far as the public record shows, not by anyone. Claims read out of a config, dump, or binary are
stated plainly; claims that are a reasonable reading but unobserved are marked *inferred*.

## The session model is a listen server over EOS P2P

The inviter's client *is* the authoritative server; there is no dedicated server.

```ini
[/Script/Engine.GameEngine]
+NetDriverDefinitions=(DefName="GameNetDriver",DriverClassName="/Script/RedpointEOSNetworking.RedpointEOSNetDriver",...)
[OnlineSubsystem]
DefaultPlatformService=RedpointEOS
NativePlatformService=Steam
```

`WindowsEngine.ini` sets `[OnlineSubsystemSteam] bUseSteamNetworking=False` — Steam relay is off,
EOS P2P is the transport. Corroborating: the only game executable is
`ForeverWinter-Win64-Shipping.exe` (no dedicated-server binary ships); `MaxPlayers=4`; the exe
contains `EFWSessionDisconnectReason::HostLeft` and **no** `HostMigration` string, so when the
host quits the session ends; `p.NetEnableListenServerSmoothing=0` is set explicitly (you only
tune that if you ship listen servers); server tick rate is 30 Hz.

The exe *also* contains `ADedicatedServerMatchmakingBeaconHost`, `DedicatedServerEngine.ini`, and
similar — stock Redpoint plugin code compiled in but unused. No server binary ships and no config
points at it, so it is not evidence of dedicated servers.

## There is no anti-cheat, and nothing validates paks at join

```ini
[EpicOnlineServices]
EnableAntiCheat=False
```

Corroborated three ways: no EAC/BattlEye files exist anywhere in the install; the crash context
reports an empty `<Misc.AnticheatProvider>`; and the `RedpointEOSAntiCheat` module, though
compiled in, is gated off by that flag.

Pak signing **is** enforced, but it is a **local, load-time** gate with no network component.
Paks mount at process start, long before a session exists, and the signature bypass has already
patched the check out by then. There is no pak attestation, no manifest check, and no module scan
at join, so a modded client is never refused or kicked. `bUseBuildIdOverride=true` also pins the
network compatibility ID to a constant, so different game builds are not separated at the OSS
layer (the game appears to compensate with its own `FWParty.FilterByGameVersion` /
`FilterByBuildType` CVars).

## Tuning data is client-local; what consumes it is host-authoritative

This is the split that answers the question. DataTables and DataAssets carry **zero replication
markers** — they are cooked content, and each client loads its own copy from its own paks.
`DA_WPN_RFL01_v2` (`FireRate`, `WeaponDamage`, ...) has literally no `PropertyFlags`, `RepIndex`,
`bReplicates`, or `Net` occurrences, and the same holds for every DataTable in the catalog.

But the systems that *read* those tables are authority-gated, and their **results** are what
replicate:

- **Loot rolls.** `Random Loot From Array` and `Thin the herd?` both carry a
  `HasAuthority` check alongside the RNG call; the outcome is replicated state
  (`RandomLoot` RepIndex 15, `SearchedItems` RepIndex 13), not a client computation.
- **AI perception.** `BP_AI_CharacterBase` replicates `Current Awareness State` (RepIndex 51) and
  pairs `Server_StateChange` with `Multicast_StateChange`; the player pawn *receives* detection
  state (`Someone is aware of me`, RepIndex 91, with OnRep).
- **HK spawning.** `BP_SpawnController_HunterKillerSquad` gates its ubergraph behind three
  `HasAuthority` checks, with the spawn call inside the gate. `BP_PlayerBase` carries
  `SERVER Evaluate Anger New HKs` and `SERVER Inform Items Looted` as Server RPCs.

(Trap: `CLASS_ReplicationDataIsSetUp` appears on nearly every BP class, including UMG widgets that
are definitely not replicated. Only `RepIndex` / `PropertyFlags: … Net …` count.)

### Consequences

- **A non-host running gameplay/data mods changes nothing real.** The host arbitrates loot, AI,
  spawns and damage, so a non-host's tooltips and stat readouts lie while gameplay does not
  shift. Not an exploit — self-deception.
- **The host running them applies to everyone, silently.** The only real integrity concern.
- **Exception: movement.** `ClientAuthorativePosition=true` (within an error tolerance) makes the
  client authoritative over its own position, so movement-affecting mods are the one category
  where a non-host may genuinely change behaviour. *Inferred, untested.*

## Skins cross the wire as a soft object path — the CMSF-relevant finding

`GA_Player_ChangeSkin` is `LocalOnly` and only manipulates HUB widgets, but `BP_PlayerBase`
carries a full replication chain:

```
'SERVER Skin Has Changed'   FUNC_Net | FUNC_NetReliable | FUNC_NetServer
'CLIENTS Skin Has Changed'  FUNC_Net | FUNC_NetReliable | FUNC_NetMulticast
'Get Current Skin'  ->  'Current Skeletal Mesh' | SoftObjectProperty
```

The skin propagates as an **asset path string**, not as content. So an appended skin works
locally and its path does reach other clients — but a peer without the mod pak cannot resolve it.
*Inferred* from UE soft-path semantics: the visible result is a fallback/absent mesh, not a
desync, crash, or kick. **Content-adding mods therefore need the pak on every peer that should
see them.**

## Confounds for any cosmetic test

Public documentation is essentially absent. A sweep of the Nexus TFW pages and Steam discussions
finds only three mods saying anything about co-op; the one relevant case
([Unkillables Rebalance](https://www.nexusmods.com/theforeverwinter/mods/68)) states "host must
have the mod," agreeing with the split above. There is no first-party modding policy — the widely
cited "mods are fine" line is a modder's paraphrase of a dev Q&A, not a developer post.

And the *base game* mishandles skins in co-op: multiple Steam threads report skins failing to
register for multiplayer and being removed on leaving base, with no mods involved. Any clean
attribution of a skin failure to CMSF has to control for that.

## The decisive test, when it is run

Two clients, one modded and one not, with a modified `DamageToStagger` value: check whether
stagger behaviour changes when the **modded player is the client rather than the host**. The
analysis above predicts it does not. A second run with a CMSF skin pak on one side only would
settle the soft-path finding at the same time.
