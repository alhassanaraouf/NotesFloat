# Changelog

What changed in each NotesFloat release. The section for a version becomes its GitHub release notes and is
shown in the in-app update window. Add changes under **Unreleased** as you go; when releasing, rename it to
the version and date, then tag.

## [Unreleased]

### Added
- The welcome guide now introduces **quick capture** and offers the optional Accessibility permission it uses
  to grab selected text.

### Fixed
- **Arabic, Hebrew and other right-to-left notes** read and align like in Apple Notes: each paragraph takes its
  direction from its first letter, Arabic lines are right-aligned, and list bullets and numbers sit on the right.
- Dashed lists use "–" like Apple Notes. The plain "-" stuck to Arabic text.

## [0.3.2] - 2026-11-01

### Added
- **Quick capture** (⌃⌥⇧N): adds the selected text (with Accessibility) or the clipboard to a note without
  opening the window. Also in any app's **Services › Add to NotesFloat**. Choose the note with
  ⌘K › Capture Into This Note.
- **Undo** after deleting a note: the note goes back to its folder.
- Opening a note from a content search jumps to the match and highlights it.
- VoiceOver labels for icon buttons and list rows; messages are announced.

### Changed
- **Permissions now survive updates.** NotesFloat is signed with a stable certificate, so macOS stops asking for
  Apple Notes, Full Disk Access and Accessibility again after each update. (It asks once more after updating to
  this version.)
- Saving happens in the background, so typing never pauses while a note saves.
- Numbered lists renumber as you move or add items, and show "1." like Apple Notes.

## [0.3.0] - 2026-10-30

### Added
- **Welcome guide** on first launch that sets up access to Apple Notes and the optional Full Disk Access.
- **Automatic updates** via Sparkle, with Settings › Updates to turn checking and automatic install on or off.
- **Themes**: Apple Notes (default), Liquid Glass, Graphite and Paper.
- Settings reorganised into General, Appearance, Permissions and Updates.

## [0.2.3] - 2026-10-30

### Fixed
- Top bar buttons no longer overflow the window's top edge when the window is hidden from screen sharing.

## [0.2.2] - 2026-10-30

### Changed
- Renamed to **NotesFloat** everywhere; the project now has a website at alhassan.raoufs.me/work/NotesFloat.

## [0.2.1] - 2026-10-30

### Changed
- New app identifier `me.raoufs.alhassan.NotesFloat`; settings carry over automatically.

## [0.2.0] - 2026-10-30

### Added
- App icon: an Apple Notes page floating above its tile.

## [0.1.0] - 2026-10-30

### Added
- First release: a floating, Raycast Notes-style window for Apple Notes that stays above full-screen apps, with
  a ⌘K command panel, notes search, Apple Notes formatting, pins, export and hide-from-screen-sharing.
