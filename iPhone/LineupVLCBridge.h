#import <Foundation/Foundation.h>
#import <MobileVLCKit/MobileVLCKit.h>

/*
 * Reaching libvlc's C API from Swift.
 *
 * MobileVLCKit ships libvlc's headers inside the framework, but its module map
 * excludes every one of them, so `import VLCKitSPM` cannot see the C API. The
 * symbols themselves are exported from the framework binary, verified against
 * the shipped 3.6.0 slices:
 *
 *     T _libvlc_video_set_callbacks
 *     T _libvlc_video_set_format_callbacks
 *
 * So rather than fight the module map by importing excluded headers, this
 * declares the handful of things we use and lets the linker resolve them. The
 * declarations are copied from libvlc 3.0's own headers and must match its ABI
 * exactly -- if a future VLCKit changes them, the link or the behaviour breaks,
 * which is why the version is pinned in project.yml and checked in CI.
 */

typedef struct libvlc_media_player_t libvlc_media_player_t;

typedef void *(*libvlc_video_lock_cb)(void *opaque, void **planes);
typedef void (*libvlc_video_unlock_cb)(void *opaque, void *picture, void *const *planes);
typedef void (*libvlc_video_display_cb)(void *opaque, void *picture);
typedef unsigned (*libvlc_video_format_cb)(void **opaque, char *chroma,
                                           unsigned *width, unsigned *height,
                                           unsigned *pitches, unsigned *lines);
typedef void (*libvlc_video_cleanup_cb)(void *opaque);

extern void libvlc_video_set_callbacks(libvlc_media_player_t *mp,
                                       libvlc_video_lock_cb lock,
                                       libvlc_video_unlock_cb unlock,
                                       libvlc_video_display_cb display,
                                       void *opaque);

extern void libvlc_video_set_format_callbacks(libvlc_media_player_t *mp,
                                              libvlc_video_format_cb setup,
                                              libvlc_video_cleanup_cb cleanup);

/* LibVLC's public clock query reads input time even while paused. VLCKit's
 * cached time relies on events which VLC3 suppresses outside PLAYING_S. */
extern int64_t libvlc_media_player_get_time(libvlc_media_player_t *mp);

/* Writes the picture on screen to a PNG at psz_filepath, from libvlc 3.0's
 * libvlc_media_player.h. Auto Sync reads the broadcast's scoreboard from it.
 * VLCKit's own snapshot method wraps the same call. num is the video output,
 * 0 for the only one; a width with a height of 0 keeps the aspect. */
extern int libvlc_video_take_snapshot(libvlc_media_player_t *p_mi, unsigned num,
                                      const char *psz_filepath,
                                      unsigned int i_width, unsigned int i_height);

/*
 * VLCKit declares this in PrivateHeaders/VLCMediaPlayer+Internal.h, which is
 * not in the umbrella header and so is invisible to Swift. The selector exists
 * on the real class; re-declaring it here is a declaration only, with no
 * implementation to provide.
 */
@interface VLCMediaPlayer (LineupBridge)
@property (readonly) libvlc_media_player_t *playerInstance;
@end

/*
 * Returning the addresses forces the linker to resolve both symbols, so a
 * VLCKit that no longer exports them fails the build rather than failing on a
 * viewer's phone. Nothing here calls into libvlc.
 */
void *LineupVLCVideoSetCallbacksAddress(void);
void *LineupVLCVideoSetFormatCallbacksAddress(void);
int64_t LineupVLCPlaybackTimeMilliseconds(VLCMediaPlayer *player);
