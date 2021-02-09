# PlayerStatus
- Displays icons, sounds, and notifications when a player:
    - fully loads into the game
        - Players often load for a while after the `- player has joined the game.` message. Players can't see chat messages until fully loaded.
    - is AFK for a minute or longer (hasn't pressed any buttons)
    - loses connection to the server
    - recovers from a lag spike that lasts several seconds

All messages are shown in the notification area (where you see the `Player fell or something` messages) except for the fully loaded message, which is shown in the chat area.

Icons and sounds work like the "Take Cover!" and "Medic!" commands.

## Commands
`afk?` - Chat command. Shows AFK player count + server percentage.  
`.listafk` - Console command. shows total AFK time for all players in the current map, sorted by most AFK time.
