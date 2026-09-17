# TickRevamp — live call-site survey of HeroicSouls (H mirror, commit fdb6efba8, 2026-08-25)

Scope: every `*.luau` under `C:/Users/Faded/Documents/GitHub/HeroicSouls-BackUp` (2,481 files). 268 files mention `TickAPI`/`StrikeTickAPI`/`TimeManagerAPI`; 279 including `SyncedTime*`. Method: one `rg` dump (`research/scratch/callsites/all_lines.txt`, 3,820 lines) + Python post-processing with a comment/string-stripping Luau block scanner (`survey.py`, `survey2.py`, `survey3.py`; outputs `survey_out.md`, `survey2_out.md`, `survey3_out.md`; full concatenation of every caller file with `path:line:` prefixes in `tickfiles_dump.txt`). Scanner validated on a synthetic snippet (`survey_nesttest.py`: depth {0:5,1:2,2:1}, chain max 2 — correct).

Path legend (mirror suffixes `_[Module]`/`_[Folder]`/... stripped): `RS/SM/` = ReplicatedStorage/SharedModules, `RF/LO/` = ReplicatedFirst/LocalOnly, `RF/` = ReplicatedFirst, `SSS/` = ServerScriptService, `SS/` = ServerStorage, `SG/` = StarterGui, `SP/SPS/` = StarterPlayer/StarterPlayerScripts.

Tiers: **live** = shipped game code; **plugin** = `SS/RoBase/*` + `SS/Custom_Plugin_Service/*` (the RoBase Studio plugin, which requires `game.PluginGuiService.CoreHolder.Core.TickAPI`); **archive** = `SS/DEVELOPER/ARCHIVE_VAULT/*`, `SS/RoBase/ARCHIVES/*`. Counts below exclude commented-out lines unless marked *raw*.

---

## 1. Call shapes

### 1a. Wrapper entry points (caller files only; the wrapper/core modules themselves excluded)

| shape | live | plugin | archive | total | raw (incl. comments) | live files | examples |
|---|---|---|---|---|---|---|---|
| `TickAPI.Tick.delay(` | 56 | 14 | 7 | 77 | 85 (+8 commented) | 42 | `SSS/Modules/SpawnManager/SpawnManager.luau:387`; `RF/LO/Modules/CameraClass/CameraClass.luau:312`; `SG/Menu/Locked/MenuHolder/Outer/Cards/PrimaryCard/PrimaryCardControler.luau:118` |
| `TickAPI.Tick.recur(` | 29 | 21 | 4 | 54 | 60 | 21 | `RS/SM/WorldStateManager/WorldStateManager.luau:150`; `SSS/Modules/EventSpawnerClass.luau:406`; `RF/LO/Modules/InputMouseManager.luau:361` |
| `TickAPI.Tick.remove(` | 0 | 0 | 0 | 0 | 0 | 0 | — |
| `TickAPI.Tick.update(` | 0 | 0 | 0 | 0 | 8 | 0 | wrappers only: `RS/SM/TickAPI/TickAPI.luau:39`, `RS/SM/StrikeManager/StrikeTickAPI/StrikeTickAPI.luau:16`, `SS/RoBase/Core/TickAPI/TickAPI.luau:35`, `SS/RoBase/Core/SimAnimLite/FxPackageLite/TickAPI/TickAPI.luau:14`, `RF/LO/Init_Scripts/SetupCliffAreaScreenSize_AndANIMATION/TickAPI/TickAPI.luau:17` |
| `TickAPI.Tick.getClocks` / `.event(` | 0 | 0 | 0 | 0 | 0 | 0 | — |
| `TickAPI.Tick:remove(` (colon misuse) | **2** | 0 | 2 | 4 | 4 | 1 | `SG/Menu/Locked/MenuHolder/Outer/Cards/PrimaryCard/PrimaryCardControler.luau:124`, `:141` (+ archive REFERENCE_VAULT copy `:124`, `:141`) |
| `TickAPI.Tickh.delay(` | 63 | 0 | 3 | 66 | 71 | 39 | `SSS/Modules/SpawnManager/SpawnManager.luau:300`; `RF/LO/Modules/InputMouseManager.luau:425`; `RF/LO/Modules/HitFx/HitFlashObject.luau:176` |
| `TickAPI.Tickh.recur(` | 40 | 0 | 1 | 41 | 46 | 36 | `RS/SM/CustomCharacterData/CoreCharacterSheet/CharacterSheet/CharacterSheet.luau:803`; `SSS/Modules/BaseOverDungeonClass/TowerOfTest/TowerOfTest.luau:98`; `RS/SM/GroupClass/GroupClass.luau:541` |
| `TickAPI.Tickh.remove/update/getClocks/event`, `Tickh:` | 0 | 0 | 0 | 0 | update 4 (wrappers) | 0 | — |
| `TickAPI.Tickr.delay(` | 1 | 0 | 0 | 1 | 1 | 1 | `RS/SM/CustomCharacterData/CoreCharacterSheet/CharacterSheet/CharacterSheetIncludes/CharacterSheet_Animation/CharacterSheet_Animation.luau:218` |
| `TickAPI.Tickr.recur(` | 4 | 0 | 0 | 4 | 7 (+3 commented) | 4 | `RF/LO/Modules/AbilityClass/AbilityClass_Utility.luau:287`; `RF/LO/Modules/HitFx/HitFlashObject.luau:126`; `...CharacterSheet_Animation.luau:312`; `RS/SM/BurstTextPool/BurstTextClass/BurstTextConfigSets/DefaultBurstType/DefaultBurstType_Original.luau:79` |
| `TickAPI.Tickr.*` other, `Tickr:` | 0 | 0 | 0 | 0 | update 2 (wrappers) | 0 | — |
| `TickAPI[<dynamic>]` | 1 | 0 | 0 | 1 | 1 | 1 | `RS/SM/TickAPI/AfterNotTouchedClass.luau:45` (`TickAPI[TickType].delay`) |
| `TickAPI.SafeStopClock(` | 66 | 6 | 4 | 76 | 83 (+7 commented) | 43 | `RF/LO/Modules/HitFx/HitFlashObject.luau:153`; `RF/LO/Modules/InputMouseManager.luau:454`; `RS/SM/EntityActionClass.luau:89` |
| `TimeManagerAPI.SafeStopClock(` (alias) | 2 | 2 | 0 | 4 | 4 | 1 | `RS/SM/RepActionManager/SimAnim/FxPackage/FxPackage.luau:1340`, `:1341`; plugin `SS/RoBase/Core/SimAnimLite/FxPackageLite/FxPackageLite.luau:681`, `:682` |
| `TickAPI.GetAfterNotTouched(` | 1 | 0 | 0 | 1 | 1 | 1 | `SSS/Modules/BaseOverDungeonClass/TowerOfTest/TowerOfTest.luau:283` (arg `"Tickh"`, `:Touch()` at `:279`) |
| `TickAPI.<any other member>` | 0 | 0 | 0 | 0 | 0 | 0 | — |
| `StrikeTickAPI.Tick.delay(` | 5 | 0 | 0 | 5 | 5 | 2 | `RS/SM/RepUpdateManager/UpdateAction/UpdateAction_ActionServerHitScan.luau:333`, `:407`; `RS/SM/RepActionManager/Action/Attack/Action_ConeHitScan/Action_ConeHitScan.luau:300`, `:415`, `:561` |
| `TimeManagerAPI.Tickh.delay(` / `.recur(` (alias of the MAIN wrapper, `FxPackage.luau:25`) | 7 / 1 | 0 | 0 | 8 | 8 | 1 | `RS/SM/RepActionManager/SimAnim/FxPackage/FxPackage.luau:513,681,742,836,939,1009,1089`; recur `:1049` |
| `TimeManagerAPI.Tick.delay(` / `.recur(` (FxPackageLite wrapper) | 0 | 7 / 1 | 0 | 8 | 8 | 0 | `SS/RoBase/Core/SimAnimLite/FxPackageLite/FxPackageLite.luau:278,334,415,500,538,610,748`; recur `:576` |

