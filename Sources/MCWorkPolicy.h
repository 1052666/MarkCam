#ifndef MC_WORK_POLICY_H
#define MC_WORK_POLICY_H
#include <stdint.h>
// Advisory backpressure, not an iOS memory guarantee. Zero cannot justify a
// large allocation: os_proc_available_memory can return zero at the process limit.
#define MC_MAX_PENDING 6U
#define MC_MAX_PHOTO_IN_FLIGHT 2U
#define MC_CAPTURE_RESERVE (160ULL*1024*1024)
#define MC_RENDER_RESERVE (256ULL*1024*1024)
typedef enum {
 MCAdmissionAllowed,
 MCAdmissionHeavyProcessing,
 MCAdmissionLiveProcessing,
 MCAdmissionPressure,
 MCAdmissionInFlight,
 MCAdmissionPending,
 MCAdmissionMemory
} MCCaptureAdmissionResult;
static inline int MCCanAcceptPhotoRequest(unsigned inFlight,int live,int liveInFlight){
 return !liveInFlight && inFlight<(live?1:MC_MAX_PHOTO_IN_FLIGHT);
}
// Reserve capacity before asking AVFoundation for a photo; completion callbacks
// can arrive out of order. Subtract only after checking pending to avoid overflow.
static inline MCCaptureAdmissionResult MCCaptureAdmission(unsigned pending,unsigned reserved,int live,int pressure,int heavy,int processing,uint64_t available){
 unsigned limit=live?2:MC_MAX_PENDING;
 if(heavy)return MCAdmissionHeavyProcessing;
 if(live&&processing)return MCAdmissionLiveProcessing;
 if(pressure)return MCAdmissionPressure;
 if(!MCCanAcceptPhotoRequest(reserved,live,0))return MCAdmissionInFlight;
 if(pending>=limit||reserved>=limit-pending)return MCAdmissionPending;
 if(available<MC_CAPTURE_RESERVE)return MCAdmissionMemory;
 return MCAdmissionAllowed;
}
static inline int MCCanCapture(unsigned pending,int live,int pausedPressure,uint64_t available){
 return !pausedPressure && pending<(live?2:MC_MAX_PENDING) && available>=MC_CAPTURE_RESERVE;
}
static inline int MCCanRender(int foreground,int captureBusy,int processing,int paused,int thermal,uint64_t available){
 return foreground&&!captureBusy&&!processing&&!paused&&thermal<2&&available>=MC_RENDER_RESERVE;
}
static inline int MCPhotoNeedsRendering(int watermark,double brightness,double contrast,double saturation,double warmth){
 return watermark||brightness!=0.0||contrast!=1.0||saturation!=1.0||warmth!=0.0;
}
static inline int MCShouldResumePermissionJob(int ready,int blocked,int permissionReason){
 return ready&&blocked&&permissionReason;
}
#endif
