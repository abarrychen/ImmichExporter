# Privacy

Immich Exporter is designed to operate locally on the Mac.

## Data the app accesses

- The Immich storage folder selected by the user
- The export destination selected by the user
- An Immich server URL and API key, only when the optional user-name lookup is used

## Data handling

- Media files are copied locally from the selected source to the selected destination.
- The app does not upload media to the developer or to any third-party service.
- The optional API request is sent only to the Immich server URL entered by the user.
- The API key is retained in application memory for the current session and is not intentionally persisted to disk.
- The app contains no analytics, advertising, crash-reporting SDK, or telemetry service.

## Network security

Use HTTPS for the optional Immich API lookup whenever possible. An API key sent to an HTTP endpoint can be observed by other parties with access to the network path. Create a dedicated API key with only the `user.read` permission and revoke it when it is no longer needed.

## Temporary files

ZIP exports use a uniquely named hidden staging directory within the chosen destination. The app attempts to remove this directory after completion, cancellation, or failure. A crash or forced termination may leave a staging directory behind.

