import Foundation

/// Built-in help, written for a 10-year-old: short sentences, everyday words, one step at a time.
/// Kept in BacklineKit (plain data) so a unit test can check the reading level of every line.
public enum HelpTopic: String, CaseIterable, Identifiable, Sendable {
    case start, addSong, removeLead, practice, dance, beats, export, youtube, youtubeSignIn, record, miniPlayer,
         keys, troubleshooting, remove

    public var id: String { rawValue }
}

public struct HelpStep: Sendable {
    public let symbol: String      // SF Symbol shown next to the step (matches the button in the app)
    public let text: String
    public init(_ symbol: String, _ text: String) { self.symbol = symbol; self.text = text }
}

public struct HelpPage: Sendable {
    public let topic: HelpTopic
    public let title: String
    public let symbol: String
    public let intro: String
    public let steps: [HelpStep]
    public let tip: String?
}

public enum HelpContent {
    public static func page(_ t: HelpTopic) -> HelpPage { pages.first { $0.topic == t }! }

    /// The pages this app shows: the Mac's own words (click, drag, keys, Finder) on a Mac, the touch words
    /// everywhere else. Both sets are compiled on every platform, so the kit tests check both.
    #if os(macOS)
    public static let pages: [HelpPage] = macPages
    #else
    public static let pages: [HelpPage] = touchPages
    #endif

