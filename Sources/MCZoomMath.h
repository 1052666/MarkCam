#ifndef MC_ZOOM_MATH_H
#define MC_ZOOM_MATH_H
#include <math.h>
// Hardware factor 1 is the widest constituent, NOT necessarily the 1x wide lens.
static inline double MCZoomDisplay(double hardware,double wideReference){return hardware/fmax(1,wideReference);}
static inline double MCZoomHardware(double display,double wideReference,double deviceMin,double deviceMax){
 double lo=fmax(1,deviceMin),hi=fmax(lo,fmin(deviceMax,8*fmax(1,wideReference)));
 double z=isfinite(display)?display*fmax(1,wideReference):wideReference;
 return fmax(lo,fmin(hi,z));
}
#endif
