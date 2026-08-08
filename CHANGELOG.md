# Changelog

All notable changes to Immich Exporter are documented here.

## [1.1.0] - 2026-08-08

### Added

- Immich API export mode alongside direct NAS access
- Single-user and all-user API exports
- Server-generated ZIP downloads with 500 MB, 1 GB, 2 GB, and 4 GB part-size choices
- Folder output for API exports through automatic archive extraction
- Live byte-level API download progress and cancellation
- A stop control and 15-second timeout while loading API users
- Per-user folders and archive names for all-user exports

### Changed

- Reworked the source selection interface around NAS and API modes
- Made API key guidance neutral because access varies by Immich version, role, and server configuration
- Rewrote the project documentation and updated the application screenshot
- Updated privacy and security documentation for API media downloads

### Preserved

- Automatic UUID discovery and live scanning for mounted Immich storage
- Folder layout choices, optional XMP files, duplicate-name handling, and ZIP exports

## [1.0.0] - 2026-08-03

- Initial open-source release
- Direct export from mounted Immich storage
- UUID discovery, scan progress, bilingual interface, and folder or ZIP output