Totals, live tier, non-comment: **delay 132** (56 Tick + 63 Tickh + 1 Tickr + 5 Strike + 7 alias), **recur 74** (29 + 40 + 4 + 1 alias), **SafeStopClock 68** (66 + 2 alias) + 1 internal (`AfterNotTouchedClass.luau:74`).

### 1b. Handle methods and handle-shape dependencies (tick-caller files, receivers verified by name-tracking: 106 distinct handle variables from 118 assignment sites)

| usage | count (live/plugin/archive) | examples |
|---|---|---|
| `handle:stop()` | 24 (12/6/6) + 4 `clockObj:stop()` inside the four wrappers' `SafeStopClock` | `RF/LO/Modules/CameraClass/xray.luau:70`; `RF/LO/Modules/SoundEffectVolumeConstructor.luau:69`; `RF/LO/Modules/UISystemBooter/PaperDollView/PaperDollView.luau:228`; `SG/Menu/.../Inventory/InfoCardManager.luau` (`CurrentShowCardDelayTimer:stop()` x4) |
| `handle:reset()` | 9 (9/0/0) | delay handles: `RF/LO/Modules/UISystemBooter/TargetBarManagerClass/TargetEffectsManagerClass/EffectStatusBarItem.luau:172`; `.../TargetEffectStatusItem.luau:201`; `RF/LO/Modules/HitFx/HitFlashObject.luau:247` (`NPC_Timer[TargetId]:reset()`); `RS/SM/SoundControler/SoundControler.luau:320`; `SSS/Modules/SpawnManager/Includes/GroupManagment.luau:64`; `SSS/Modules/Spawner.luau:355`; `RS/SM/TickAPI/AfterNotTouchedClass.luau:63`. **recur handles**: `RS/SM/WorldStateManager/WorldStateManager.luau:167`; `RS/SM/BurstTextPool/.../DefaultBurstType_Original.luau:242` |
| `handle:after(` | **0** | whole-mirror `:after(` = 31 tokens, none on a Tick handle: 10 `event:after` core definitions, 4 `MobileEnemy:after("_PrepEnemy","_BeginCreationSetup")`-style BaseClass *Callbacks* mixin calls (`SSS/Modules/BaseEntityClass/MobileNPCClass/MobileEnemyClass.luau:302,345,358,393`), 17 in BaseClass Callbacks examples/tests |
| `handle:adjust(` | 2 (2/0/0) | `...CharacterSheet_Animation.luau:158`; `RS/SM/RepUpdateManager/UpdateAction/UpdateAction_ActionServerHitScan.luau:459` |
| `handle:setClock(` | 0 | defined only in the FxPackageLite core `SS/RoBase/Core/SimAnimLite/FxPackageLite/TickAPI/Tick.luau:56` |
| dot-call misuse `handle.stop()` etc. | 0 | — |
| direct field reads `.timer/.delay/.fn/.recur/.parent/.err` on handles | 0 | — |
| `.class/.type/.name` on handles | 0 | — |
| `[handle] = ...` (handle as table key) | 0 | — |
| `handle == x` (non-nil compare) | 0 | (`CertingModerator.luau:148 ServerTypeSelected == true` is a different local, `:97`, than the handle local at `:240`) |
| `type(handle) == "table"` discriminator | **2** | `RS/SM/EntityActionClass.luau:88` (Tick handle vs SyncedTimer Id string in the same list); `RS/SM/CustomCharacterData/CoreCharacterSheet/CharacterSheet/CharacterSheet.luau:754` (same field alternates between a `Tickh.recur` handle `:803` and an Instance `AuraLockClone` `:775`; `:863` calls `:Destroy()` on the Instance case) |
| `handle ~= nil` / `== nil` guards | 71 (47/12/12) | e.g. `RF/LO/Modules/HitFx/BurstTextFX/BurstTextFX.luau:233` |
| `if handle then` / `if self["X"] then` truthiness | present | `RF/LO/Modules/InputMouseManager.luau:359` |
| `handle = nil` after stop | 110 (87/15/8) | — |
| `x = TickAPI.SafeStopClock(x)` idiom (relies on nil return) | 19 (16/3/0) | `RF/LO/Modules/HitFx/HitFlashObject.luau:153`; `RF/LO/Modules/InputMouseManager.luau:365,428,455`; `FxPackage.luau:1340-1341` |
| handles passed as args / stored in collections | 92 sites | `RS/SM/EntityActionClass.luau:75` (`self.TimerTable`), `FxPackage.luau:1147` (`self.EventClocks`), `CharacterSheet_Animation.luau:157` (`self.StepClockBag[i][2]`), `HitFlashObject.luau:176` (`NPC_Timer[self.AdorneeId]`), `xray.luau:87` (`ObscuringItemManager.ObscuredCoolDown[id2]`) |
| result discarded (fire-and-forget) | 144 statement-level calls, **40 of them `recur`** (unstoppable forever timers) | `RF/LO/Init_Scripts/LocalInitilizer/LocalGeneralConfig/UI_Initilizer/UI_Initilizer.luau:45`; `RF/LO/Modules/UISystemBooter/QuestHudManager.luau:297`; `RF/LO/UIControls/GroupInviteWindow/GroupInviteController.luau:216,397`; `RS/SM/AssetDelivery/private_AssetDelivery.luau:764`; `RS/SM/GroupClass/GroupClass.luau:102`; `RS/SM/ObjectBouncer.luau:102`; `SSS/Initialize_Modules_Server/Initialize_Modules_Server.server.luau:249`; `SSS/Modules/Spawner.luau:434,456`; `RS/SM/Game_Manager/Threads/UpdateClientEntities.luau:36`; `SG/Hud_LayOutV1/PingFrame/PingDisplay/PingScript.client.luau:30` |

