#ifndef MC_WORK_POLICY_H
#define MC_WORK_POLICY_H
#include <stdint.h>
// Advisory backpressure, not an iOS memory guarantee. Zero means unavailable.
#define MC_MAX_PENDING 6
#define MC_CAPTURE_RESERVE (160ULL*1024*1024)
#define MC_RENDER_RESERVE (256ULL*1024*1024)
static inline int MCCanCapture(unsigned pending,int live,int pausedPressure,uint64_t available){
 return !pausedPressure && pending<(live?2:MC_MAX_PENDING) && (!available||available>=MC_CAPTURE_RESERVE);
}
static inline int MCCanRender(int foreground,int captureBusy,int processing,int paused,int thermal,uint64_t available){
 return foreground&&!captureBusy&&!processing&&!paused&&thermal<2&&(!available||available>=MC_RENDER_RESERVE);
}
#endif
