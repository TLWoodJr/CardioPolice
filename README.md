# Cardio Police

You've been sitting in Stormwind for an hour. The Cardio Police would like a word.

Cardio Police reminds you to get up and work out: after every dungeon you finish, and after every hour you spend
outside dungeons. Each reminder is the next exercise in your rotation. Out of the box that's pushups, then situps,
then jumping jacks, then air squats, and back to pushups. Made for WoW Forever.

## Features

- **After every dungeon**: when you leave a dungeon or raid you were in for at least 5 minutes. A corpse run
  doesn't count as leaving. Releasing to a spirit healer after a wipe does.
- **Every hour outside dungeons**: the timer pauses while you're in a dungeon or AFK, and carries over between
  sessions.
- **Never mid-fight**: a reminder that comes up during combat waits until combat ends.
- **Sirens and lights**: each reminder plays a police siren and glows red and blue down the sides of your screen,
  swapping sides. You can switch to the raid warning sound or turn either off.
- **Your rotation**: add, remove, rename and reorder exercises (up to 8) and set the reps for each.
- **Your timing**: change how often the timed reminder comes, how long a dungeon has to last to count, and how
  long Snooze waits. Either kind of reminder can be turned off.
- **Done, Snooze or Skip**: Done logs the reps and moves to the next exercise. Snooze brings the same one back
  later. Skip moves on without logging.
- **Minimap button**: hover for what's next and when, left-click for settings, right-click to work out now.
  Drag it around the minimap, or hide it.
- **Partner sync**: work out with a friend. You share one rotation and the same rep counts, and when one of you
  gets a reminder, you both do. Each of you keeps your own totals.

## Settings

Open the settings window with `/cardio config`, by left-clicking the minimap button, or from the AddOns tab of the
game's options. Click an exercise's number to make it the next one up.

## Partner sync

Both of you need Cardio Police. Then each of you names the other:

```
/cardio partner TheirName
```

If one of you is offline, the other catches up on the rotation the next time they log in. Use `Name-Realm` if a
plain name doesn't connect. Both of you need the same version of Cardio Police for the rotation to sync.

## Commands

`/workout` works as well as `/cardio`.

| Command | What it does |
| --- | --- |
| `/cardio` | Show the next workout now |
| `/cardio config` | Open the settings window |
| `/cardio rotation` | List the rotation and what's next |
| `/cardio reps <exercise> <n>` | Set the reps, e.g. `/cardio reps squats 25` |
| `/cardio add <exercise> <n>` | Add an exercise, e.g. `/cardio add Burpees 10` |
| `/cardio remove <exercise>` | Take an exercise out of the rotation |
| `/cardio interval <minutes>` | Time outside dungeons between reminders (default 60, `0` turns it off) |
| `/cardio dungeon <minutes>` | Shortest dungeon run that counts (default 5, `off` turns dungeon reminders off) |
| `/cardio snooze <minutes>` | How long Snooze waits (default 5) |
| `/cardio sound <siren\|warning\|none>` | Alert sound |
| `/cardio flash` | Turn the red and blue screen flash on or off |
| `/cardio minimap` | Show or hide the minimap button |
| `/cardio test` | Play the alert |
| `/cardio stats` | Your totals for each exercise |
| `/cardio status` | What's next, minutes until the timed reminder, and your partner |
| `/cardio partner <name>` | Sync with a friend. Leave the name off to stop |
| `/cardio reset` | Clear your totals and restart the rotation |
