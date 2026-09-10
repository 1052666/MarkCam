#include <stdio.h>
#include <stdlib.h>
#include "MCCameraLayout.h"
#include "MCZoomMath.h"
static void rect(const char *name,MCRect r,int last){printf("\"%s\":[%.9f,%.9f,%.9f,%.9f]%s",name,r.x,r.y,r.w,r.h,last?"":",");}
int main(int argc,char **argv){
 if(argc==6){printf("%.9f\n",MCZoomHardware(atof(argv[1]),atof(argv[2]),atof(argv[3]),atof(argv[4])));return 0;}
 if(argc!=8)return 2;
 MCCameraLayout a=MCLayout(atof(argv[1]),atof(argv[2]),atof(argv[3]),atof(argv[4]),atof(argv[5]),atof(argv[6]),atof(argv[7]));
 printf("{");
 #define OUT(n) rect(#n,a.n,0)
 OUT(stage);OUT(mode);OUT(shutter);OUT(files);OUT(flip);OUT(edit);OUT(watermark);OUT(live);OUT(settings);OUT(hint);OUT(lenses);OUT(zoomLabel);OUT(zoomSlider);rect("status",a.status,1);
 printf("}\n");return 0;
}
