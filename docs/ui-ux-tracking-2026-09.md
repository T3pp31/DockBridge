# UI/UX improvement tracking (2026-09)

Parent issue: [#211](https://github.com/T3pp31/DockBridge/issues/211)

This document tracks the 2026-09 UI/UX survey items and their original pull requests.

Implementation evidence was reviewed in `main` at `510ad819d59f85a6733c46faade1cb49475f8353`.
The status column describes code in that tree, not GitHub PR lifecycle or acceptance-test results:

- **Code present**: corresponding implementation code is present; full survey acceptance remains to be verified.
- **Needs verification**: related code exists, but it does not establish that the survey item is implemented.
- **Original PR state: unverified for all rows.** GitHub merge/close history was not available during this offline review. Code presence does not establish that the linked PR was merged; an equivalent implementation may have arrived through another PR. Check the original PR before scheduling review or duplicate work.

## P0 — Safety and daily friction

| Issue | Title | Original PR | Implementation status | Evidence in main |
|-------|-------|-------------|-----------------------|------------------|
| [#212](https://github.com/T3pp31/DockBridge/issues/212) | Empty password save deletes Keychain | [#254](https://github.com/T3pp31/DockBridge/pull/254) | Code present | [ConnectionListViewModel.save](../apps/macos/DockBridge/ViewModels/ConnectionListViewModel.swift) |
| [#213](https://github.com/T3pp31/DockBridge/issues/213) | Interactive credential prompt on connect | [#256](https://github.com/T3pp31/DockBridge/pull/256) | Code present | [ConnectionListView credential sheet](../apps/macos/DockBridge/Views/Connection/ConnectionListView.swift) |
| [#214](https://github.com/T3pp31/DockBridge/issues/214) | Transfer overwrite policy and Ask prompt | [#257](https://github.com/T3pp31/DockBridge/pull/257) | Code present | [MainViewModel.runTransferOrAsk](../apps/macos/DockBridge/ViewModels/MainViewModel.swift), [MainView overwrite sheet](../apps/macos/DockBridge/Views/Main/MainView.swift) |
| [#215](https://github.com/T3pp31/DockBridge/issues/215) | Multi-select upload/download | [#235](https://github.com/T3pp31/DockBridge/pull/235) | Code present | [MainViewModel.uploadSelected / downloadSelected](../apps/macos/DockBridge/ViewModels/MainViewModel.swift) |
| [#216](https://github.com/T3pp31/DockBridge/issues/216) | Invalid DnD feedback | [#236](https://github.com/T3pp31/DockBridge/pull/236) | Code present | [FileDropModifiers rejection feedback](../apps/macos/DockBridge/Views/Main/FileDropModifiers.swift) |
| [#217](https://github.com/T3pp31/DockBridge/issues/217) | Drop onto folder rows | [#237](https://github.com/T3pp31/DockBridge/pull/237) | Code present | [LocalFileTable / RemoteFileTable row drop destinations](../apps/macos/DockBridge/Views/Main/FileDropModifiers.swift) |
| [#218](https://github.com/T3pp31/DockBridge/issues/218) | Keyboard shortcuts | [#238](https://github.com/T3pp31/DockBridge/pull/238) | Code present | [MainViewCommands](../apps/macos/DockBridge/Views/Main/MainViewCommands.swift) |
| [#219](https://github.com/T3pp31/DockBridge/issues/219) | Consolidate primary actions | [#239](https://github.com/T3pp31/DockBridge/pull/239) | Code present | [MainView toolbar](../apps/macos/DockBridge/Views/Main/MainView.swift), [PanePathBars navigation-only policy](../apps/macos/DockBridge/Views/Shared/PanePathBars.swift) |
| [#220](https://github.com/T3pp31/DockBridge/issues/220) | Collapsible transfer queue | [#240](https://github.com/T3pp31/DockBridge/pull/240) | Code present | [TransferQueueView.isExpanded](../apps/macos/DockBridge/Views/Transfer/TransferQueueView.swift), [MainView scene storage](../apps/macos/DockBridge/Views/Main/MainView.swift) |
| [#221](https://github.com/T3pp31/DockBridge/issues/221) | Single-row path bar | [#241](https://github.com/T3pp31/DockBridge/pull/241) | Code present | [PathSummaryRow](../apps/macos/DockBridge/Views/Shared/PathSummaryRow.swift), [PanePathBars](../apps/macos/DockBridge/Views/Shared/PanePathBars.swift) |
| [#222](https://github.com/T3pp31/DockBridge/issues/222) | DesignTokens | [#242](https://github.com/T3pp31/DockBridge/pull/242) | Code present | [DesignTokens](../apps/macos/DockBridge/UI/DesignTokens.swift), [TransferQueueView usage](../apps/macos/DockBridge/Views/Transfer/TransferQueueView.swift) |

## P1 — Competitive parity and HIG

| Issue | Title | Original PR | Implementation status | Evidence in main |
|-------|-------|-------------|-----------------------|------------------|
| [#223](https://github.com/T3pp31/DockBridge/issues/223) | One-click Reconnect | [#243](https://github.com/T3pp31/DockBridge/pull/243) | Code present | [ConnectionListView Reconnect action](../apps/macos/DockBridge/Views/Connection/ConnectionListView.swift) |
| [#224](https://github.com/T3pp31/DockBridge/issues/224) | Go to path | [#244](https://github.com/T3pp31/DockBridge/pull/244) | Code present | [GoToPathSheet](../apps/macos/DockBridge/Views/Main/GoToPathSheet.swift), [MainView presentation](../apps/macos/DockBridge/Views/Main/MainView.swift) |
| [#225](https://github.com/T3pp31/DockBridge/issues/225) | Contextual error recovery | [#245](https://github.com/T3pp31/DockBridge/pull/245) | Code present | [MainView error recovery actions](../apps/macos/DockBridge/Views/Main/MainView.swift) |
| [#226](https://github.com/T3pp31/DockBridge/issues/226) | Sidebar connection indicator | [#246](https://github.com/T3pp31/DockBridge/pull/246) | Code present | [ConnectionListView.connectionIndicator](../apps/macos/DockBridge/Views/Connection/ConnectionListView.swift) |
| [#227](https://github.com/T3pp31/DockBridge/issues/227) | Transfer queue column layout | [#247](https://github.com/T3pp31/DockBridge/pull/247) | Needs verification | [TransferQueueView.transferTable](../apps/macos/DockBridge/Views/Transfer/TransferQueueView.swift); see layout caveat below |
| [#228](https://github.com/T3pp31/DockBridge/issues/228) | Open / Quick Look | [#248](https://github.com/T3pp31/DockBridge/pull/248) | Code present | [LocalPaneView Open / Quick Look actions](../apps/macos/DockBridge/Views/Main/LocalPaneView.swift) |
| [#229](https://github.com/T3pp31/DockBridge/issues/229) | Finder-style file table | [#249](https://github.com/T3pp31/DockBridge/pull/249) | Code present | [LocalFileTable / RemoteFileTable and modifiedCell](../apps/macos/DockBridge/Views/Main/FileDropModifiers.swift) |
| [#230](https://github.com/T3pp31/DockBridge/issues/230) | Sheet footer buttons | [#250](https://github.com/T3pp31/DockBridge/pull/250) | Code present | [RemotePaneSheets footers](../apps/macos/DockBridge/Views/Main/RemotePaneSheets.swift), [GoToPathSheet footer](../apps/macos/DockBridge/Views/Main/GoToPathSheet.swift) |
| [#231](https://github.com/T3pp31/DockBridge/issues/231) | Status bar transfer summary | [#251](https://github.com/T3pp31/DockBridge/pull/251) | Code present | [ConnectionStatusBar.transferSummary](../apps/macos/DockBridge/Views/Shared/ConnectionStatusBar.swift), [MainView wiring](../apps/macos/DockBridge/Views/Main/MainView.swift) |
| [#232](https://github.com/T3pp31/DockBridge/issues/232) | Local drop label symmetry | [#252](https://github.com/T3pp31/DockBridge/pull/252) | Code present | [DropKind.overlayTitle](../apps/macos/DockBridge/Views/Main/FileDropModifiers.swift), [LocalPaneView overlay](../apps/macos/DockBridge/Views/Main/LocalPaneView.swift) |

Layout caveat (#227): [TableColumnLayout.swift](../apps/macos/DockBridge/UI/TableColumnLayout.swift) defines **file-table** widths used by `LocalFileTable` and `RemoteFileTable`, not transfer-queue widths. The current transfer queue has its own table in `TransferQueueView.swift`. The helper's existence alone is not evidence that #227's acceptance criteria are met; verify the original issue and the current macOS layout before marking it complete.

## P2 — Nice-to-have

| Issue | Title | Original PR | Implementation status | Evidence in main |
|-------|-------|-------------|-----------------------|------------------|
| [#233](https://github.com/T3pp31/DockBridge/issues/233) | Host key verification help | [#253](https://github.com/T3pp31/DockBridge/pull/253) | Code present | [HostKeyConfirmView verification guidance](../apps/macos/DockBridge/Views/Security/HostKeyConfirmView.swift) |
| [#234](https://github.com/T3pp31/DockBridge/issues/234) | Path bookmarks | [#258](https://github.com/T3pp31/DockBridge/pull/258) | Code present | [PathBookmarkStore](../apps/macos/DockBridge/Services/PathBookmarkStore.swift), [PanePathBars menus](../apps/macos/DockBridge/Views/Shared/PanePathBars.swift), [PathBookmarkStoreTests](../apps/macos/DockBridgeTests/PathBookmarkStoreTests.swift) |

## Completion criteria (#211)

The previous checked items recorded PR creation, not merge or feature acceptance. The code evidence above supersedes that review-queue snapshot, but does not establish that #211 is complete. Remaining verification:

- [ ] Confirm the original PR states on GitHub and reconcile any PR superseded by an equivalent implementation.
- [ ] Confirm P0 survey acceptance criteria against the current implementation and macOS behavior.
- [ ] Confirm P1 adopted survey acceptance criteria, including the #227 layout caveat.
- [ ] Confirm P2 tracked survey acceptance criteria where implemented.

## Keeping this tracker current

When a tracked PR is merged, closed, or superseded, update its row and the completion checklist in the same change that records the outcome. Record `Merged (#NNN)` only after checking GitHub's merge record; for an unmerged PR superseded by another implementation, link that implementation and record the original PR's actual disposition separately. Do not infer PR state or full acceptance from a source file's existence.

Include the reviewed main revision and implementation/test evidence when refreshing statuses. Keep unverified items explicit, and confirm the parent and child issues' acceptance criteria before closing #211. For this document's offline regression checks, run `python3 scripts/test-ui-ux-tracking.py` (row preservation, local evidence links, and removal of the stale blanket PR assertions); this does not query GitHub or test the macOS UI.

## Out of scope (not yet filed)

- ssh-agent integration
- VoiceOver detailed audit
- Drop overlay material enhancement
- Breadcrumb hover Finder parity
- Transfer pause / persistent history
