# reference/ — read-only evidence snapshots (never edited, never required by build/)

Copied 2026-09-16 from HeroicSouls-BackUp @ fdb6efba8 (2026-08-25) and https://github.com/rxi/tick (master).
Prior rebuild for comparison: C:/Users/Faded/Documents/ClaudeProjects/RbxProjects/STUDIO_TASKS/TickAPIOptimize/build/src/TickAPI (not copied; read in place).

| file | origin | sha256 (16) | lines |
|---|---|---|---|
| live/AfterNotTouchedClass.luau | see SOURCES origin map below | 295c79a6fdba9979 | 80 |
| live/MinHeap.luau | see SOURCES origin map below | 7bc5c39b66b55aed | 261 |
| live/SyncedTimerClass.luau | see SOURCES origin map below | e15afe14ca25f7c9 | 435 |
| live/Tick.luau | see SOURCES origin map below | 93ca6a152716a576 | 232 |
| live/Tick2.luau | see SOURCES origin map below | 83a557f4d2eb9737 | 232 |
| live/Tick3.luau | see SOURCES origin map below | 83a557f4d2eb9737 | 232 |
| live/TickAPI.luau | see SOURCES origin map below | 8b5cd9f3d3a54390 | 89 |
| baseclass/BaseClass.luau | see SOURCES origin map below | 2cd16c8b484b9d6e | 274 |
| baseclass/Beholder.luau | see SOURCES origin map below | 4b6e25f45ea66e61 | 198 |
| baseclass/Callbacks.luau | see SOURCES origin map below | efae9c833e4c2320 | 289 |
| baseclass/Invoker.luau | see SOURCES origin map below | 572b26f6c54fa793 | 59 |
| baseclass/ObjectPool.luau | see SOURCES origin map below | 70f3c64bf3c5f4e4 | 328 |
| baseclass/Stateful.luau | see SOURCES origin map below | d7a02ce2c8a0e17a | 294 |
| rxi-tick/LICENSE | see SOURCES origin map below | 470cf16844c0e1c9 | 20 |
| rxi-tick/README.md | see SOURCES origin map below | 4e2ea2b570027306 | 86 |
| rxi-tick/tick.lua | see SOURCES origin map below | 9b1c8763883bca0e | 166 |

Origin map: live/* = ReplicatedStorage/SharedModules_[Folder]/{TickAPI_[Module]/*, SyncedTimerClass_[Module].luau, DataFoundery_[Module]/ADTs_[Folder]/MinHeap_[Module].luau}; baseclass/* = ReplicatedStorage/SharedModules_[Folder]/BaseClass_[Module]/{BaseClass_[Module].luau, HelperIncludes_[Folder]/*}; rxi-tick/* = rxi/tick GitHub master.
| build/vendor/BaseClass.luau | reference/baseclass/BaseClass.luau with the JsonR require replaced by a no-op registrar (test-only, never shipped) | 21960b8e125d1cd5 | 280 |
