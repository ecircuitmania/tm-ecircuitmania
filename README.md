# tm-ecircuitmania

A plugin for collecting match data for ECM.

## How round data is collected

Each round is read from two places:

1. **MLFeed** gives every player's checkpoint and finish times.
   - **Other players:** what the server sent your game, so already checked by the server.
   - **You:** your own game's view of your car. The server corrects your times afterwards, but if it didn't count your finish (say you lagged past the finish timeout), your finish still shows.
2. **Your score record**, written by the server, is only used to check that one thing: whether the server counted your finish. If it didn't, you're sent as a DNF. If there's no answer (you finished first, or the mode has no round points, like Knockout), your own view is sent.

License: Public Domain

Authors: XertroV & eCircuitmania team.

Suggestions/feedback: @XertroV on Openplanet discord

Code/issues: [https://github.com/XertroV/tm-play-map](https://github.com/XertroV/tm-play-map)

GL HF