`tick.group()` / `:event(` in game code: 0 (only inside the 10 core copies). No game file requires `Tick`/`Tick2`/`Tick3` directly — only the wrappers do (`RS/SM/TickAPI/TickAPI.luau:36,42,52`; `SS/RoBase/Core/TickAPI/TickAPI.luau:14`; archive `:32,38,48`).

### 1c. Require shapes (raw, all files)

| target | count |
|---|---|
| `require(game.ReplicatedStorage.SharedModules.TickAPI)` | 180 |
| `require(game.PluginGuiService.CoreHolder.Core.TickAPI)` (RoBase plugin wrapper) | 33 |
| `require(game.ReplicatedStorage.SharedModules:WaitForChild("TickAPI"))` | 9 |
| `require(CoreReference.TickAPI)` (RoBase) | 7 |
| `require(SharedModules.TickAPI)` / `require(SharedModules:WaitForChild("TickAPI"))` / `require(ReplicatedStorage.SharedModules.TickAPI)` | 5 / 3 / 1 |
| `require(game.ReplicatedStorage.SharedModules.StrikeManager.StrikeTickAPI)` | 2 |
| `require(script.TickAPI)` (FxPackageLite → its own wrapper copy) | 1 |
| `require(CoreHolder.Core.TickAPI)` / `require(Core.TickAPI)` (RoBase) | 1 / 1 |
| core modules `TickAPI.Tick/Tick2/Tick3` | 7 (wrappers only) |

Per-file require source (tick-caller files): live: main 191, main+strike 2, comment-only 4, **no require but live calls 1** — `RF/LO/Modules/CameraClass/xray.luau:87` uses a **global** `TickAPI`, which exists only because `SG/TradeWindow/HolderFrame/TradeControlUI.luau:11` (client) and `RS/SM/Game_Manager/PlayerLoading/PlayerLoadingManagerServer/LoginComms.luau:33` (server) assign `TickAPI = require(...)` without `local`. Plugin: robase 37, main+robase 3, main 3, fxlite 1. Archive: main 15, robase 2.

### 1d. The five wrapper copies and who calls each

