# Cardio Police

You've been sitting in Stormwind for an hour. The Cardio Police would like a word.

Cardio Police reminds you to get up and work out: after every dungeon you finish, and after every hour you spend
outside dungeons. Each reminder is the next exercise in a rotation, so it's pushups, then situps, then jumping
jacks, then air squats, and back to pushups. Made for WoW Forever.

## Features

- **After every dungeon**: when you leave a dungeon or raid you were in for at least 5 minutes. A corpse run
  doesn't count as leaving. Releasing to a spirit healer after a wipe does.
- **Every hour outside dungeons**: the timer pauses while you're in a dungeon or AFK, and carries over between
  sessions.
- **Never mid-fight**: a reminder that comes up during combat waits until combat ends.
- **The rotation**: 15 pushups, 20 situps, 30 jumping jacks, 20 air squats. Change any rep count to suit you.
- **Done, Snooze or Skip**: Done logs the reps and moves to the next exercise. Snooze brings the same one back in
  5 minutes. Skip moves on without logging.
- **Partner sync**: work out with a friend. You share one rotation and the same rep counts, and when one of you
  gets a reminder, you both do. Each of you keeps your own totals.

## Partner sync

Both of you need Cardio Police. Then each of you names the other:

```
/cardio partner TheirName
```

If one of you is offline, the other catches up on the rotation the next time they log in. Use `Name-Realm` if a
plain name doesn't connect.

## Commands

`/workout` works as well as `/cardio`.

| Command | What it does |
| --- | --- |
| `/cardio` | Show the next workout now |
| `/cardio stats` | Your totals for each exercise |
| `/cardio status` | What's next, minutes until the timed reminder, and your partner |
| `/cardio reps <exercise> <n>` | Set the reps, e.g. `/cardio reps squats 25` (pushups, situps, jacks, squats) |
| `/cardio interval <minutes>` | Time outside dungeons between reminders (default 60) |
| `/cardio partner <name>` | Sync with a friend. Leave the name off to stop |
| `/cardio reset` | Clear your totals and restart the rotation |