    /// iPhone and iPad.
    public static let touchPages: [HelpPage] = [
        HelpPage(topic: .start, title: "Start here", symbol: "hand.wave",
                 intro: "Backline splits a song into parts, so you can turn off your part and play it yourself.",
                 steps: [
                    HelpStep("plus", "Add a song. Tap the plus button. Paste a song or video link, or pick a file."),
                    HelpStep("waveform", "Wait a little while Backline splits the song. Keep Backline open while it works."),
                    HelpStep("guitars", "Tap YOU at the top and pick the part you play. Backline turns that part off."),
                    HelpStep("play.fill", "Tap Play. Now you play with the band!"),
                 ],
                 tip: "Your songs stay on your phone. Backline does not send them to anyone."),

        HelpPage(topic: .dance, title: "Practice a dance", symbol: "figure.dance",
                 intro: "Tap Dance at the top to hear one part at a time and see the counts.",
                 steps: [
                    HelpStep("figure.dance", "Tap LISTEN at the top and pick a part, like Bass. It plays loud. The rest of the band plays soft."),
                    HelpStep("hand.tap", "Play the song. Tap “Tap on the 1” when you hear the 1."),
                    HelpStep("8.circle", "Now the counts 1 to 8 start. The one you are on lights up."),
                    HelpStep("repeat", "Tap Loop at the bottom to play one eight again and again. Hold it down for 16 or 32 counts."),
                    HelpStep("slider.horizontal.3", "Tap Tune to make it slower or faster. The music stays in tune."),
                 ],
                 tip: "Count-in says 5, 6, 7, 8 before the music starts, like a teacher. Bachata or salsa? Pick it next to the song name."),

        HelpPage(topic: .beats, title: "Rap or sing over a beat", symbol: "music.mic",
                 intro: "Tap Beats at the top, and Backline turns the singer off so the beat is yours.",
                 steps: [
                    HelpStep("repeat", "Tap Loop at the bottom to play 4 bars again and again. It starts right on the beat."),
                    HelpStep("list.bullet", "Hold Loop down to pick 1, 2, 4 or 8 bars."),
                    HelpStep("hand.draw", "Or touch the wave and hold. Then drag to make a loop. It snaps to the bars."),
                    HelpStep("hand.tap", "Tap “Tap on the 1” when you hear the first beat of a bar. Then the beats count 1 to 4."),
                    HelpStep("slider.horizontal.3", "Tap Tune to slow the beat down. It stays in tune."),
                    HelpStep("chevron.right.circle", "Tap the arrow next to Music to see its parts, like guitar and keys."),
                    HelpStep("ear", "Want to hear the singer softly? Tap YOU at the top. Then turn on Guide."),
                 ],
                 tip: "Tap Loop again to stop the loop. To save the beat, tap the three dots at the top. Then tap Save track."),

        HelpPage(topic: .addSong, title: "Add a song", symbol: "plus.circle",
                 intro: "Tap the plus button, then pick the way that is easiest for you.",
                 steps: [
                    HelpStep("link", "Copy a song or video link. Then tap Paste in the link box."),
                    HelpStep("folder", "Or tap Files and pick a song. MP3, WAV, AIFF, M4A and FLAC files all work."),
                    HelpStep("music.note.list", "Or tap Music to pick a song that is saved on your phone."),
                    HelpStep("photo.on.rectangle", "Or tap Video to use the sound of a video from Photos."),
                    HelpStep("mic", "Or tap Record to record a band, a speaker, or a song in another app."),
                 ],
                 tip: "You can also share a song or a link to Backline from another app. Songs you added before are in your library."),

        HelpPage(topic: .removeLead, title: "Take out the lead guitar", symbol: "guitars",
                 intro: "The lead guitar plays the solos, and the rhythm guitar plays the chords and riffs.",
                 steps: [
                    HelpStep("guitars", "Tap YOU at the top. Then tap Lead guitar (or Guitar)."),
                    HelpStep("switch.2", "The Lead guitar switch turns off. The rhythm guitar keeps playing."),
                    HelpStep("play.fill", "Tap Play. You play the solo, and the band plays the rest."),
                    HelpStep("ear", "Stuck? Tap YOU and turn on Guide. You will hear the real solo very softly, so you can follow it."),
                 ],
                 tip: "Want to practice rhythm instead? Pick Rhythm guitar. Each part has its own switch, so you can turn any part on or off."),

        HelpPage(topic: .practice, title: "Practice a hard part", symbol: "repeat",
                 intro: "Hard parts get easy when you play them slowly, over and over.",
                 steps: [
                    HelpStep("repeat", "Tap Loop at the bottom. Backline plays the part you are in, over and over."),
                    HelpStep("rectangle.split.3x1", "Tap a name on the tape, like Chorus, to jump there. The loop moves there too."),
                    HelpStep("hand.draw", "Or touch the wave and hold. Then drag to draw your own loop."),
                    HelpStep("arrow.up.left.and.arrow.down.right", "Pinch the wave to zoom in. Then the loop is easy to draw."),
                    HelpStep("a.circle", "Or hold Loop down. Tap Set A where the hard part starts. Then Set B where it ends."),
                    HelpStep("slider.horizontal.3", "Tap Tune to slow the song down. The notes stay in tune."),
                    HelpStep("gauge.with.dots.needle.33percent", "Turn on Trainer in Tune. It starts slow and gets a little faster each time the part repeats."),
                    HelpStep("metronome", "Turn on Count-in in Tune. You will hear 1, 2, 3, 4 before the music starts."),
                 ],
                 tip: "Tap Loop again to stop the loop. Tap the wave to jump to any place in the song."),

        HelpPage(topic: .export, title: "Save a backing track", symbol: "square.and.arrow.up",
                 intro: "You can save the song without your part, to play along in the car or in another app.",
                 steps: [
                    HelpStep("switch.2", "Turn off the parts you don't want to hear."),
                    HelpStep("ellipsis", "Tap the three dots at the top. Then tap Save track."),
                    HelpStep("textformat", "Type a name. Pick WAV, MP3 or AIFF. MP3 files are the smallest."),
                    HelpStep("checkmark", "Tap Save. Then pick Save to Files, AirDrop, GarageBand or any other app."),
                 ],
                 tip: "If you made the song slower, or changed the pitch, the saved song will be the same."),

        HelpPage(topic: .youtube, title: "Add a song from a link", symbol: "link",
                 intro: "Backline can get the sound from a song or video link, but not the picture.",
                 steps: [
                    HelpStep("play.rectangle", "Open the song or video in its app or in Safari."),
                    HelpStep("square.and.arrow.up", "Tap Share. Then pick Backline. That is the easy way."),
                    HelpStep("doc.on.doc", "Or tap Copy link. In Backline, tap the plus button. Then tap Paste."),
                    HelpStep("music.note", "A link to a song on a music service works too. Backline looks for the same song."),
                    HelpStep("list.bullet", "Did you share a list of songs? Tap the one you want."),
                    HelpStep("waveform", "Backline gets the sound and splits the song."),
                 ],
                 tip: "Only use songs you are allowed to use. Some sites do not let you save their songs."),

        HelpPage(topic: .youtubeSignIn, title: "A link asks you to sign in", symbol: "person.crop.circle.badge.checkmark",
                 intro: "Some songs and videos only play for people who are signed in to Google.",
                 steps: [
                    HelpStep("person.crop.circle", "Tap Sign in. You only have to do it once."),
                    HelpStep("key", "Google's sign-in page opens inside Backline. Type your Google email. Then type your password."),
                    HelpStep("key.slash", "Does Google ask for a passkey? Tap Use password at the bottom."),
                    HelpStep("checkmark.circle", "When you are signed in, the page closes by itself."),
                 ],
                 tip: "Backline never sees your password. Don't know it? Record the song instead. To sign out, open Settings."),

        HelpPage(topic: .record, title: "Record a song", symbol: "record.circle",
                 intro: "You can record a song while it plays in another app, or record the sound in the room.",
                 steps: [
                    HelpStep("plus", "Tap the plus button. Then tap Record. Then tap Another app."),
                    HelpStep("record.circle", "Tap Start. Then tap Start Broadcast in the box that opens."),
                    HelpStep("play.rectangle", "Go to your music app. Play the song from the start."),
                    HelpStep("stop.fill", "When the song ends, tap the red pill at the top of the screen. Then tap Stop."),
                    HelpStep("mic", "To use the mic instead, tap Mic. Hold your phone near the sound."),
                 ],
                 tip: "Backline only records while the red pill is on. Recordings stay on your phone. They are deleted after the song is split."),

        HelpPage(topic: .miniPlayer, title: "Play from the lock screen", symbol: "lock.iphone",
                 intro: "Backline keeps playing when you lock your phone or open another app.",
                 steps: [
                    HelpStep("chevron.down", "Tap the arrow at the top left to shrink the player into a small bar."),
                    HelpStep("play.fill", "Tap Play or Pause on the small bar. Tap the bar to open the big player."),
                    HelpStep("lock.iphone", "Lock your phone. Play, pause and the song bar are on the lock screen."),
                    HelpStep("airpods", "Double-press your AirPods to go forward one bar. Triple-press to go back one bar."),
                 ],
                 tip: nil),

        HelpPage(topic: .keys, title: "Keys and foot pedals", symbol: "keyboard",
                 intro: "With a keyboard or a foot pedal, your hands can stay on the guitar.",
                 steps: [
                    HelpStep("space", "Space bar: play or stop."),
                    HelpStep("a.square", "A: mark the start of a loop, then the end, then stop the loop."),
                    HelpStep("l.square", "L: turn the loop on or off."),
                    HelpStep("k.square", "K: turn the count-in on or off."),
                    HelpStep("c.square", "C: turn the click on or off."),
                    HelpStep("o.square", "O: set the 1 in Dance or Beats."),
                    HelpStep("g.square", "G: turn the guide on or off."),
                    HelpStep("r.square", "R: hear every part again."),
                    HelpStep("1.square", "Number keys: turn a part on or off. 1 is the top part."),
                 ],
                 tip: "Most Bluetooth page-turner foot pedals work too. The pedal that turns the page down plays and stops. The one that turns the page up marks a loop."),

        HelpPage(topic: .troubleshooting, title: "Something went wrong", symbol: "wrench.and.screwdriver",
                 intro: "Here are easy fixes for the most common problems.",
                 steps: [
                    HelpStep("wifi", "A link does not work? Check that your Wi-Fi is on. Then tap Try again."),
                    HelpStep("person.crop.circle", "Still no luck? Tap Sign in and sign in to Google once."),
                    HelpStep("record.circle", "Or play the song in another app, and record it with Backline."),
                    HelpStep("speaker.slash", "No sound? Check the volume on your phone and the silent switch. Then check that the parts are turned on."),
                    HelpStep("pause.circle", "Splitting stops when you leave Backline. Come back to the app and it goes on."),
                    HelpStep("arrow.clockwise", "Something looks stuck? Close Backline and open it again. Your songs are saved."),
                 ],
                 tip: nil),

        HelpPage(topic: .remove, title: "Free up space", symbol: "trash",
                 intro: "Each song takes up room on your phone, so you can delete songs you don't need.",
                 steps: [
                    HelpStep("list.bullet", "Open your library. Swipe a song to the left."),
                    HelpStep("trash", "Tap Delete. Backline deletes the parts. Your original file stays safe."),
                    HelpStep("gearshape", "Open Settings to see how much space your songs use."),
                    HelpStep("xmark.circle", "To remove Backline, press and hold its icon. Then tap Remove App."),
                 ],
                 tip: "Backing tracks you saved are in the place you chose, like Files. They stay until you delete them."),
    ]

