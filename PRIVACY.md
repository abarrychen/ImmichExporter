# Privacy

Immich Exporter is designed to operate locally on the Mac.

## Data the app accesses

- The Immich storage folder selected by the user
- The export destination selected by the user
- An Immich server URL and API key when user-name lookup or API export mode is used

## Data handling

- Media files are copied locally from the selected source to the selected destination.
- The app does not upload media to the developer or to any third-party service.
- API requests are sent only to the Immich server URL entered by the user. In API export mode, the app requests the selected user's download manifest and media archives.
- The API key is retained in application memory for the current session and is not intentionally persisted to disk.
- The app contains no analytics, advertising, crash-reporting SDK, or telemetry service.

## Network security

Use HTTPS whenever possible. An API key sent to an HTTP endpoint can be observed by other parties with access to the network path. Use only the access required for your server and revoke the key when it is no longer needed. Available API access depends on the Immich version, account role, and server settings.

## Temporary files

ZIP and API exports use a uniquely named hidden staging directory within the chosen destination. The app attempts to remove this directory after completion, cancellation, or failure. A crash or forced termination may leave a staging directory behind.
