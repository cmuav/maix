// Stubs for gstreamer static-plugin register symbols that CocoaSpice's
// gst_ios_init.m calls unconditionally (via GST_IOS_PLUGINS_CORE/SYS/PLAYBACK
// defines in gst_ios_init.h). UTM's build links static plugin archives; we
// don't. The stubs return TRUE so gst_init proceeds; we use GStreamer only
// for SPICE audio, which we're not rendering in Phase 2b.

typedef int gboolean;

#define STUB(name) gboolean gst_plugin_##name##_register(void) { return 1; }

STUB(adder)
STUB(app)
STUB(audioconvert)
STUB(audiorate)
STUB(audioresample)
STUB(audiotestsrc)
STUB(autodetect)
STUB(coreelements)
STUB(gio)
STUB(jpeg)
STUB(osxaudio)
STUB(playback)
STUB(typefindfunctions)
STUB(videoconvert)
STUB(videofilter)
STUB(videorate)
STUB(videoscale)
STUB(videotestsrc)
STUB(volume)
