import Foundation

/// Built-in help, written for a 10-year-old: short sentences, everyday words, one step at a time.
/// Kept in BacklineKit (plain data) so a unit test can check the reading level of every line.
public enum HelpTopic: String, CaseIterable, Identifiable, Sendable {
    case start, addSong, removeLead, practice, export, youtube, youtubeSignIn, record, miniPlayer,
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

    public static let pages: [HelpPage] = [
        HelpPage(topic: .start, title: "Start here", symbol: "hand.wave",
                 intro: "Backline helps you play along with your favorite songs. It splits a song into parts, like drums, bass and guitar. Then you can turn off your part and play it yourself.",
                 steps: [
                    HelpStep("music.note", "Add a song. You can drag a music file onto Backline, or paste a YouTube link."),
                    HelpStep("waveform", "Wait a little while Backline splits the song. This takes about a minute."),
                    HelpStep("guitars", "Pick the part you play under \"I'm playing\". Backline turns that part off."),
                    HelpStep("play.fill", "Press Play, or press the space bar. Now you are the band's guitar player!"),
                 ],
                 tip: "Everything stays on your Mac. Backline does not send your songs to anyone."),

        HelpPage(topic: .addSong, title: "Add a song", symbol: "plus.circle",
                 intro: "There are four ways to add a song. Pick the one that is easiest for you.",
                 steps: [
                    HelpStep("arrow.down.doc", "Drag a music file from Finder and drop it on Backline."),
                    HelpStep("folder", "Or click Choose file and pick a song. MP3, WAV, AIFF, M4A and FLAC files all work."),
                    HelpStep("link", "Or copy a YouTube link. Paste it in the box that says \"paste a YouTube link\", then press Return."),
                    HelpStep("record.circle", "Or play the song in another app, and use Record from an app. See the Record page to learn how."),
                 ],
                 tip: "Already playing a song? Click the plus button, or Add song at the bottom of the list. You get the same choices. Songs you added before are in the list on the left."),

        HelpPage(topic: .removeLead, title: "Take out the lead guitar", symbol: "guitars",
                 intro: "Backline can split the guitar into two parts. The lead guitar plays the solos and tunes. The rhythm guitar plays the chords and riffs.",
                 steps: [
                    HelpStep("guitars", "Look for \"I'm playing\" near the top. Click Lead."),
                    HelpStep("switch.2", "The Lead guitar switch turns off. The rhythm guitar keeps playing."),
                    HelpStep("play.fill", "Press Play. You play the solo, and the band plays the rest."),
                    HelpStep("ear", "Stuck? Turn on Guide. You will hear the real solo very softly, so you can follow it."),
                 ],
                 tip: "Want to practice rhythm instead? Click Rhythm. Each part has its own switch, so you can turn any part on or off."),

        HelpPage(topic: .practice, title: "Practice a hard part", symbol: "repeat",
                 intro: "Hard parts get easy when you play them slowly, over and over.",
                 steps: [
                    HelpStep("rectangle.split.3x1", "Click a part of the song in the top picture, like \"Section 3\". Backline plays that part over and over."),
                    HelpStep("a.circle", "Or press A where the hard part starts. Press A again where it ends."),
                    HelpStep("minus", "Click the minus button next to 100% to slow the song down. The notes stay in tune."),
                    HelpStep("gauge.with.dots.needle.33percent", "Try the speed trainer. It starts slow and gets a little faster each time the part repeats."),
                    HelpStep("checkmark.square", "Turn on the count-in. You will hear 1, 2, 3, 4 before the music starts."),
                    HelpStep("metronome.fill", "Turn on Click to hear a beat that follows the song."),
                 ],
                 tip: "Press A a third time to stop the loop."),

        HelpPage(topic: .export, title: "Save a backing track", symbol: "square.and.arrow.up",
                 intro: "You can save the song without your part. Then you can play along on your phone or in the car.",
                 steps: [
                    HelpStep("switch.2", "Turn off the parts you don't want to hear."),
                    HelpStep("square.and.arrow.up", "Click the Save button at the bottom right."),
                    HelpStep("textformat", "Type a name. Pick WAV, MP3 or AIFF. MP3 files are the smallest."),
                    HelpStep("checkmark", "Click Save. Backline puts it in the Music folder, in a folder called Backline."),
                 ],
                 tip: "If you made the song slower, or changed the pitch, the saved song will be the same."),

        HelpPage(topic: .youtube, title: "Use a YouTube link", symbol: "link",
                 intro: "Backline can get the sound from a YouTube video. It does not get the picture.",
                 steps: [
                    HelpStep("safari", "Open the video in your web browser."),
                    HelpStep("doc.on.doc", "Click the address bar at the top. Then copy the link. You can press Command and C."),
                    HelpStep("link", "Click the box in Backline that says \"paste a YouTube link\". Press Command and V."),
                    HelpStep("return", "Press Return. Backline gets the sound and splits the song."),
                 ],
                 tip: "Only use songs you are allowed to use. Getting songs from YouTube may break YouTube's rules."),

        HelpPage(topic: .youtubeSignIn, title: "YouTube asks you to sign in", symbol: "person.crop.circle.badge.checkmark",
                 intro: "Some videos only play for people who are signed in. Backline can sign in for you. You only have to do it once.",
                 steps: [
                    HelpStep("person.crop.circle", "Click Sign in to YouTube."),
                    HelpStep("key", "Google's sign-in page opens inside Backline. Type your Google email. Then type your password."),
                    HelpStep("key.slash", "Does Google ask for a passkey? Passkeys don't work here. Click Show other ways. Then pick Enter your password."),
                    HelpStep("checkmark.circle", "When you see \"You're signed in\", click Done."),
                 ],
                 tip: "Backline never sees your password. Don't know your password? Ask a grown-up, or use Record from an app. To sign out, open Backline, then Settings."),

        HelpPage(topic: .record, title: "Record from an app", symbol: "record.circle",
                 intro: "You can record a song while it plays in another app, like your web browser. Use this for Spotify, or when a YouTube link does not work.",
                 steps: [
                    HelpStep("play.rectangle", "Start the song in the other app. Backline can only see apps that are making sound."),
                    HelpStep("record.circle", "In Backline, click Record from an app."),
                    HelpStep("list.bullet", "Click the app in the list, like Safari or Chrome."),
                    HelpStep("record.circle.fill", "Click Record. Then go back to the song and play it from the start."),
                    HelpStep("lock.shield", "The first time, your Mac asks if Backline can record sound. Click Allow."),
                    HelpStep("stop.fill", "When the song ends, Backline stops by itself. You can also click Stop & Split."),
                 ],
                 tip: "Backline only records the app you picked. It never uses your microphone. If you clicked Don't Allow by mistake, click Open Privacy Settings. Then turn on Backline."),

        HelpPage(topic: .miniPlayer, title: "Use the small player", symbol: "rectangle.inset.bottomright.filled",
                 intro: "The small player floats on top of other apps. It is great when you read tabs or watch a lesson at the same time.",
                 steps: [
                    HelpStep("rectangle.inset.bottomright.filled", "Open the Window menu and pick Mini Player. Or press Shift, Command and M."),
                    HelpStep("hand.draw", "Drag the small player to any spot on the screen."),
                    HelpStep("arrow.up.left.and.arrow.down.right", "Click the big-window button to go back."),
                 ],
                 tip: nil),

        HelpPage(topic: .keys, title: "Keys and foot pedals", symbol: "keyboard",
                 intro: "Your hands are on the guitar, so these keys help.",
                 steps: [
                    HelpStep("space", "Space bar: play or stop."),
                    HelpStep("a.square", "A: mark the start of a loop, then the end, then stop the loop."),
                    HelpStep("l.square", "L: turn the loop on or off."),
                    HelpStep("k.square", "K: turn the count-in on or off."),
                    HelpStep("c.square", "C: turn the click on or off."),
                    HelpStep("g.square", "G: turn the guide on or off."),
                    HelpStep("r.square", "R: hear every part again."),
                    HelpStep("1.square", "Number keys: turn a part on or off. 1 is the top part."),
                 ],
                 tip: "Most page-turner foot pedals work too. The pedal that turns the page down plays and stops. The one that turns the page up marks a loop."),

        HelpPage(topic: .troubleshooting, title: "Something went wrong", symbol: "wrench.and.screwdriver",
                 intro: "Here are easy fixes for the most common problems.",
                 steps: [
                    HelpStep("wifi", "A YouTube link does not work? Check that your Wi-Fi is on. Then click Try again."),
                    HelpStep("person.crop.circle", "YouTube says to sign in? Click Sign in to YouTube and sign in once."),
                    HelpStep("record.circle", "Still no luck? Play the video in your browser and use Record from an app."),
                    HelpStep("speaker.slash", "No sound? Check the volume on your Mac. Then check that the parts are turned on."),
                    HelpStep("waveform.slash", "A recording is silent? Click Open Privacy Settings. Then turn on Backline."),
                    HelpStep("arrow.clockwise", "Something looks stuck? Quit Backline and open it again. Your songs are saved."),
                 ],
                 tip: nil),

        HelpPage(topic: .remove, title: "Remove Backline", symbol: "trash",
                 intro: "Backline does not change anything else on your Mac. It does not add other programs. It is easy to remove.",
                 steps: [
                    HelpStep("externaldrive", "First, click the button below. It shows the folder with your split songs."),
                    HelpStep("trash", "Drag that folder to the Trash. This frees up space."),
                    HelpStep("xmark.circle", "Quit Backline. Then open the Applications folder."),
                    HelpStep("trash", "Drag Backline to the Trash. That's it!"),
                 ],
                 tip: "Backing tracks you saved are in the Music folder, in a folder called Backline. They stay until you delete them."),
    ]
}
