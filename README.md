# Lyrics in the Car

Lyrics in the Car is an iOS app that follows the song currently playing in Apple Music and displays synchronized lyrics without controlling playback.

The current lyric and the upcoming lyric are available in the app and in a Live Activity, including the Lock Screen and supported Dynamic Island layouts.

## Features

- Follows the system Apple Music player's current track and playback position.
- Loads synchronized lyrics from [LRCLIB](https://lrclib.net).
- Shows the current and next lyric line in the app and Live Activity.
- Tracks play, pause, seek, interruption, and song changes.
- Supports a display timing offset from -3.0 to +3.0 seconds.
- Keeps instrumental gaps blank instead of showing a lyric too early.
- Does not start, pause, skip, or otherwise control music playback.

## Requirements

- Xcode 26.5 or later
- iOS 26.5 or later
- An Apple Music track with accessible playback metadata
- Media & Apple Music permission
- An internet connection for LRCLIB requests

A physical iPhone is recommended for validating Apple Music playback and Live Activity behavior.

## Getting Started

1. Clone the repository:

   ```sh
   git clone https://github.com/Vickyciou/LyricsInTheCar.git
   cd LyricsInTheCar
   ```

2. Open `LyricsInTheCar.xcodeproj` in Xcode.
3. Select your development team and update the bundle identifiers if required for signing.
4. Build and run the `LyricsInTheCar` scheme on an iPhone.
5. Start a song in Apple Music.
6. In Lyrics in the Car, tap **Start following** and grant Media & Apple Music access.
7. Optionally adjust **Display timing**, then tap **Start Live Activity**.

## How Lyrics Are Matched

The app reads the current track's title, artist, album, duration, and playback position from `MPMusicPlayerController`. It requests synchronized lyrics from LRCLIB and accepts a response only when the recording metadata and rounded duration match.

This intentionally avoids guessing lyrics for a different recording, but it also means lyrics may be unavailable when metadata differs between Apple Music and LRCLIB.

## Project Structure

| Path | Purpose |
| --- | --- |
| `LyricsInTheCar/` | SwiftUI app, playback observation, lyric loading, and session state |
| `LyricsLiveActivityExtension/` | Lock Screen, Dynamic Island, and compact Live Activity layouts |
| `Shared/` | ActivityKit attributes shared by the app and extension |
| `LyricsInTheCarTests/` | Timeline, source, session, and Live Activity layout tests |
| `LyricsInTheCarUITests/` | App-level UI tests |

The session layer owns playback reconciliation and lyric selection. Infrastructure adapters provide Apple Music observations, LRCLIB requests, a monotonic clock, and ActivityKit publishing.

## Testing

Run the unit test target from Xcode, or use:

```sh
xcodebuild test \
  -project LyricsInTheCar.xcodeproj \
  -scheme LyricsInTheCar \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
```

The test suite covers lyric parsing and matching, timing boundaries, pauses, seeks, track changes, Live Activity state updates, and long-line rendering within the Lock Screen height budget.

## Current Limitations

- Synchronized lyrics depend on matching content being available from LRCLIB.
- Playback metadata and behavior can vary between Apple Music items.
- Foreground synchronization is implemented and covered by tests. Sustained background timing and CarPlay behavior still require broader real-device validation.
- The app displays lyrics only; it is not a playback controller.

## Privacy

The app requests Media & Apple Music access to read the current track and playback position. To retrieve lyrics, it sends the track title, artist, album, and rounded duration to LRCLIB. It does not upload audio, and this repository contains no analytics integration.

## Acknowledgements

Synchronized lyrics are provided by [LRCLIB](https://lrclib.net). Apple Music is a trademark of Apple Inc. Lyrics returned by external services remain subject to their applicable rights and terms.

## License

The source code is available under the [MIT License](LICENSE).
