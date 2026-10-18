#import "LineupVLCBridge.h"

void *LineupVLCVideoSetCallbacksAddress(void) {
    return (void *)&libvlc_video_set_callbacks;
}

void *LineupVLCVideoSetFormatCallbacksAddress(void) {
    return (void *)&libvlc_video_set_format_callbacks;
}

int64_t LineupVLCPlaybackTimeMilliseconds(VLCMediaPlayer *player) {
    return player ? libvlc_media_player_get_time(player.playerInstance) : -1;
}