| copy | driver | surface delta vs canonical | callers |
|---|---|---|---|
| `RS/SM/StrikeManager/StrikeTickAPI/StrikeTickAPI.luau` (+ own `Tick.luau`, canonical core minus one error string) | Stepped, `.Tick` only, no `SafeStopClock` | none | 2 files: `RS/SM/RepUpdateManager/UpdateAction/UpdateAction_ActionServerHitScan.luau:46` (delay `:333`, `:407`), `RS/SM/RepActionManager/Action/Attack/Action_ConeHitScan/Action_ConeHitScan.luau:41` (delay `:300`, `:415`, `:561`). Handles are stopped through the MAIN wrapper's `TickAPI.SafeStopClock` via `EntityAction:AddTimer` (`UpdateAction_ActionServerHitScan.luau:442` → `EntityActionClass.luau:89`) — cross-wrapper stop works only because `stop()` is a handle method (`e.parent`). |
| `RF/LO/Init_Scripts/SetupCliffAreaScreenSize_AndANIMATION/TickAPI/TickAPI.luau` (+ `Tick.luau` without `adjust`/`reset`, no nil-skip) | RenderStepped inside a coroutine, `.Tick` only | missing adjust/reset | **0 callers — dead copy.** The sibling `SetupCliffAreaScreenSize_AndANIMATION.luau:21` requires the MAIN wrapper (`recur` at `:86` with `FPS = 1/30` `:42`, `SafeStopClock` `:105`). |
| `SS/RoBase/Core/TickAPI/TickAPI.luau` (+ `Tick.luau`: no `event:adjust`/`event:reset`, has a broken group-level `tick:reset`, no nil-skip) | Heartbeat inside a coroutine, `.Tick` + `SafeStopClock` | missing adjust/reset | 42 plugin files (37 robase-only + 3 main+robase + 2 archive), all under `SS/RoBase/*`; 20 of the 21 plugin `Tick.recur` sites are the duplicated `HideAndShow.luau:102` search-box modules. Plugin callers use `:stop()` directly 6×, never `:reset`/`:adjust` (so the missing methods are not hit). |
| `SS/RoBase/Core/SimAnimLite/FxPackageLite/TickAPI/TickAPI.luau` (+ `Tick.luau`: adds `event:setClock(x)` `:56`, no adjust/reset, no nil-skip) | Heartbeat, `.Tick` + `SafeStopClock` | +setClock (0 callers) | 1 file: `SS/RoBase/Core/SimAnimLite/FxPackageLite/FxPackageLite.luau:17` (`TimeManagerAPI = require(script.TickAPI)`; 7 delay + 1 recur + 2 SafeStopClock) |
| `SS/DEVELOPER/ARCHIVE_VAULT/PureScriptCopies/TickAPI/TickAPI.luau` (+ Tick/Tick2/Tick3) | Stepped/Heartbeat/RenderStepped (same as main, older SafeStopClock form) | none | 0 callers (archive) |
| MAIN `RS/SM/TickAPI/TickAPI.luau` | Stepped→`Tick`, Heartbeat→`Tickh`, RenderStepped→`Tickr` (client only) | canonical | ~200 requiring files; also required under a second name `TimeManagerAPI` in `RS/SM/RepActionManager/SimAnim/FxPackage/FxPackage.luau:25` (and again as `TickAPI` at `:34`) |

### 1e. Client / server split (live tier, non-comment delay/recur calls)

| side (by container) | Tick.delay | Tick.recur | Tickh.delay | Tickh.recur | Tickr.delay | Tickr.recur | Strike | alias Tickh |
|---|---|---|---|---|---|---|---|---|
| client (RF, SG, SP) | 19 | 10 | 13 | 11 | 0 | 2 | 0 | 0 |
| shared (RS) | 20 | 13 | 29 | 10 | 1 | 2 | 5 | 8 |
| server (SSS) | 17 | 6 | 21 | 19 | 0 | 0 | 0 | 0 |

Files mentioning TickAPI by container: client 57, shared 92, server 119 (of which 48 are the RoBase plugin and 18 archive/dev). Zero server-container files reference `TickAPI.Tickr`; the two shared-module Tickr users are client-guarded (`CharacterSheet_Animation.luau:56,342`; `DefaultBurstType_Original.luau` is a client FX module). Server code uses Heartbeat (`Tickh`) more than Stepped (`Tick`): 40 vs 23.

---

## 2. Usage patterns

**P1. Timers created inside timer callbacks.** Statically nested creation is rare: **2 sites, depth 1** — `RF/LO/Modules/CameraClass/CameraClass.luau:312→315` (`Tick.delay` inside `Tick.delay`; inner delay is `fadeOutTime`, defaulted to `0` at `:307` → a nested delay-0 that legacy fires synchronously via the `d < 0` path, `Tick.luau:184-190`) and `RF/LO/Modules/InputMouseManager.luau:425→430` (a `Tickh.delay` callback creates a `Tick.recur` — **cross-scheduler**: Heartbeat callback schedules a Stepped timer). Dynamic nesting (callback → method → timer) is common: `FxPackage.luau:1049` recur → `_processAllContextData` → `StoreClock(TimeManagerAPI.Tickh.delay(...))` `:680`, `:741`; `AfterNotTouchedClass.luau:45-51` callback → `self:Destroy()` → `SafeStopClock` of its own clock `:74`; `SSS/Modules/EventSpawnerClass.luau:406` `WaveClock` recur → `Release()` → `for i=1,SpawnNumber: Tick.delay(..., 0.25*i)` `:345-354`.

**P2. Callbacks that stop their own handle (remove-from-inside-own-callback): 21 sites** (15 recur "poll until ready then stop", 6 delay "nil myself when I fire"): `CertingModerator.luau:73,178,221,244`; `RF/LO/Modules/HitFx/BurstTextFX/BurstTextFX.luau:239`; `InputMouseManager.luau:361,425`; `SoundEffectVolumeConstructor.luau:66`; `RF/LO/Modules/VirtualMouse/VirtualMouse.luau:197`; `CharacterSheet_Initilizations.luau:258`; `CharacterSheet_StatAdjustments.luau:570`; `CharacterSheet.luau:803`; `GroupClass.luau:471,1004`; `MobileEnemyClass.luau:720`; `IntroductionAreaAbridged.luau:211`; `TowerOfTest.luau:98`; `EventSpawnerClass.luau:406`; `GroupManagment.luau:68`; plugin `GenericDropDown.luau:638`, `EventConnections.luau:123`. Legacy tolerates this because `update` iterates backwards and `remove(i)` swaps the last element in (`Tick.luau:141-149`). Stopping *other* timers from a callback also happens: `EntityActionClass.luau:81-95` (`Cancel` iterates `TimerTable`) is invoked from strike callbacks.

