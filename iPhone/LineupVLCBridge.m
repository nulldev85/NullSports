#import "LineupVLCBridge.h"

void *LineupVLCVideoSetCallbacksAddress(void) {
    return (void *)&libvlc_video_set_callbacks;
}

void *LineupVLCVideoSetFormatCallbacksAddress(void) {
    return (void *)&libvlc_video_set_format_callbacks;
}
