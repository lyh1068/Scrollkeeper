/// A short book put on the watch the first time the app runs, so there is something to
/// read, and to try the crown on, before any book has been sent. It can be deleted.
enum Guide {
    static let name = "Scrollkeeper Guide.md"
    static let text = """
    # Welcome
    Scrollkeeper is a book reader for your wrist. This short guide is a book like any other. When you're done with it, swipe left on it in the list of books to delete it.

    # Reading
    Turn the Digital Crown to move through the text, one line per step. You'll feel a light tap every five lines.
    You can also drag the text with your finger.
    The clock hides while you read. Tap the text to bring it back, along with the controls.

    # Controls
    Tap the text to show the controls. Tap it again to hide them.
    - **A−** and **A+** change the text size.
    - The number between them is how far through the book you are.
    - **▶** starts auto-scroll. **−** and **+** set its speed in lines per minute.

    # Auto-scroll
    While the text scrolls by itself, turn the Digital Crown to go faster or slower. Tap the text to stop.
    It pauses when you lower your wrist.

    # Chapters and bookmarks
    With the controls showing, tap the list button at the top to see the book's chapters and your bookmarks. Tap one to jump there, or tap **Bookmark Here** to save your place.
    A book without chapters gets a list of places to jump to instead, from 0% to 90%.
    Scrollkeeper also remembers where you stopped in every book, and shows how far you've read in the list of books.

    # Staying in your book
    Your watch goes back to the clock a couple of minutes after you lower your wrist. To come back to your book for up to an hour instead, open Settings on the watch and go to General, then Return to Clock. Tap Scrollkeeper, then Custom, then After 1 hour.

    # Adding books
    Open Scrollkeeper on your iPhone and tap **Send Books to Watch**. It takes EPUB, PDF, plain text and Markdown files. You can also share a file to Scrollkeeper from Files, Safari, Mail and other apps.
    Books are stored on your watch, so you can read without your iPhone nearby.
    The iPhone app also lists the books on your watch. Swipe one to the left there to delete it.
    """
}
