# Multiplayer — what happens when mods are used in co-op

**Provenance.** Resolved 2026-07-20 from the packaged configs, the shipping exe, and
replication metadata in the `forever-winter-datamine` dumps. This supersedes the
"genuinely undocumented" note in [01-design.md](01-design.md) §Constraints.

| | |
|---|---|
| Game build | `24097213` (Steam `buildid`; paks dated 2026-07-07) |
| Engine | UE 5.4.2 |
| Config source | `ForeverWinter/Config/DefaultEngine.ini`, `DefaultGame.ini`, `Windows/WindowsEngine.ini` — all inside `pakchunk0-Windows.pak` (AES-encrypted index) |
| Replication source | `datamine/dumps/**` — CUE4Parse `GetExports` preserves `PropertyFlags`, `RepIndex`, `RepNotifyFunc`, `FunctionFlags` |

Claims are tagged **[VERIFIED]** (read directly out of a config, dump, or binary) or
**[INFERRED]** (a reasonable reading that has *not* been tested in-game), matching the
convention in [00-findings.md](00-findings.md).

> **Nothing here has been confirmed by a live two-client test.** The structural evidence
> is strong and consistent, but the empirical A/B has never been run — by us or, as far as
> the public record shows, by anyone. See §6.

---

## 1. The session model is a listen server over EOS P2P **[VERIFIED]**

The inviter's client *is* the authoritative server. There is no dedicated server.

```ini
[/Script/Engine.GameEngine]
+NetDriverDefinitions=(DefName="GameNetDriver",DriverClassName="/Script/RedpointEOSNetworking.RedpointEOSNetDriver",DriverClassNameFallback="/Script/OnlineSubsystemUtils.IpNetDriver")

[OnlineSubsystem]
DefaultPlatformService=RedpointEOS
NativePlatformService=Steam
```

`WindowsEngine.ini` sets `[OnlineSubsystemSteam] bUseSteamNetworking=False` — Steam relay is
explicitly off, EOS P2P is the transport.

Corroborating:

- The only game executable in the install is `ForeverWinter-Win64-Shipping.exe`. **No
  dedicated-server binary ships.**
- `[/Script/Engine.GameSession] MaxPlayers=4` / `MaxSpectators=4`.
- The exe contains `EFWSessionDisconnectReason::HostLeft` and **no** `HostMigration`
  string — when the host quits, the session ends.
- `p.NetEnableListenServerSmoothing=0` is set explicitly. You only tune that if you ship
  listen servers.
- Redpoint diagnostic step names compiled in: `StartListenServer`,
  `CreateSessionForListenServer`, plus the game's own `UFWSession_HostSessionRequest`.
- Server tick rate 30 Hz (`NetServerMaxTickRate=30`).

**Interpretation trap.** The exe *also* contains `ADedicatedServerMatchmakingBeaconHost`,
`FindDedicatedServerSession`, `DedicatedServerEngine.ini`, etc. That is stock Redpoint
plugin code compiled in but unused — no server binary ships and no config points at it.
Do not read it as evidence of dedicated servers.

## 2. There is no anti-cheat, and nothing validates paks at join **[VERIFIED]**

```ini
[EpicOnlineServices]
EnableAntiCheat=False
```

Corroborated three ways: no EAC/BattlEye files exist anywhere in the install; the crash
context reports an empty `<Misc.AnticheatProvider></Misc.AnticheatProvider>`; and the
`RedpointEOSAntiCheat` module, while compiled in, is gated off by that flag.

Pak signing **is** enforced — but it is a **local, load-time** gate with no network
component. Paks mount at process start, long before a session exists, and `bitfix` has
already patched the check out by then. There is no pak attestation, no manifest check, and
no module scan at join. **A modded client is never refused or kicked.**

Also worth knowing: `bUseBuildIdOverride=true` with `BuildIdOverride=1234567` pins the
network compatibility ID to a constant, so different game builds are **not** separated at
the OSS layer. The game appears to compensate with its own `FWParty.FilterByGameVersion` /
`FWParty.FilterByBuildType` CVars.

## 3. Tuning data is client-local; everything that consumes it is host-authoritative **[VERIFIED]**

This is the split that answers the question.

**Zero replication markers** in any DataTable or DataAsset — they are cooked content, and
each client loads its own copy from its own paks:

| Directory | Files | Type |
|---|---|---|
| `dumps/ai_sensors/` | 43 | `FWAISensorDefinition_*` |
| `dumps/ai_noise/` | 27 | `AIDEF_Noise_*` |
| `dumps/weapons/` | 18 | `FWWeaponDefinition` + curves |
| `dumps/items/` | 17 | DataTables |

`DA_WPN_RFL01_v2.json` — `FireRate`, `WeaponDamage`, `MaxDispersionRate` — has literally 0
occurrences of `PropertyFlags`, `RepIndex`, `bReplicates`, or `Net`. Same for all 32
DataTables in `catalog/tables.json`.

But the systems that *read* those tables are authority-gated, and their **results** are
what replicate:

