## R. Require source per tick-caller file
   ('archive', 'main'): 15
   ('archive', 'robase'): 2
   ('live', 'main'): 191
   ('live', 'main+strike'): 2
   ('live', 'none(comment/other only)'): 4
   ('live', 'none(has live calls)'): 1
   ('plugin', 'fxlite'): 1
   ('plugin', 'main'): 3
   ('plugin', 'main+robase'): 3
   ('plugin', 'none(comment/other only)'): 1
   ('plugin', 'robase'): 37
   files with live TickAPI calls but no recognised require (param/upvalue/other path):
       RF/LO/Modules/CameraClass/xray.luau

## S. Live-tier calls by side x wrapper key (non-comment)
   client  TickAPI.Tick.delay               19
   client  TickAPI.Tick.recur               10
   client  TickAPI.Tickh.delay              13
   client  TickAPI.Tickh.recur              11
   client  TickAPI.Tickr.recur              2
   server  TickAPI.Tick.delay               17
   server  TickAPI.Tick.recur               6
   server  TickAPI.Tickh.delay              21
   server  TickAPI.Tickh.recur              19
   shared  StrikeTickAPI.Tick.delay         5
   shared  TickAPI.Tick.delay               20
   shared  TickAPI.Tick.recur               13
   shared  TickAPI.Tickh.delay              29
   shared  TickAPI.Tickh.recur              10
   shared  TickAPI.Tickr.delay              1
   shared  TickAPI.Tickr.recur              2
   shared  TimeManagerAPI.Tickh.delay       7
   shared  TimeManagerAPI.Tickh.recur       1
   server-side files that reference TickAPI.Tickr (would be nil on server):

## M. Dot-call misuse on handles (name.stop() etc.) in tick-caller files

## N. Callbacks that stop/SafeStopClock their OWN handle from inside the callback: 21
    ('RF/LO/Init_Scripts/LocalInitilizer/LocalGeneralConfig/UI_Initilizer/CertingModerator/CertingModerator.luau', 73, 'recur', 'SaftyClock')
    ('RF/LO/Init_Scripts/LocalInitilizer/LocalGeneralConfig/UI_Initilizer/CertingModerator/CertingModerator.luau', 178, 'recur', 'SaftyClockDungeon')
    ('RF/LO/Init_Scripts/LocalInitilizer/LocalGeneralConfig/UI_Initilizer/CertingModerator/CertingModerator.luau', 221, 'recur', 'CharacterSheetCertClock')
    ('RF/LO/Init_Scripts/LocalInitilizer/LocalGeneralConfig/UI_Initilizer/CertingModerator/CertingModerator.luau', 244, 'recur', 'ServerTypeSelected')
    ('RF/LO/Modules/HitFx/BurstTextFX/BurstTextFX.luau', 239, 'delay', 'AlertCoolDownClock')
    ('RF/LO/Modules/InputMouseManager.luau', 361, 'recur', 'self.PressedClock')
    ('RF/LO/Modules/InputMouseManager.luau', 425, 'delay', 'self.HoldingTimer')
    ('RF/LO/Modules/SoundEffectVolumeConstructor.luau', 66, 'recur', 'CheckingClock')
    ('RF/LO/Modules/VirtualMouse/VirtualMouse.luau', 197, 'delay', 'self.DebugClock')
    ('RS/SM/CustomCharacterData/CoreCharacterSheet/CharacterSheet/CharacterSheetIncludes/CharacterSheet_Initilizations.luau', 258, 'recur', 'self.PingUpdateClock')
    ('RS/SM/CustomCharacterData/CoreCharacterSheet/CharacterSheet/CharacterSheetIncludes/CharacterSheet_StatAdjustments.luau', 570, 'recur', 'self.HealClock')
    ('RS/SM/CustomCharacterData/CoreCharacterSheet/CharacterSheet/CharacterSheet.luau', 803, 'recur', 'self.latchOnLockedAura')
    ('RS/SM/GroupClass/GroupClass.luau', 471, 'recur', 'self.StandByClock')
    ('RS/SM/GroupClass/GroupClass.luau', 1004, 'recur', 'CallForGroupClock')
    ('SSS/Modules/BaseEntityClass/MobileNPCClass/MobileEnemyClass.luau', 720, 'delay', 'self.currentRecoveryClock')
    ('SSS/Modules/BaseOverDungeonClass/IntroductionAreaAbridged/IntroductionAreaAbridged.luau', 211, 'recur', 'self.RegistrationTimer')
    ('SSS/Modules/BaseOverDungeonClass/TowerOfTest/TowerOfTest.luau', 98, 'recur', 'self.RegistrationTimer')
    ('SSS/Modules/EventSpawnerClass.luau', 406, 'recur', 'self.WaveClock')
    ('SSS/Modules/SpawnManager/Includes/GroupManagment.luau', 68, 'delay', 'GroupDataClock')
    ('SS/RoBase/Core/RobaseUIClasses/GenericDropDown/GenericDropDown.luau', 638, 'delay', 'self.DisappearClock')
    ('SS/RoBase/Core/RobaseUIClasses/MainMenu/MainMenuFilter/Includes/EventConnections.luau', 123, 'delay', 'self.SubTagUpdateClock')

## O. Tick calls created inside a for-loop: 4
    ('RF/LO/Modules/CameraClass/xray.luau', 87, 'delay', 'for')
    ('SSS/Modules/DungeonCreator/DungeonCreator.luau', 168, 'delay', 'for')
    ('SSS/Modules/EventSpawnerClass.luau', 346, 'delay', 'for')
    ('SS/RoBase/Core/DropDownConstructorClass/DropDownConstructorClass.luau', 212, 'delay', 'for')
## O2. Tick calls created inside a Lume.each/ipairs/pairs closure (equal-delay batch candidates): 0
