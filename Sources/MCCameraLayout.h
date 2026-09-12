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
  int compact=h-top-bottom<660;double dock=compact?174:184,dockY=h-bottom-dock;
  int video=aspect<.65;
  double stageTop=top+((compact||video)?0:44),space=fmax(1,(video?h-bottom:dockY)-stageTop);
  double fw=fmin(w,space*aspect),fh=fw/aspect;
  a.stage=MCR((w-fw)/2,stageTop+(space-fh)/2,fw,fh);
  a.mode=MCR((w-156)/2,dockY+2,156,44);
  double d=compact?68:76,sy=dockY+54;
  a.shutter=MCR((w-d)/2,sy,d,d);a.files=MCR(18,sy+(d-48)/2,72,48);a.flip=MCR(w-70,sy+(d-48)/2,52,48);
  a.edit=MCR((w-180)/2,h-bottom-44,180,44);
  a.watermark=MCR(12,top,92,44);a.live=MCR((w-96)/2,top,96,44);a.settings=MCR(w-64,top,52,44);
  a.hint=MCR(12,(compact||video)?48:8,fmax(1,fw-24),22);
  if(video)controlsBottom=fmax(0,a.stage.y+a.stage.h-dockY+4);
 }else{
  double dock=132,space=fmax(1,w-left-right-dock),sh=h-top-bottom;
  double fw=fmin(space,sh*aspect),fh=fw/aspect;
  a.stage=MCR(left+(space-fw)/2,top+(sh-fh)/2,fw,fh);
  double x=w-right-dock;
  a.mode=MCR(x+4,top+52,dock-8,44);double d=68,sy=top+108;
  a.shutter=MCR(x+(dock-d)/2,sy,d,d);a.files=MCR(x+4,sy+d+12,66,48);a.flip=MCR(x+dock-52,sy+d+12,48,48);
  a.edit=MCR(x+4,h-bottom-44,dock-8,44);
  a.watermark=MCR(left+8,top,92,44);a.live=MCR(left+112,top,96,44);a.settings=MCR(x+dock-56,top,52,44);
  a.hint=MCR(12,48,fmax(1,fw-24),22);
 }
 // Controls float on the full uncropped preview without reducing its height.
 a.lenses=MCR((a.stage.w-fmin(220,a.stage.w-24))/2,a.stage.h-104-controlsBottom,fmin(220,a.stage.w-24),44);
 a.zoomLabel=MCR(14,a.stage.h-54-controlsBottom,56,44);
 a.zoomSlider=MCR(78,a.stage.h-54-controlsBottom,fmax(44,a.stage.w-94),44);
 a.status=MCR(a.stage.x+12,a.stage.y+a.stage.h-158-controlsBottom,fmax(1,a.stage.w-24),44);
 return a;
}
#endif