    /// The Mac: the same pages and order, with the Mac's own buttons, menus and keys.
    public static let macPages: [HelpPage] = [
        HelpPage(topic: .start, title: "Start here", symbol: "hand.wave",
                 intro: "Backline splits a song into parts, so you can turn off your part and play it yourself.",
                 steps: [
                    HelpStep("music.note", "Add a song. Drag a music file onto Backline, or paste a song or video link."),
                    HelpStep("waveform", "Wait a little while Backline splits the song. Keep Backline open while it works."),
                    HelpStep("guitars", "Click YOU at the top and pick the part you play. Backline turns that part off."),
                    HelpStep("play.fill", "Press Play, or press the space bar. Now you play with the band!"),
                 ],
                 tip: "Your songs stay on your Mac. Backline does not send them to anyone."),

        HelpPage(topic: .dance, title: "Practice a dance", symbol: "figure.dance",
                 intro: "Click Dance at the top to hear one part at a time and see the counts.",
                 steps: [
                    HelpStep("figure.dance", "Click LISTEN at the top and pick a part, like Bass. It plays loud. The rest of the band plays soft."),
                    HelpStep("hand.tap", "Play the song. Click “Tap on the 1” when you hear the 1. You can also press O."),
                    HelpStep("8.circle", "Now the counts 1 to 8 start. The one you are on lights up."),
                    HelpStep("repeat", "Click Loop at the bottom to play one eight again and again. Hold it down for 16 or 32 counts."),
                    HelpStep("tortoise", "Use Speed at the bottom to make it slower or faster. The music stays in tune."),
                 ],
                 tip: "Count-in says 5, 6, 7, 8 before the music starts, like a teacher. Bachata or salsa? Pick it next to the song name."),

        HelpPage(topic: .beats, title: "Rap or sing over a beat", symbol: "music.mic",
                 intro: "Click Beats at the top, and Backline turns the singer off so the beat is yours.",
                 steps: [
                    HelpStep("repeat", "Click 1, 2, 4 or 8 bars next to Loop. The loop starts right on the beat."),
                    HelpStep("hand.draw", "Or hold Option and drag on the wave to make a loop. It snaps to the bars."),
                    HelpStep("hand.tap", "Click “Tap on the 1” when you hear the first beat of a bar. Then the beats count 1 to 4."),
                    HelpStep("tortoise", "Use Speed at the bottom to slow the beat down. It stays in tune."),
                    HelpStep("chevron.right.circle", "Click the arrow next to Music to see its parts, like guitar and keys."),
                    HelpStep("ear", "Want to hear the singer softly? Click YOU at the top. Then turn on Guide."),
                 ],
                 tip: "Click the same bars again to stop the loop. To save the beat, click Save track at the bottom right."),

        HelpPage(topic: .addSong, title: "Add a song", symbol: "plus.circle",
                 intro: "Click Add a song at the top, then pick the way that is easiest for you.",
                 steps: [
                    HelpStep("arrow.down.doc", "Drag a music or video file from Finder and drop it on Backline."),
                    HelpStep("folder", "Or click Choose file and pick a song. MP3, WAV, AIFF, M4A and FLAC files all work."),
                    HelpStep("link", "Or copy a song or video link. Click the link box and press Command and V. Then press Return."),
                    HelpStep("record.circle", "Or click Record a song. You can record a song while it plays in another app."),
                    HelpStep("mic", "Or record a band or a speaker with a microphone or an audio interface."),
                 ],
                 tip: "You can also press Command and O. Songs you added before are in the Library on the left."),

        HelpPage(topic: .removeLead, title: "Take out the lead guitar", symbol: "guitars",
                 intro: "The lead guitar plays the solos, and the rhythm guitar plays the chords and riffs.",
                 steps: [
                    HelpStep("guitars", "Click YOU at the top. Then click Lead guitar (or Guitar)."),
                    HelpStep("switch.2", "The Lead guitar switch turns off. The rhythm guitar keeps playing."),
                    HelpStep("play.fill", "Press Play. You play the solo, and the band plays the rest."),
                    HelpStep("ear", "Stuck? Click YOU and turn on Guide. You will hear the real solo very softly, so you can follow it."),
                 ],
                 tip: "Want to practice rhythm instead? Pick Rhythm guitar. Each part has its own switch, so you can turn any part on or off."),

        HelpPage(topic: .practice, title: "Practice a hard part", symbol: "repeat",
                 intro: "Hard parts get easy when you play them slowly, over and over.",
                 steps: [
                    HelpStep("repeat", "Click Loop at the bottom. Backline plays the part you are in, over and over."),
                    HelpStep("rectangle.split.3x1", "Click a name above the wave, like Chorus. Backline loops that part."),
                    HelpStep("hand.draw", "Or hold Option and drag on the wave to draw your own loop."),
                    HelpStep("a.circle", "Or press A where the hard part starts. Press A again where it ends."),
                    HelpStep("tortoise", "Use Speed at the bottom to slow the song down. The notes stay in tune."),
                    HelpStep("gauge.with.dots.needle.33percent", "Try the speed trainer next to Speed. It starts slow and gets a little faster each time the part repeats."),
                    HelpStep("metronome", "Turn on Count-in. You will hear 1, 2, 3, 4 before the music starts."),
                    HelpStep("metronome.fill", "Turn on Click to hear a beat that follows the song."),
                 ],
                 tip: "Press L to stop the loop. Click the wave to jump to any place in the song."),

        HelpPage(topic: .export, title: "Save a backing track", symbol: "square.and.arrow.up",
                 intro: "You can save the song without your part, to play along in the car or in another app.",
                 steps: [
                    HelpStep("switch.2", "Turn off the parts you don't want to hear."),
                    HelpStep("square.and.arrow.up", "Click Save at the bottom right, or press Command and E."),
                    HelpStep("textformat", "Type a name. Pick WAV, MP3 or AIFF. MP3 files are the smallest."),
                    HelpStep("checkmark", "Click Save. Then pick a folder. Backline starts in a folder called Backline, in your Music folder."),
                 ],
                 tip: "If you made the song slower, or changed the pitch, the saved song will be the same."),

        HelpPage(topic: .youtube, title: "Add a song from a link", symbol: "link",
                 intro: "Backline can get the sound from a song or video link, but not the picture.",
                 steps: [
                    HelpStep("safari", "Open the song or video in your web browser or in its app."),
                    HelpStep("doc.on.doc", "Copy its link. In a browser, click the address bar. Then press Command and C."),
                    HelpStep("link", "In Backline, click Add a song. Click the link box and press Command and V. Then press Return."),
                    HelpStep("arrow.down.doc", "Or drag the link onto Backline. That works too."),
                    HelpStep("music.note", "A link to a song on a music service works too. Backline looks for the same song."),
                    HelpStep("list.bullet", "Did you paste a list of songs? Click the one you want."),
                    HelpStep("waveform", "Backline gets the sound and splits the song."),
                 ],
                 tip: "Only use songs you are allowed to use. Some sites do not let you save their songs."),

        HelpPage(topic: .youtubeSignIn, title: "A link asks you to sign in", symbol: "person.crop.circle.badge.checkmark",
                 intro: "Some songs and videos only play for people who are signed in to Google.",
                 steps: [
                    HelpStep("person.crop.circle", "Click Sign in. You only have to do it once."),
                    HelpStep("key", "Google's sign-in page opens inside Backline. Type your Google email. Then type your password."),
                    HelpStep("key.slash", "Does Google ask for a passkey? Passkeys don't work here. Click the button below the page. Then pick Enter your password."),
                    HelpStep("checkmark.circle", "When you see “You're signed in”, click Done."),
                 ],
                 tip: "Backline never sees your password. Don't know it? Record the song instead. To sign out, open the Backline menu, then Settings."),

        HelpPage(topic: .record, title: "Record a song", symbol: "record.circle",
                 intro: "You can record a song while it plays in another app, or record the sound in the room.",
                 steps: [
                    HelpStep("record.circle", "Click Add a song. Then click Record a song. Or press Shift, Command and R."),
                    HelpStep("play.rectangle", "Start the song in the other app. Backline only sees apps that are making sound."),
                    HelpStep("list.bullet", "Click the app in the list, like Safari. Then click Record."),
                    HelpStep("play.fill", "Go back to the song and play it from the start."),
                    HelpStep("stop.fill", "When the song ends, Backline stops by itself. You can also click Stop & Split."),
                    HelpStep("mic", "To record the room, click Microphone. Pick your microphone or audio interface in the list."),
                 ],
                 tip: "The first time, your Mac asks if Backline may record. Click Allow. Recordings stay on your Mac. They are deleted after the song is split."),

        HelpPage(topic: .miniPlayer, title: "Use the small player", symbol: "rectangle.inset.bottomright.filled",
                 intro: "The small player floats on top of other apps, so you can read tabs or watch a lesson at the same time.",
                 steps: [
                    HelpStep("rectangle.inset.bottomright.filled", "Open the Window menu and pick Mini Player. Or press Shift, Command and M."),
                    HelpStep("play.fill", "Click Play or Pause on the small player. Backline keeps playing when you use other apps."),
                    HelpStep("hand.draw", "Drag the small player to any spot on the screen."),
                    HelpStep("arrow.up.left.and.arrow.down.right", "Click the big-window button to go back."),
                 ],
                 tip: nil),

        HelpPage(topic: .keys, title: "Keys and foot pedals", symbol: "keyboard",
                 intro: "With a keyboard or a foot pedal, your hands can stay on the guitar.",
                 steps: [
                    HelpStep("space", "Space bar: play or stop."),
                    HelpStep("a.square", "A: mark the start of a loop, then the end, then stop the loop."),
                    HelpStep("l.square", "L: turn the loop on or off."),
                    HelpStep("k.square", "K: turn the count-in on or off."),
                    HelpStep("c.square", "C: turn the click on or off."),
                    HelpStep("o.square", "O: set the 1 in Dance or Beats."),
                    HelpStep("g.square", "G: turn the guide on or off."),
                    HelpStep("r.square", "R: hear every part again."),
                    HelpStep("1.square", "Number keys: turn a part on or off. 1 is the top part."),
                    HelpStep("arrow.left.and.right.square", "Left and right arrows: go back or forward one bar."),
                 ],
                 tip: "Most Bluetooth page-turner foot pedals work too. The pedal that turns the page down plays and stops. The one that turns the page up marks a loop."),

        HelpPage(topic: .troubleshooting, title: "Something went wrong", symbol: "wrench.and.screwdriver",
                 intro: "Here are easy fixes for the most common problems.",
                 steps: [
                    HelpStep("wifi", "A link does not work? Check that your Wi-Fi is on. Then click Try again."),
                    HelpStep("person.crop.circle", "Still no luck? Click Sign in and sign in to Google once."),
                    HelpStep("record.circle", "Or play the song in another app, and record it with Backline."),
                    HelpStep("speaker.slash", "No sound? Check the volume on your Mac. Then check that the parts are turned on."),
                    HelpStep("waveform.slash", "A recording is silent? Click Open Privacy Settings. Then turn on Backline."),
                    HelpStep("arrow.clockwise", "Something looks stuck? Quit Backline and open it again. Your songs are saved."),
                 ],
                 tip: nil),

        HelpPage(topic: .remove, title: "Free up space", symbol: "trash",
                 intro: "Each song takes up room on your Mac, so you can delete songs you don't need.",
                 steps: [
                    HelpStep("list.bullet", "In the Library, right-click a song. Then click Remove from Library."),
                    HelpStep("trash", "Click Remove. Backline deletes the parts. Your own song file stays safe."),
                    HelpStep("externaldrive", "Want to see all your split songs? Click the button below."),
                    HelpStep("xmark.circle", "To remove Backline, quit it. Then drag Backline from Applications to the Trash."),
                 ],
                 tip: "Backing tracks you saved are in the folder you picked, like Music. They stay until you delete them."),
    ]
}
