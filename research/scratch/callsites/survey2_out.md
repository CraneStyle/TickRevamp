## T. Counts by tier (live game / RoBase+plugin / archive), caller files only, commented-out lines excluded
| shape | live | plugin | archive | total | live files |
|---|---|---|---|---|---|
| TickAPI.Tick.delay( | 56 | 14 | 7 | 77 | 42 |
| TickAPI.Tick.recur( | 29 | 21 | 4 | 54 | 21 |
| TickAPI.Tickh.delay( | 63 | 0 | 3 | 66 | 39 |
| TickAPI.Tickh.recur( | 40 | 0 | 1 | 41 | 36 |
| TickAPI.Tickr.delay( | 1 | 0 | 0 | 1 | 1 |
| TickAPI.Tickr.recur( | 4 | 0 | 0 | 4 | 4 |
| TickAPI.Tick:remove( (colon misuse) | 2 | 0 | 2 | 4 | 1 |
| TickAPI.SafeStopClock( | 66 | 6 | 4 | 76 | 43 |
| TimeManagerAPI.SafeStopClock( | 2 | 2 | 0 | 4 | 1 |
| TickAPI.GetAfterNotTouched( | 1 | 0 | 0 | 1 | 1 |
| StrikeTickAPI.Tick.delay( | 5 | 0 | 0 | 5 | 2 |
| TimeManagerAPI.Tick.delay( (FxPackageLite/plugin) | 0 | 7 | 0 | 7 | 0 |
| TimeManagerAPI.Tick.recur( | 0 | 1 | 0 | 1 | 0 |
| TimeManagerAPI.Tickh.delay( (FxPackage alias) | 7 | 0 | 0 | 7 | 1 |
| TimeManagerAPI.Tickh.recur( | 1 | 0 | 0 | 1 | 1 |
commented-out occurrences excluded: {'TickAPI.Tick.delay(': 8, 'TickAPI.Tick.recur(': 6, 'TickAPI.Tickh.delay(': 5, 'TickAPI.Tickh.recur(': 5, 'TickAPI.Tickr.recur(': 3, 'TickAPI.SafeStopClock(': 7}

## U. Handle-name analysis (names assigned from a Tick delay/recur/after/GetAfterNotTouched call)
assigned handles (distinct file+name): 106; assignment sites: 118; fire-and-forget calls (result discarded, statement-level): 144, of which recur (unstoppable forever-timers): 40
   unstoppable recur examples: ['RF/LO/Init_Scripts/LocalInitilizer/LocalGeneralConfig/UI_Initilizer/UI_Initilizer.luau:45', 'RF/LO/Modules/UISystemBooter/InvitePlayerToGroupAssetClass.luau:309', 'RF/LO/Modules/UISystemBooter/QuestHudManager.luau:297', 'RF/LO/UIControls/GroupInviteWindow/GroupInviteController.luau:216', 'RF/LO/UIControls/GroupInviteWindow/GroupInviteController.luau:397', 'RS/SM/AssetDelivery/private_AssetDelivery.luau:763', 'RS/SM/BurstTextPool/BurstTextClass/BurstTextConfigSets/DefaultBurstType/DefaultBurstType_Original.luau:61', 'RS/SM/CustomCharacterData/CoreCharacterSheet/CharacterSheet/CharacterSheetIncludes/CharacterSheet_Animation/TestLocalSound.client.luau:13', 'RS/SM/Game_Manager/Threads/UpdateClientEntities.luau:35', 'RS/SM/GroupClass/GroupClass.luau:101', 'RS/SM/ObjectBouncer.luau:102', 'SSS/Initialize_Modules_Server/EnsureStoredEnemiesDefaultBoundSize.luau:64']
| usage on a Tick handle | count | live/plugin/archive | examples |
|---|---|---|---|
| :stop() | 24 | 12/6/6 | RF/LO/Modules/CameraClass/xray.luau:70 [delay] ObscuringItemManager.ObscuredCoolDown[id2]<br>RF/LO/Modules/SoundEffectVolumeConstructor.luau:69 [recur] CheckingClock<br>RF/LO/Modules/UISystemBooter/PaperDollView/PaperDollView.luau:228 [delay] ActiveClock<br>RS/SM/CustomCharacterData/CoreCharacterSheet/CharacterSheet/CharacterSheetIncludes/CharacterSheet_Animation/CharacterSheet_Animation.luau:138 [recur] self.AnimSpeedClockTracking<br>RS/SM/CustomCharacterData/CoreCharacterSheet/CharacterSheet/CharacterSheetIncludes/CharacterSheet_Animation/TestLocalSound.client.luau:59 [recur] AnimationSpeedConnect |
| :reset() | 7 | 7/0/0 | RF/LO/Modules/UISystemBooter/TargetBarManagerClass/TargetEffectsManagerClass/EffectStatusBarItem.luau:172 [delay] self.DurationClock<br>RF/LO/Modules/UISystemBooter/TargetBarManagerClass/TargetEffectsManagerClass/TargetEffectStatusItem.luau:201 [delay] self.DurationClock<br>RS/SM/BurstTextPool/BurstTextClass/BurstTextConfigSets/DefaultBurstType/DefaultBurstType_Original.luau:242 [recur] Clock<br>RS/SM/SoundControler/SoundControler.luau:320 [delay] SoundControler.BassPlayedCoolDownClock<br>RS/SM/WorldStateManager/WorldStateManager.luau:167 [recur] self.ProcessDeadManTimerObj |
| :adjust( | 2 | 2/0/0 | RS/SM/CustomCharacterData/CoreCharacterSheet/CharacterSheet/CharacterSheetIncludes/CharacterSheet_Animation/CharacterSheet_Animation.luau:158 [delay] clock<br>RS/SM/RepUpdateManager/UpdateAction/UpdateAction_ActionServerHitScan.luau:459 [delay] StrikeClock |
| SafeStopClock(name) | 75 | 63/8/4 | RF/Loading/LoadingScreen/AnimatedFlipLoadingWheel/AnimatedFlipLoadingWheel.client.luau:102 [recur] Clock<br>RF/Loading/LoadingScreen/AnimatedFlipLoadingWheel/AnimatingLoadingWheel.client.luau:103 [recur] Clock<br>RF/LO/Init_Scripts/LocalInitilizer/LocalGeneralConfig/UI_Initilizer/CertingModerator/CertingModerator.luau:78 [recur] SaftyClock<br>RF/LO/Init_Scripts/LocalInitilizer/LocalGeneralConfig/UI_Initilizer/CertingModerator/CertingModerator.luau:156 [recur] CertPingClock<br>RF/LO/Init_Scripts/LocalInitilizer/LocalGeneralConfig/UI_Initilizer/CertingModerator/CertingModerator.luau:184 [recur] SaftyClockDungeon |
| name = SafeStopClock(name) | 19 | 16/3/0 | RF/LO/Modules/HitFx/HitFlashObject.luau:153 [recur] self.BlinkingTimer<br>RF/LO/Modules/InputMouseManager.luau:365 [recur] self.PressedClock<br>RF/LO/Modules/InputMouseManager.luau:428 [delay] self.HoldingTimer<br>RF/LO/Modules/InputMouseManager.luau:455 [recur] self.PressedClock2<br>RF/LO/Modules/LocalEntityClass/LocalEntityClass.luau:433 [recur] self.EnablePositionConstraintToggleTimeObj |
| name = nil | 110 | 87/15/8 | RF/Loading/LoadingScreen/AnimatedFlipLoadingWheel/AnimatedFlipLoadingWheel.client.luau:31 [recur] Clock<br>RF/Loading/LoadingScreen/AnimatedFlipLoadingWheel/AnimatingLoadingWheel.client.luau:28 [recur] Clock<br>RF/LO/Init_Scripts/LocalInitilizer/LocalGeneralConfig/UI_Initilizer/CertingModerator/CertingModerator.luau:70 [recur] SaftyClock<br>RF/LO/Init_Scripts/LocalInitilizer/LocalGeneralConfig/UI_Initilizer/CertingModerator/CertingModerator.luau:92 [recur] CertPingClock<br>RF/LO/Init_Scripts/LocalInitilizer/LocalGeneralConfig/UI_Initilizer/CertingModerator/CertingModerator.luau:175 [recur] SaftyClockDungeon |
| ~= nil / == nil check | 71 | 47/12/12 | RF/LO/Modules/CameraClass/xray.luau:69 [delay] ObscuringItemManager.ObscuredCoolDown[id2]<br>RF/LO/Modules/HitFx/BurstTextFX/BurstTextFX.luau:233 [delay] AlertCoolDownClock<br>RF/LO/Modules/UISystemBooter/PaperDollView/PaperDollView.luau:227 [delay] ActiveClock<br>RF/LO/Modules/UISystemBooter/TargetBarManagerClass/TargetEffectsManagerClass/EffectStatusBarItem.luau:170 [delay] self.DurationClock<br>RF/LO/Modules/UISystemBooter/TargetBarManagerClass/TargetEffectsManagerClass/TargetEffectStatusItem.luau:200 [delay] self.DurationClock |
| name == x (non-nil) | 1 | 1/0/0 | RF/LO/Init_Scripts/LocalInitilizer/LocalGeneralConfig/UI_Initilizer/CertingModerator/CertingModerator.luau:148 [recur] ServerTypeSelected |
| type(name) | 1 | 1/0/0 | RS/SM/CustomCharacterData/CoreCharacterSheet/CharacterSheet/CharacterSheet.luau:754 [recur] self.latchOnLockedAura |
| passed as arg / stored elsewhere | 92 | 78/8/6 | RF/Loading/LoadingScreen/AnimatedFlipLoadingWheel/AnimatedFlipLoadingWheel.client.luau:102 [recur] Clock<br>RF/Loading/LoadingScreen/AnimatedFlipLoadingWheel/AnimatingLoadingWheel.client.luau:103 [recur] Clock<br>RF/LO/Init_Scripts/LocalInitilizer/LocalGeneralConfig/UI_Initilizer/CertingModerator/CertingModerator.luau:78 [recur] SaftyClock<br>RF/LO/Init_Scripts/LocalInitilizer/LocalGeneralConfig/UI_Initilizer/CertingModerator/CertingModerator.luau:156 [recur] CertPingClock<br>RF/LO/Init_Scripts/LocalInitilizer/LocalGeneralConfig/UI_Initilizer/CertingModerator/CertingModerator.luau:184 [recur] SaftyClockDungeon |
| :Destroy() on handle | 1 | 1/0/0 | RS/SM/CustomCharacterData/CoreCharacterSheet/CharacterSheet/CharacterSheet.luau:863 [recur] self.latchOnLockedAura |
recur handles that receive :reset():
    RS/SM/BurstTextPool/BurstTextClass/BurstTextConfigSets/DefaultBurstType/DefaultBurstType_Original.luau Clock
    RS/SM/WorldStateManager/WorldStateManager.luau self.ProcessDeadManTimerObj
recur handles that receive :after( or :adjust(:

## V. Whole-mirror counts of lowercase handle-method tokens (all *.luau, any receiver) — for reconciling ASSESSMENT.md
:stop(: total=69 files=49 in-tick-caller-files=45; top receivers: [('event', 10), ('currentLerp', 6), ('CurrentMainBarTween', 4), ('self.GranularTweenObj', 4), ('clockObj', 4), ('ActiveTweens', 4), ('CurrentShowCardDelayTimer', 4), ('Tween', 4), ('self.ProgressUpdateTween', 2), ('CurrentSmallBarTween', 2), ('DashTweenObject', 2), ('tween.ActiveTweens[TweenId]', 2)]
:reset(: total=42 files=34 in-tick-caller-files=9; top receivers: [('event', 7), ('self', 5), ('ShuffleSelect', 4), ('Clock', 4), ('flow', 3), ('self.DurationClock', 2), ('Tween', 2), ('svc', 2), ('GroupDataClock', 1), ('self.SleepClock', 1), ('NPC_Timer[TargetId]', 1), ('self.ProcessDeadManTimerObj', 1)]
:after(: total=31 files=15 in-tick-caller-files=4; top receivers: [('event', 10), ('so', 10), ('MobileEnemy', 4), ('MyClass', 2), ('Callbacks', 2), ('theClass', 2), ('SubKlass', 1)]
:adjust(: total=9 files=9 in-tick-caller-files=2; top receivers: [('event', 7), ('clock', 1), ('StrikeClock', 1)]

## W. Generic field tokens .timer/.fn/.parent/.err and .recur-not-call in tick-caller files (non-library, non-comment)
   SSS/Modules/DungeonCreator/DungeonCreator.luau:411: "[["..err .."]] \n" ..

## X. SafeStopClock enclosing function names (callers, non-comment)
by enclosing function (leaf name): [('_teardown', 6), ('KillSelf', 4), ('_setUpNewTimer', 4), ('_removeResetTimer', 4), ('processFrame', 3), ('_pingUntilDungeonIAmReady', 3), ('cancelAndFadeOutCurrentAmbient', 3), ('Disban', 3), ('cancelAndFadeOutCurrentMusic', 3), ('SetUpImageSprites', 2), ('AlertBurstText', 2), ('MouseHold', 2), ('RemoveHoldTimer', 2), ('Destroy', 2), ('Kill', 2), ('_triggerAFilterUpdateClock', 2), ('_pingThatClientIsReady', 1), ('CheckForIfClientIsReady', 1), ('SetUpCoolDown', 1), ('BlinkingOff', 1), ('_stopActionHoldingClock', 1), ('SetHoldTimerCheck', 1), ('_ReleaseLockedAura', 1), ('RemoveIconFromStatusBar', 1), ('DebugVMouse', 1), ('SetUpQueTimer', 1), ('ConsumeQuedAction', 1), ('_confirmLatchAndStopAttempts', 1), ('_setUpAuraLockClone', 1), ('Cancel', 1), ('SetupStandByMode', 1), ('_isWorldStatesSyncedComplete', 1), ('SimpleWaitUntil', 1), ('_setUpKillClock', 1), ('CleanUpAllStoredClocks', 1), ('_bassSoundTriggerLogic', 1), ('Remove', 1), ('SetupRecoveryTime', 1), ('SelfDestruct', 1), ('SetUpCustomSubscriptions', 1), ('RequestUntilComplete', 1), ('_removeTimerCheck', 1), ('setTimerForTempFlinch', 1), ('Setup_Subscriptions', 1), ('ResetGroupDataClock', 1), ('DeActivate', 1), ('ClearOutsideOfUITimer', 1), ('MouseOutsideOfUI', 1), ('_simpleWaitUntil', 1)]
SafeStopClock inside destroy/cleanup/stop/reset-like functions: 24 of 80

## Y. Identifier delays that are frame-rate-ish constants (FPS etc.)
   RF/Loading/LoadingScreen/AnimatedFlipLoadingWheel/AnimatedFlipLoadingWheel.client.luau:9: local FPS = 1/24
   RF/Loading/LoadingScreen/AnimatedFlipLoadingWheel/AnimatingLoadingWheel.client.luau:9: local FPS = 1/30
   RF/LO/Init_Scripts/SetupCliffAreaScreenSize_AndANIMATION/SetupCliffAreaScreenSize_AndANIMATION.luau:42: local FPS = 1/30
   RS/SM/DataBaseCache/DataBaseCache.luau:437: local FPS =  tonumber(DataBaseCache.DB[PhysicalFxId].FPS)
   RS/SM/RepActionManager/SimAnim/FxPackage/FxPackage.luau:1126: local FPS = self.FPS
   RS/SM/RepActionManager/SimAnim/FxPackage/FxPackage.luau:1132: FPS = FPS,
   RS/SM/TimeLineClass/TimeLineClass.luau:37: local FPS = 60
   RS/UI/LoadingScreenBuffer/AnimatedFlipLoadingWheel/AnimatedFlipLoadingWheel.client.luau:9: local FPS = 1/24
   RS/UI/LoadingScreenBuffer/AnimatedFlipLoadingWheel/AnimatingLoadingWheel.client.luau:9: local FPS = 1/30
   SS/RoBase/Core/TemplateHolder/PhysicalFx/PhysicalFx.luau:150: local FPS = tonumber(DataObject.FPS)
   SS/RoBase/Core/TimeLineClass/TimeLineClass.luau:32: local FPS = 60

## Z. Nesting scanner sanity test on synthetic snippet
(see survey.py section E; synthetic test executed in survey_nesttest.py)