- **Loot rolls.** `Random Loot From Array` (`lootobjects/BP_LootContainer_RandomBase.json`)
  and `Thin the herd?` (`BP_LootContainer.json`) both carry a
  `CallFunc_HasAuthority_ReturnValue` local alongside `CallFunc_RandomFloat_ReturnValue`.
  The outcome is replicated state, not a client computation:
  `BP_LootContainer_RandomBase.RandomLoot` RepIndex 15, `BP_LootContainer.SearchedItems`
  RepIndex 13.
- **AI perception.** `enemies/BP_AI_CharacterBase.json` replicates `Current Awareness State`
  (RepIndex 51) and pairs `Server_StateChange` with `Multicast_StateChange`.
  `BP_AI_Euruska_Stalker.json` shows it unambiguously: `PlayerDetected_Server` /
  `PlayerDetected_Multicast`. The player pawn *receives* detection state —
  `Someone is aware of me` (RepIndex 91, with OnRep).
- **HK spawning.** `hunterkillers/BP_SpawnController_HunterKillerSquad.json` gates its
  ubergraph behind three `CallFunc_HasAuthority_ReturnValue` locals, with
  `SpawnPersistentAIFromClassAndWait` inside the gate. `BP_PlayerBase` carries
  `SERVER Evaluate Anger New HKs` and `SERVER Inform Items Looted` as Server RPCs.

**Trap:** `CLASS_ReplicationDataIsSetUp` appears on nearly every BP class, including
`WBP_ItemTooltips` — a UMG widget that is definitively not replicated. It is **not**
evidence of replication. Only `RepIndex` / `PropertyFlags: … Net …` count.

### Consequences

- **Non-host runs gameplay/data mods → nothing real changes.** The host arbitrates loot,
  AI, spawns, damage. Their tooltips and stat readouts lie; gameplay does not shift. Not
  an exploit — self-deception.
- **Host runs them → applies to everyone, silently.** The only real integrity concern.
- **Exception: movement.** `[/Script/Engine.GameNetworkManager] ClientAuthorativePosition=true`
  (with `MAXPOSITIONERRORSQUARED=10000.0f`) — clients are authoritative over their own
  position within an error tolerance. Movement-affecting mods are the one category where a
  non-host may genuinely change behaviour. **[INFERRED]**, untested.

## 4. Skins cross the wire as a soft object path — the CMSF-relevant finding **[VERIFIED]**

`GA_Player_ChangeSkin` is `NetExecutionPolicy: EGameplayAbilityNetExecutionPolicy::LocalOnly`
and only manipulates widgets in the HUB. But `BP_PlayerBase` carries a full replication
chain:

```
'skin has changed'          FUNC_BlueprintCallable                        (local)
'SERVER Skin Has Changed'   FUNC_Net | FUNC_NetReliable | FUNC_NetServer
'CLIENTS Skin Has Changed'  FUNC_Net | FUNC_NetReliable | FUNC_NetMulticast
'Get Current Skin'  ->  'Current Skeletal Mesh' | SoftObjectProperty
```

The skin propagates as an **asset path string**, not as content.

**What this means for CMSF:** an appended skin row works locally, and the path string does
reach other clients — but peers without the mod pak cannot resolve it. **[INFERRED]** from
UE soft-path semantics: the visible result is a fallback/absent mesh, not a desync, crash,
or kick. Content-adding mods therefore need the pak on **every peer that should see them**.

This is a sharper PoC question than the four currently in [00-findings.md](00-findings.md),
and it is cheap to test once the selector filter problem (§Post-PoC in
[01-design.md](01-design.md)) is solved.

## 5. Public documentation is essentially absent **[VERIFIED]**

Swept ~150 Nexus TFW mod pages and the Steam discussions. **Three** mods say anything at
all about co-op:

- **Unkillables Rebalance** ([mods/68](https://www.nexusmods.com/theforeverwinter/mods/68)) —
  "Works in multiplayer (host must have the mod)". The only "host must have it" case
  documented anywhere, and it agrees with §3.
- **X's OTT ReShade** ([mods/9](https://www.nexusmods.com/theforeverwinter/mods/9)) —
  "Reshade will work online". Expected; it's a post-process layer, not game state.
- **MeruMods**, one of the most prolific TFW skin authors, answering a co-op question on
  [mods/31](https://www.nexusmods.com/theforeverwinter/mods/31) — "I don't know, I never
  played it coop."

**Zero** mods anywhere state that all players need the mod. There is no first-party
modding policy; the widely-cited "mods are fine" source is a modder's paraphrase of a
Sept 2024 dev Q&A, not a developer post.

**Confound for any cosmetic testing:** the *base game* mishandles skins in co-op. Multiple
2026 Steam threads report skins failing to register for multiplayer and being removed on
leaving base, with no mods involved. Clean attribution of a skin failure to CMSF will
require controlling for this.

## 6. What is still untested

The whole of §3 and §4 rests on structural evidence — configs, exe strings, replication
flags — not on observation. Neither we nor the public record has run the experiment.

**The cheap decisive test:** two clients, one modded and one not, with a modified
`DamageToStagger` (`UnkillablesRebalanceFix` already has the values —
`docs/diagnosis.md:32`, 20000→1000). Check whether stagger behaviour changes when the
**modded player is the client rather than the host**. §3 predicts it does not.

A second run with a CMSF skin pak on one side only would settle §4 at the same time.