**P3. Timers stored on objects and released in teardown.** 106 handle fields/locals; `SafeStopClock` is called 80× in live+plugin callers, 19× with the `x = SafeStopClock(x)` reassign idiom; enclosing functions (leaf names): `_teardown` 6, `KillSelf` 4, `Disban` 3, `Destroy` 2, `Kill` 2, `RemoveHoldTimer` 2, `onRelease`, `_ReleaseLockedAura` … — 24 of 80 inside destroy/cleanup/stop-named functions, the rest in state transitions. Bulk release of collections: `FxPackage.luau:1156` (`Lume.each(self.EventClocks, SafeStopClock)`), `EntityActionClass.luau:83-95`, `CharacterSheet_Animation.luau:141` (`_clearAllClocks`). `SafeStopClock` is routinely applied to handles that already fired naturally (every teardown after a one-shot; `FxPackage.luau:1340-1342`), i.e. the F3 leak path is exercised constantly.

**P4. After-chains: none.** 0 live `:after(` on Tick handles (see 1b). Legacy F8 has no live exposure.

**P5. adjust (ratio semantics) — 2 sites, both on one-shot handles, both depend on ratio-preserving retime:**
- `CharacterSheet_Animation.luau:153-159` `_updateSetUpClocks`: for each stored `{originalTime, clock}` in `self.StepClockBag`, `clock:adjust(originalTime / self.MovementAnimSpeed)` — footstep-sound clocks (`Tickr.delay` at `:218`, delay `Time / MovementAnimSpeed` `:216`) are re-timed when the animation speed changes; the elapsed fraction must be preserved.
- `UpdateAction_ActionServerHitScan.luau:452-462`: after `ActionData.WaitForAdjustedTime` (a SyncedTimer event) `StrikeClock:adjust(clamp(timeOfFrame,0.016,1000)/(ActionSpeed*FinalAnimationSpeedMod))` retimes a `StrikeTickAPI.Tick.delay` strike-detection window (`:407`, initial delay `adjustedFrameTime` `:405`). The guard `if StrikeClock == nil` `:458` never fires (variable is never nilled), so `adjust` can run on an already-fired handle → must be a silent no-op, never an error.

**P6. reset:** 7 on one-shots = "extend the timeout" (debounce): effect-duration bars (`EffectStatusBarItem.luau:172`, `TargetEffectStatusItem.luau:201`), hit-flash timeout (`HitFlashObject.luau:247`), bass-sound cooldown (`SoundControler.luau:320`), group-data clock (`GroupManagment.luau:64`), spawner sleep (`Spawner.luau:355`), `AfterNotTouched:Touch` (`AfterNotTouchedClass.luau:63`). **2 on recurring**: `WorldStateManager.luau:146-168` dead-man's switch (`Tick.recur` every `0.016*3`, `reset()` on every processing pass — reset on a recur must re-arm a full period from now), `DefaultBurstType_Original.luau:79,242` (`Tickr.recur` burst counter reset on each burst). Reset is guarded by `~= nil` at 6 of 9 sites but the variable is not always nilled on natural fire, so reset on a dead handle happens (legacy: sets `timer` on a detached event, no revive) — keep as no-op.

**P7. delay 0 / tiny periods.** No literal `0` delay or period. Computed 0: `CameraClass.luau:307/318` (`fadeOutTime or 0`). Tiny: `Tickr.recur 0.01` (`AbilityClass_Utility.luau:287-301`, cooldown text refresher — legacy fires it ~1.6×/frame at 60 fps by the catch-up `while` loop `Tick.luau:145`), `Tickr.recur 0.048` (`HitFlashObject.luau:126`), `Tickh.delay 0.02` (`RS/SM/DataBaseCache/DataBaseCache.luau:381`, "one frame of breathing room"), recur `FPS = 1/24` (`RF/Loading/LoadingScreen/AnimatedFlipLoadingWheel/AnimatedFlipLoadingWheel.client.luau:9,119`) and `1/30` (`AnimatingLoadingWheel.client.luau:9,51`; `SetupCliffAreaScreenSize_AndANIMATION.luau:42,86`) flipbook animations, `0.07` (`DefaultBurstType_Original.luau:61` queue pump), `0.10` (`InputMouseManager.luau:382`), `0.15` (`MiniMapRegulator.luau:779`, `InputMouseManager.luau:442`). Literal-argument distribution over all delay/recur calls: ≥0.5 s: 93, 0.05–0.5 s: 47, <0.05 s: 3; identifier/field: 94; expression: 27.

**P8. Non-number delays.** No string literals. Risky computed values: `RF/LO/Modules/HardPointSFXManager.luau:57` `AttatchmentInstance:GetAttribute("LifeTime")` (nil if the attribute is missing → legacy errors `expected delay to be a number`, `Tick.luau:171`), `AbilityClass_Utility.luau:311` `tonumber(Value)`, `AmbienceRandomNoise.luau:63` `math.random(min,max)`, `AmbientTrackManagement.luau:59` `forcedFadeOutTime + 0.25`, DB-sourced `FPS` (`DataBaseCache.luau:437`, `PhysicalFx.luau:150`). The legacy core coerces with `tonumber(delay)` (`Tick.luau:166`), so numeric strings from config work today; the prior rebuild keeps this (`P/build/src/TickAPI/Handle/init.luau:84`).

