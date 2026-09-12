#include "MCWorkPolicy.h"
#include <assert.h>
#include <stdio.h>

int main(void) {
 const uint64_t ample=1024ULL*1024*1024;
 // Empty queue; pressure and memory recovery without a job change.
 assert(MCCanStartCapture(0,0,0,0,0,0,ample));
 assert(!MCCanStartCapture(0,0,0,0,0,1,ample));
 assert(MCCanStartCapture(0,0,0,0,0,0,ample));
 assert(!MCCanStartCapture(0,0,0,0,0,0,MC_CAPTURE_RESERVE-1));
 assert(MCCanStartCapture(0,0,0,0,0,0,MC_CAPTURE_RESERVE));
 assert(MCCanStartCapture(0,0,0,0,0,0,0)); // Unavailable measurement.
 // Ordinary photos can overlap light processing, but remain bounded.
 assert(MCCanStartCapture(5,0,0,1,0,0,ample));
 assert(!MCCanStartCapture(6,0,0,0,0,0,ample));
 assert(MCCanStartCapture(5,0,0,0,0,0,ample));
 // Live and video cannot overlap processing; Live's cap is photo-mode only.
 assert(!MCCanStartCapture(0,1,0,1,0,0,ample));
 assert(!MCCanStartCapture(0,0,1,1,0,0,ample));
 assert(!MCCanStartCapture(2,1,0,0,0,0,ample));
 assert(MCCanStartCapture(2,1,1,0,0,0,ample));
 assert(!MCCanStartCapture(0,0,0,1,1,0,ample));
 // Editor/capture ownership prevents rendering and releasing it resumes work.
 assert(!MCCanRender(1,1,0,0,0,ample));
 assert(MCCanRender(1,0,0,0,0,ample));
 assert(!MCCanRender(0,0,0,0,0,ample));
 assert(!MCCanRender(1,0,0,1,0,ample));
 assert(!MCCanRender(1,0,0,0,2,ample));
 assert(MCCanRender(1,0,0,0,1,ample));
 puts("20 native capture/worker policy assertions passed");
}
