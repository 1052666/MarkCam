#ifndef MC_CAMERA_LAYOUT_H
#define MC_CAMERA_LAYOUT_H
#include <math.h>
typedef struct { double x,y,w,h; } MCRect;
typedef struct { MCRect stage,mode,shutter,files,flip,edit,watermark,live,settings,hint,lenses,zoomLabel,zoomSlider,status; } MCCameraLayout;
static inline MCRect MCR(double x,double y,double w,double h){return (MCRect){x,y,fmax(0,w),fmax(0,h)};}
// Shared by native UIKit and executable host geometry tests. Never aspect-fill/crop.
static inline MCCameraLayout MCLayout(double w,double h,double top,double bottom,double left,double right,double aspect){
 MCCameraLayout a={0};if(!(aspect>0))aspect=w>h?4./3:3./4;double controlsBottom=0;
 if(w<=h){
  int compact=h-top-bottom<660;double dock=compact?154:164,dockY=h-bottom-dock;
  int video=aspect<.65;
  double stageTop=top+((compact||video)?0:44),space=fmax(1,(video?h-bottom:dockY)-stageTop);
  double fw=fmin(w,space*aspect),fh=fw/aspect;
  a.stage=MCR((w-fw)/2,stageTop+(space-fh)/2,fw,fh);
  a.mode=MCR((w-156)/2,dockY+2,156,34);
  double d=compact?68:76,sy=dockY+42;
  a.shutter=MCR((w-d)/2,sy,d,d);a.files=MCR(22,sy+(d-48)/2,56,48);a.flip=MCR(w-78,sy+(d-48)/2,56,48);
  a.edit=MCR((w-208)/2,h-bottom-38,208,36);
  a.watermark=MCR(12,top,76,44);a.live=MCR((w-84)/2,top,84,44);a.settings=MCR(w-64,top,52,44);
  a.hint=MCR(12,(compact||video)?48:8,fmax(1,fw-24),22);
  if(video)controlsBottom=fmax(0,a.stage.y+a.stage.h-dockY+4);
 }else{
  double dock=132,space=fmax(1,w-left-right-dock),sh=h-top-bottom;
  double fw=fmin(space,sh*aspect),fh=fw/aspect;
  a.stage=MCR(left+(space-fw)/2,top+(sh-fh)/2,fw,fh);
  double x=w-right-dock;
  a.mode=MCR(x+4,top+52,dock-8,32);double d=68,sy=top+92;
  a.shutter=MCR(x+(dock-d)/2,sy,d,d);a.files=MCR(x+9,sy+d+12,48,44);a.flip=MCR(x+dock-57,sy+d+12,48,44);
  a.edit=MCR(x+4,h-bottom-40,dock-8,36);
  a.watermark=MCR(left+8,top,72,44);a.live=MCR(left+88,top,82,44);a.settings=MCR(x+dock-56,top,52,44);
  a.hint=MCR(12,48,fmax(1,fw-24),22);
 }
 // Controls float on the full uncropped preview without reducing its height.
 a.lenses=MCR((a.stage.w-fmin(220,a.stage.w-24))/2,a.stage.h-98-controlsBottom,fmin(220,a.stage.w-24),40);
 a.zoomLabel=MCR(14,a.stage.h-52-controlsBottom,56,40);
 a.zoomSlider=MCR(78,a.stage.h-54-controlsBottom,fmax(44,a.stage.w-94),44);
 a.status=MCR(a.stage.x+12,a.stage.y+a.stage.h-134-controlsBottom,fmax(1,a.stage.w-24),30);
 return a;
}
#endif
