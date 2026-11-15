# App Store listing

Text to paste into App Store Connect, and the steps that only the account holder can do.
Screenshots are in `screenshots/`.

## Listing text

| Field | Text |
|---|---|
| Name | Scrollkeeper |
| Subtitle | Read books on your wrist |
| Category | Books |
| Age rating | 4+ |
| Support URL | https://github.com/lyh1068/Scrollkeeper |
| Privacy Policy URL | https://github.com/lyh1068/Scrollkeeper/blob/main/PRIVACY.md |
| Copyright | 2026 (your name) |

**Promotional text**

Send EPUB, PDF, text and Markdown books from your iPhone and read them on your Apple Watch with the Digital Crown. No accounts, no cloud, no tracking.

**Description**

Scrollkeeper is a simple book reader for Apple Watch. It is made for reading text on a small screen, not for viewing documents.

Pick books on your iPhone. Scrollkeeper turns them into clean, compact text and sends them to your watch, where they are stored so you can read without your phone.

ON YOUR WATCH
• Turn the Digital Crown to scroll one line at a time, with a light tap every five lines.
• Auto-scroll at the speed you choose. Turn the crown to go faster or slower. It pauses when you lower your wrist.
• Full-screen text: the clock and controls hide while you read.
• Adjustable text size.
• Chapter list and bookmarks. Books without chapters get places to jump to instead.
• Remembers your place in every book, and shows how far you've read.
• Hundreds of books fit, stored on the watch.

ON YOUR IPHONE
• Imports EPUB, PDF, plain text (.txt) and Markdown (.md).
• Share a file to Scrollkeeper from Files, Safari, Mail and other apps.
• Lists the books on your watch with how far you've read, and lets you delete them from the phone.
• Cleans up text for a small screen: re-flows hard-wrapped lines, removes page headers and page numbers from PDFs, and finds chapters.
• Reads scanned PDF pages with on-device text recognition, in English and Chinese.
• Detects older Chinese text encodings such as GBK.

PRIVATE
• No accounts, no ads, no analytics. Your books never leave your devices.

NOTES
• Copy-protected (DRM) books bought from a store can't be opened.
• Pictures and tables are left out; Scrollkeeper keeps the text and chapter headings.
• Requires an Apple Watch paired with your iPhone.

**Keywords** (91 of 100 characters)

ebook,reader,epub,pdf,txt,markdown,novel,crown,wrist,offline,autoscroll,bookmark,小说,阅读器,电子书

**App Privacy answers**

Data collection: "Data Not Collected".

**Notes for App Review**

Scrollkeeper's iPhone app converts book files and transfers them to the Apple Watch app, where reading happens. No account or sign-in is needed.

To test without transferring a file: open Scrollkeeper on Apple Watch. A short built-in book, "Scrollkeeper Guide", is already in the list. Open it, turn the Digital Crown to scroll, and tap the text for the controls.

To test a transfer: on iPhone, tap "Send Books to Watch" and pick any .txt, .epub or .pdf file from Files. The book appears in the list on the watch, and under "On your watch" on the iPhone, where it can be swiped away to delete it from the watch.

## Screenshots

| File | Shows | Size |
|---|---|---|
| `iphone-1-books.png` | The watch's books and reading progress | 1320 × 2868 (6.9-inch iPhone) |
| `iphone-2-how-it-works.png` | First-run screen | 1320 × 2868 |
| `watch-1-library.png` | Book list | 416 × 496 (46 mm Apple Watch) |
| `watch-2-reading.png` | Full-screen reading | 416 × 496 |
| `watch-3-controls.png` | Text size and auto-scroll controls | 416 × 496 |
| `watch-4-chapters.png` | Chapters and bookmarks | 416 × 496 |

The sample book is *Pride and Prejudice*, which is in the public domain.

## Steps only the account holder can do

1. **Join the Apple Developer Program** (paid, yearly) if the team in Xcode is still a free personal team. Only paid members can upload to App Store Connect.
2. **Create the app in App Store Connect** with bundle ID `com.iterlum.Scrollkeeper`. This is also where you learn whether the name "Scrollkeeper" is free.
3. **Test on real devices first.** The simulator cannot deliver files from iPhone to watch, so check on your own iPhone and watch:
   - send one book of each kind: .txt, .md, .epub, a text PDF and a scanned PDF;
   - share a PDF to Scrollkeeper from Files or Books;
   - turn the crown, start auto-scroll, add a bookmark, jump to a chapter;
   - close and reopen the watch app and check it returns to your place;
   - check the iPhone lists the watch's books, then delete one from the iPhone, once with the watch app open and once with it closed.
4. **Upload:** in Xcode choose Any iOS Device, then Product → Archive → Distribute App → App Store Connect. The watch app is included in the same upload.
5. **Try it through TestFlight** before submitting for review.
6. **Fill in the listing** with the text above, upload the screenshots, answer App Privacy and the age rating, set the price and countries.
7. **China mainland:** selling there needs an ICP filing number entered in App Store Connect. Without one, leave China mainland unticked under availability.

## Known review risk

The watch app hides the clock while reading with `_statusBarHidden`, a SwiftUI call whose name starts with an underscore, which marks it as not officially supported. Other watch apps ship with it, but if Apple objects, remove that one line in `Watch/ReaderView.swift`; the only effect is that the clock stays visible while reading.