**P9. Cross-wrapper mixing.** `EntityAction.TimerTable` holds StrikeTickAPI handles, main-wrapper handles and SyncedTimer Id strings together (`UpdateAction_ActionServerHitScan.luau:107,123,372,442,453,510`), discriminated by `type(x) == "table"` (`EntityActionClass.luau:88-93`): tables → `TickAPI.SafeStopClock`, else → `SyncedTimer:ForceEventComplete`. **A handle must remain a table**; a numeric/string handle id would be routed to SyncedTimer.

**P10. Colon misuse (live bug).** `PrimaryCardControler.luau:115-144`: `TickAPI.Tick:remove(LastTickObject)` at `:124` and `:141` is intended to cancel the hover-card delay before creating a new one (`:125`) or on mouse-leave (`:141`). In legacy `bound.remove` receives the bound table as `e`, sets `group[bound] = false` and scans for `bound` (never found) — the real timer is never removed, so stale `setVisibleFlag(Data)` timers still fire and the variable is overwritten. Only sites in the whole mirror; same code duplicated in the archive REFERENCE_VAULT.

**P11. Global leak.** `xray.luau:87` depends on the global `TickAPI` assigned by `TradeControlUI.luau:11` (see 1c).

---

## 3. What a drop-in compatibility layer MUST preserve, and who would notice deviations

Must preserve (all counts live tier):
1. `TickAPI.Tick`, `TickAPI.Tickh`, `TickAPI.Tickr` (client-only; nil on server is never touched) tables exposing `.delay(fn, t)` and `.recur(fn, t)` called with **dot** syntax (206 calls), returning a **truthy table** handle (P9; 71 nil-checks; `if self["PressedClock"]` `InputMouseManager.luau:359`).
2. `TickAPI.SafeStopClock(h)` accepting nil, idempotent, **returning nil** (19 reassign sites); `TickAPI.GetAfterNotTouched(t, fn, "Tickh"|"Tick"|"Tickr")` returning an object with `:Touch()`/`:Destroy()` (1 caller; `AfterNotTouchedClass.Storage` has 0 external readers, so the Id type is free).
3. Handle methods `:stop()` (12), `:reset()` (9, incl. 2 on recur), `:adjust(n)` (2, ratio semantics on one-shots; no-op after fire). `:after` can be kept for rxi parity but has 0 callers.
4. `tonumber` coercion of the delay; error on non-numeric (matches legacy; `HardPointSFXManager.luau:57` would surface a nil attribute either way).
5. Delay `0` legal for one-shots (`CameraClass.luau:307`); reject only `recur` period ≤ 0 (no live caller passes one).
6. Stop/remove from inside the handle's own callback (21 sites) and stopping other handles from a callback (`EntityActionClass.luau:81-95`).
7. Stop on an already-fired or already-stopped handle is silent (dozens of teardowns; P3).
8. Separate scheduler instances per driver: Stepped (`Tick` 85 calls + `StrikeTickAPI.Tick` 5), Heartbeat (`Tickh` 111), RenderStepped (`Tickr` 5); a handle stopped through a different wrapper's `SafeStopClock` must still stop (P9: Strike handles stopped via main `SafeStopClock`).
9. `dt`-driven `update(dt)` from the RunService signals (`TickAPI.luau:38-56`) — no caller calls `update` or passes absolute time.

Deviations and who notices:
- **Same-frame ordering (legacy newest-first → due-then-creation order).** Sites that create several timers with equal delays in one frame: `SSS/Modules/DungeonCreator/DungeonCreator.luau:167-179` (one `Tickh.delay(…,3)` per player), `xray.luau:63-87` (one `Tick.delay` per obscuring part, same delay), `FxPackage.luau:680/741` (VFX and sound contexts sharing a `TaggedKeyTable` key), `EventSpawnerClass.luau:345-354` (`0.25*i`, distinct). None of their callbacks depend on sibling order (independent parts/players/FX). **No caller found that relies on newest-first.**
- **Nested already-past-due event fires later in the same update instead of synchronously.** Only `CameraClass.luau:312-322` (delay-0 inner; `self.isShaking=false` lands one update later — harmless) plus dynamic cases where FxPackage `TaggedKeyTable` delays could be ≤ dt. No caller observed relying on the synchronous path.
- **Idempotent stop** — purely beneficial; no observable difference except memory (closes F3 for the 68 SafeStopClock sites).
- **getClocks returning a real count** — 0 callers; only the Cmdr `MCPDiagnostic` commands (`SSS/Cmdr/Cmdr/BuiltInCommands/MCPDiagnostic/*.luau`, 12 `Tickh.recur` pollers) would be candidates to consume it.
- **recur catch-up vs coalesce when `dt > period`** (not listed in ASSESSMENT): legacy fires k times per update (`Tick.luau:145-156`). Affected: `Tickr.recur 0.01` (`AbilityClass_Utility.luau:287`), `1/24` and `1/30` flipbooks (P7), `0.048` blink. Coalescing would slow flipbook animations at low frame rates; catch-up keeps timing but bursts callbacks.
- **AfterNotTouched Id integer instead of GUID** — no external reader; safe.

---

## 4. SyncedTimerClass callers

