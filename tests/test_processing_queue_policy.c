#include "MCWorkPolicy.h"
#include <limits.h>
#include <math.h>
#include <stdio.h>

static unsigned checks;
#define CHECK(name, value) do { checks++; if (!(value)) { fprintf(stderr,"FAIL: %s\n",name); return 1; } } while (0)
#define ADMIT(pending,reserved,live,memory) MCCaptureAdmission(pending,reserved,live,0,0,0,memory)

int main(void) {
 const uint64_t mb=1024ULL*1024;
 CHECK("first normal request accepted",MCCanAcceptPhotoRequest(0,0,0));
 CHECK("second normal request overlaps",MCCanAcceptPhotoRequest(1,0,0));
 CHECK("third normal request bounded",!MCCanAcceptPhotoRequest(2,0,0));
 CHECK("completion returns one slot",MCCanAcceptPhotoRequest(2-1,0,0));
 CHECK("live capture waits for ordinary photo",!MCCanAcceptPhotoRequest(1,1,0));
 CHECK("ordinary photo waits for live capture",!MCCanAcceptPhotoRequest(1,0,1));
 CHECK("live capture starts when idle",MCCanAcceptPhotoRequest(0,1,0));
 CHECK("four queued and one reserved accepts sixth",ADMIT(4,1,0,512*mb)==MCAdmissionAllowed);
 CHECK("five queued and one reserved refuses seventh",ADMIT(5,1,0,512*mb)==MCAdmissionPending);
 CHECK("six queued refuses next",ADMIT(6,0,0,512*mb)==MCAdmissionPending);
 CHECK("inflight has independent bound",ADMIT(0,2,0,512*mb)==MCAdmissionInFlight);
 CHECK("pending count cannot wrap budget",ADMIT(UINT_MAX,1,0,512*mb)==MCAdmissionPending);
 CHECK("reserved count cannot wrap budget",ADMIT(1,UINT_MAX,0,512*mb)==MCAdmissionInFlight);
 CHECK("one queued live accepts one more",ADMIT(1,0,1,512*mb)==MCAdmissionAllowed);
 CHECK("two queued jobs block live",ADMIT(2,0,1,512*mb)==MCAdmissionPending);
 CHECK("photo rendering allows ordinary capture",MCCaptureAdmission(1,0,0,0,0,1,512*mb)==MCAdmissionAllowed);
 CHECK("photo rendering blocks live capture",MCCaptureAdmission(1,0,1,0,0,1,512*mb)==MCAdmissionLiveProcessing);
 CHECK("heavy processing blocks ordinary capture",MCCaptureAdmission(1,0,0,0,1,1,512*mb)==MCAdmissionHeavyProcessing);
 CHECK("memory warning blocks capture",MCCaptureAdmission(0,0,0,1,0,0,512*mb)==MCAdmissionPressure);
 CHECK("warning expiry recovers capture",MCCaptureAdmission(0,0,0,0,0,0,512*mb)==MCAdmissionAllowed);
 CHECK("below capture memory boundary blocks",ADMIT(0,0,0,MC_CAPTURE_RESERVE-1)==MCAdmissionMemory);
 CHECK("capture memory boundary admitted",ADMIT(0,0,0,MC_CAPTURE_RESERVE)==MCAdmissionAllowed);
 CHECK("zero remaining memory blocks capture",ADMIT(0,0,0,0)==MCAdmissionMemory);
 CHECK("zero remaining memory blocks render",!MCCanRender(1,0,0,0,0,0));
 CHECK("192MB permits capture",ADMIT(0,0,0,192*mb)==MCAdmissionAllowed);
 CHECK("192MB defers render independently",!MCCanRender(1,0,0,0,0,192*mb));
 CHECK("render boundary excluded below 256MB",!MCCanRender(1,0,0,0,0,MC_RENDER_RESERVE-1));
 CHECK("render boundary admitted at 256MB",MCCanRender(1,0,0,0,0,MC_RENDER_RESERVE));
 CHECK("background never starts render",!MCCanRender(0,0,0,0,0,512*mb));
 CHECK("inflight capture defers render",!MCCanRender(1,1,0,0,0,512*mb));
 CHECK("only one renderer",!MCCanRender(1,0,1,0,0,512*mb));
 CHECK("manual pause defers render",!MCCanRender(1,0,0,1,0,512*mb));
 CHECK("serious thermal defers render",!MCCanRender(1,0,0,0,2,512*mb));
 CHECK("cooled device resumes render",MCCanRender(1,0,0,0,1,512*mb));
 CHECK("denied ready job resumes after permission grant",MCShouldResumePermissionJob(1,1,1));
 CHECK("uncertain saving never auto retries",!MCShouldResumePermissionJob(0,1,1));
 CHECK("nonpermission failure remains blocked",!MCShouldResumePermissionJob(1,1,0));
 CHECK("unblocked ready job is not rewritten",!MCShouldResumePermissionJob(1,0,1));
 CHECK("unedited photo bypasses rendering",!MCPhotoNeedsRendering(0,0,1,1,0));
 CHECK("enabled watermark requires rendering",MCPhotoNeedsRendering(1,0,1,1,0));
 CHECK("brightness requires rendering",MCPhotoNeedsRendering(0,.01,1,1,0));
 CHECK("contrast requires rendering",MCPhotoNeedsRendering(0,0,.99,1,0));
 CHECK("saturation requires rendering",MCPhotoNeedsRendering(0,0,1,.99,0));
 CHECK("warmth requires rendering",MCPhotoNeedsRendering(0,0,1,1,.01));
 CHECK("tiny requested edit is preserved",MCPhotoNeedsRendering(0,1e-12,1,1,0));
 CHECK("NaN cannot enable no-edit path",MCPhotoNeedsRendering(0,NAN,1,1,0));
 CHECK("infinity cannot enable no-edit path",MCPhotoNeedsRendering(0,0,INFINITY,1,0));
 // The compatibility entrypoint must remain equivalent when no request is held.
 for(unsigned p=0;p<8;p++)for(int live=0;live<2;live++)for(int pressure=0;pressure<2;pressure++){
  uint64_t levels[]={0,MC_CAPTURE_RESERVE-1,MC_CAPTURE_RESERVE,MC_RENDER_RESERVE};
  for(unsigned i=0;i<4;i++)CHECK("legacy admission agrees with zero reservations",MCCanCapture(p,live,pressure,levels[i])==(MCCaptureAdmission(p,0,live,pressure,0,0,levels[i])==MCAdmissionAllowed));
 }
 printf("{\"passed\":%u,\"failed\":0}\n",checks);
 return 0;
}
