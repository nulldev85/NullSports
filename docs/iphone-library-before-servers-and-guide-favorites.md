# iPhone: Library before a server, Guide favorites, one sign-in look

Five iPhone fixes from tester feedback. Apple TV gains the shared Silo sign-in
and nothing else.

## Library rows before any media server

The built-in rows (Trending and the streaming-service rows) come from public
MDBList lists, so they never needed a server. They used to be filtered down to
titles a connected server or provider could play, and with nothing connected
they were empty until the first server finished loading.

Now, until a server's own rows have been built, the iPhone shows the lists as
they are. Each title becomes a details-only card (`catalog|movie|<tmdb>` or
`catalog|series|<tmdb>`) with TMDB artwork and details. Its page shows a
greyed-out Play button and either "Find in My Sources" (when something is
connected) or "Set up a media server to play this" with an Add Media Server
button. Card menus and Collections are hidden for these cards. A prompt under
the hero offers Add Media Server while nothing is connected.

The lists are fetched at most every six hours and kept in Caches
(`Lineup-library-charts.json`), so they show at once on the next launch. Once a
server's playable rows exist, they replace the chart rows as before. Apple TV is
unchanged.

## TV Guide: favorites keep their place

Adding, removing or moving a favorite no longer scrolls the channel list back
to the top. The first favorite also no longer flips the list to the Favorites
filter while you are browsing another one. Only Recents still jumps to the top
when a new play reorders it.

## TV Guide: every reorder move is saved

The reorder sheet read the Guide's cached list, which was one move behind, so a
move was applied to the old order and could be lost. The sheet now keeps its
own copy of the order, applies each move to it and saves it straight away, with
no Done to press. The sheet closes with a plain close button.

## TV Guide: no Seerr entry

Seerr is removed from the TV Guide menu. It stays in the Library menu.

## Silo sign-in matches Jellyfin and Emby

Silo's sign-in now uses the same labelled fields as Jellyfin and Emby: one
tinted group of Address, Name, Username and Password on iPhone, and the same
two-column grid on Apple TV. Account or API Key is a pair of selectable buttons
above the fields, with a checkmark on the one in use; the API key field is
hidden like a password but is not offered saved passwords. Profiles, the PIN,
Connect and Use Another Account use the same button style as every other
server's sign-in, in Silo's colours. Every place that adds a media server opens
the same sheet, so this covers the Library, Settings and the welcome screen.
Sign-in and profile logic is unchanged.