Requires (16 files): `SSS/Cmdr/Cmdr/BuiltInCommands/DevTools/testSyncedTime.luau:1`, `.../testSyncedTimeServer.luau:1`, `RS/SM/StrikeManager/StrikesOverTimeClass.luau:14`, `RS/SM/Status/Status.luau:25`, `RS/SM/Status/private_Status.luau:9`, `RS/SM/Status/ChainedStatus.luau:18`, `RS/SM/RepUpdateManager/UpdateAction/UpdateAction_ActionServerHitScan.luau:27`, `RS/SM/RepActionManager/SimAnim/FxPackage/FxPackage.luau:35` (as `SyncedTime`), `RS/SM/RepActionManager/Action/Attack/Action_ConeHitScan/Action_ConeHitScan.luau:17`, `RS/SM/RepActionManager/Action/Action.luau:35`, `RS/SM/RepActionManager/Action/Action_Utility.luau:17`, `RS/SM/AlertClass/GroupInviteAlert.luau:23`, `RS/SM/EffectsManagerClass/Effects/Effects.luau:65`, `RS/SM/PlayerResources/DashStacks.luau:12`, `RF/LO/UIControls/NoficationWindow/BaseNotificationComponent/GroupInviteNotificationComponent.luau:40`, `RF/LO/Modules/AbilityClass/AbilityClass_Utility.luau:9`; plus `RS/SM/EntityActionClass.luau` (uses `SyncedTimer:ForceEventComplete` `:92`).

| method | calls | files | examples |
|---|---|---|---|
| `AddEvent(LifeTime, func, Id, ...)` | 27 | 12 | `Action_ConeHitScan.luau:100,154,198,227,739,753,761,835,844,852` (10); `UpdateAction_ActionServerHitScan.luau:89,113,166,454,511`; `GroupInviteAlert.luau:150,167`; `Effects.luau:175,223`; `GroupInviteNotificationComponent.luau:135`; `private_Status.luau:29`; `StrikesOverTimeClass.luau:80`; `Action_Utility.luau:186`; `DashStacks.luau:22`; `FxPackage.luau:1388`; Cmdr tests ×2 |
| `ForceEventComplete(Id)` | 5 | 5 | `Status.luau:95` (in `KillMe`), `Effects.luau:301`, `EntityActionClass.luau:92` (in `Cancel`), `GroupInviteAlert.luau:322`, `GroupInviteNotificationComponent.luau:220` |
| `DeleteEvent(Id)` | 3 | 2 | `ChainedStatus.luau:62`, `GroupInviteAlert.luau:303,318` |
| `ResetTimer(Id[, time])` | 3 | 3 | `Effects.luau:219` (no time → LifeTime), `Status.luau:84` (`Time or LifeTime`), `private_Status.luau:26` (`self.LifeTime`) |
| `AdjustTime(Id, newTotal)` | 1 | 1 | `UpdateAction_ActionServerHitScan.luau:113-121` |
| `GetRemainingTime(Id)` | 2 | 2 | `AbilityClass_Utility.luau:295` (cooldown countdown text), `StrikesOverTimeClass.luau:72` |
| `HasObject(Id)` | 2 | 2 | `private_Status.luau:25`, `Action.luau:316` (`HasCoolDown`) |
| `GetWorldTime` / `GetItemFromStorage` / `ProcessEvents` external | 0 | — | — |

Ids passed: `self.Id` = `MostlyUUID.uuid()` (`GroupInviteAlert.luau:59`, `StrikesOverTimeClass`), `OwnerId..Name` string (`private_Status.luau:15-17` `_createStatusId`), `self:CoolDownId()` string (`Action_Utility.luau:184`), `nil`/omitted → `HttpService:GenerateGUID()` (Effects, ConeHitScan, FxPackage, Cmdr). **Varargs (`...` → `Data`) are never used by any caller** (every call has ≤ 3 args). `func = nil` is used deliberately as a pure keyed cooldown marker (`Action_Utility.luau:186-190` + `HasObject`). Caller bug: `DashStacks.luau:22-26` passes the *result* of `CharacterSheet:StatChange("DashStacks",1)` (returns nil, `CharacterSheet_StatAdjustments.luau:648-672`) as `func`, so the stat changes immediately and a NOOP fires after 4 s; SyncedTimer never validates callability (Tick does, `Tick.luau:168`). Probable caller bug: `UpdateAction_ActionServerHitScan.luau:113-121` reassigns `FXTimerId` to the wait event and then `AdjustTime(FXTimerId, …)` inside that event's own callback — it adjusts itself (already dequeued), not the FX event created at `:89`.

**ForceEventComplete semantics in the live class are deferred, not immediate**: `_SetEventTimeToCurrentTime` only sets `ForcedComplete = true` (`SyncedTimerClass.luau:280-290`; the re-key lines are commented out at `:278`, `:286`), and `_isNextEventValidToProcess` honours the flag only at the heap **root** (`:326-337`). A forced non-root event therefore runs at its natural due time. All five callers read as expecting "complete now" (status kill, effect stack removal, action cancel, alert dismissal). The revamp's `ForceEventComplete` should decrease-key to now (or pop directly) and run the callback in the next update.

---

## 5. Other timer-like utilities in H (convergence candidates)

| utility | location | mechanism | live use |
|---|---|---|---|
| SyncedTimerClass | `RS/SM/SyncedTimerClass.luau` | MinHeap on world time (server Stepped `:427`, client `SyncTime` `:416`) | 16 files (§4) |
| TimeManager / TimeCron | `RS/SM/RepActionManager/SimAnim/FxPackage/TimeManager.luau` (+ `TimeCron`), plugin copies `SS/RoBase/Core/GlobalTimeManager/GlobalTimeManager.luau`, `SS/RoBase/Core/SimAnim/FxPackage/TimeManager.luau` | six round-robin clock tables pumped on Stepped/`BindToRenderStep`/Heartbeat (`:82,115,139,162,185,209`) | `CreateAfterClock` 1 caller (`Action_ConeHitScan.luau`), `TimeCron` 3 mentions — nearly dead |
| TimeLineClass / TimeLineProcessor | `RS/SM/TimeLineClass/*` (`FPS = 60` `TimeLineClass.luau:37`), plugin copy `SS/RoBase/Core/TimeLineClass` | Stepped-driven timeline storage (`TimeLineProcessor.luau:62`) | 8 mentions / 4 files |
| JobCoolDownStatus | `SSS/Modules/BaseEntityClass/BaseEntityClassIncludes/SequenceService/JobCoolDownStatus.luau` | WorldTime-stamped cooldown objects polled by `UpdateJobCoolDowns` on Stepped (`SequenceService.luau:41`) | 17 mentions / 2 files |
| GranularTween | `RS/SM/GranularTween.luau:512`, `SS/RoBase/Core/GranularTween.luau:506` | Heartbeat tween with `:stop()` handles (accounts for most non-Tick `:stop()` receivers: `currentLerp`, `CurrentMainBarTween`, `GranularTweenObj`) | 14 mentions / 4 files |
| WaitFor / Promise | `RS/SM/WaitFor/Promise.luau`, `RS/SM/ActorPool/Promise.luau` | `Promise.delay` (Heartbeat-driven) | 0 game callers outside the libraries |
| EffectsTracking | `RS/SM/EffectsTracking.luau:49` | Stepped world-effects regulator ("POSSIBLY DEPRECIATION") | — |
| SyncTime / WorldTimeMod | `RF/LO/Modules/SyncTime.luau`, `Workspace/Terrain/WorldTime/WorldTimeMod.luau:22` | server Stepped → `WorldTime.Value`; client remote sync feeding SyncedTimerClient | infrastructure for SyncedTimer |
| ThinkScheduler, RoMeshRebuildScheduler, Shadeoid `Net/Clock` | `SSS/.../ThinkScheduler.luau`, `RS/RoMesh/Dynamic/RoMeshRebuildScheduler.luau`, `RS/Shadeoid/Net/Clock/Clock.luau` | frame-budget schedulers / session clock — not timers | leave alone |
| raw RunService loops outside the wrappers | — | `Heartbeat:Connect` 41 sites/35 files, `Stepped:Connect` 38/30, `RenderStepped:Connect` 13/13, `BindToRenderStep` 11/8 (game update threads: `RS/SM/Game_Manager/Threads/*`, `SSS/Modules/BaseEntityClass/BaseEntityClass.luau:71,134`, `SpawnManager.luau:645`, `FlockService.luau:625`, `MediatorAPI.luau:661`, …) | many are per-frame simulations, not countdowns |
| `task.delay(` / `task.wait(` / legacy `wait(` / legacy `delay(` | — | 31/28 files; 170/102; 322/254 (mostly Roblox PlayerModule + old scripts); 3/1 (`SS/RoBase/Core/RbxGui.luau`) | ad-hoc one-shots |
| ad-hoc cooldown/debounce | — | `Cool[Dd]own` 264 tokens/41 files (action cooldowns = SyncedTimer Ids; UI countdown = `Tickr.recur 0.01` + `GetRemainingTime`); `Debounce` 6/5 | — |

Strongest convergence targets: SyncedTimerClass (keyed/world-time timers + `ForceEventComplete`, `HasObject`, `GetRemainingTime`), the 40 fire-and-forget `recur` pollers (would become named/owned timers), TimeManager/TimeCron and JobCoolDownStatus (both near-dead, replaceable by keyed timers).

---

## 6. Verification of `P/build/reports/ASSESSMENT.md` live-use counts

| symbol | ASSESSMENT | this survey (raw, same method) | live non-comment | note |
|---|---|---|---|---|
| Tickh | 117 | 117 (71 delay + 46 recur, incl. comments/plugin/archive) | 103 | matches; raw includes 10 commented-out lines |
| SafeStopClock | 92 | 92 (88 calls any prefix + 4 wrapper definitions) | 68 calls (+1 internal) | matches |
| Tick.delay | 84 | 85 (90 if the `StrikeTickAPI.Tick.delay` substring is counted) | 56 | ASSESSMENT ≈ raw; 14 of the raw are the RoBase plugin, 8 are comments |
| Tick.recur | 57 | 60 | 29 | raw; 21 are plugin (20 duplicated `HideAndShow.luau:102`) |
| Tickr | 10 | 10 tokens (1 delay + 7 recur + 2 wrapper lines) | 5 calls | matches; 3 of the 7 recur are commented out |
| GetAfterNotTouched | 1 | 1 | 1 | matches |
| handle:stop | 71 | 69 whole-mirror `:stop(` tokens | **12** on Tick handles (+6 plugin, +4 wrapper-internal) | ASSESSMENT counted every `:stop(` — 10 are `event:stop` core definitions, ~30 are GranularTween/Tween handles |
| handle:reset | 45 | 42 whole-mirror `:reset(` tokens | **9** on Tick handles | 8 are core definitions, rest are `self:reset()`, `ShuffleSelect:reset()`, tweens, etc. |
| handle:after | 31 | 31 whole-mirror `:after(` tokens | **0** on Tick handles | all 31 are core definitions, the BaseClass Callbacks mixin (`MobileEnemy:after("_A","_B")`) or other libs — F8 has no live exposure |
| handle:adjust | 9 | 9 whole-mirror | **2** | 7 are `event:adjust` core definitions |
| getClocks | 0 | 0 | 0 | matches |

Additional ASSESSMENT-adjacent facts: F10's `setClock` has 0 callers; the RoBase group-level `tick:reset` has 0 callers; the ReplicatedFirst wrapper copy has 0 callers (dead); the deviation list omits the recur catch-up/coalesce question (§3) and the colon-misuse no-op (`PrimaryCardControler.luau:124,141`).
