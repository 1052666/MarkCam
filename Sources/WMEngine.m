#import "WMEngine.h"
#import <ImageIO/ImageIO.h>
#import <math.h>
static NSError *WMError(NSString *s) { return [NSError errorWithDomain:@"MarkCam.WMEngine" code:1 userInfo:@{NSLocalizedDescriptionKey:s}]; }
static double WN(id v,double d,double lo,double hi) { if(![v isKindOfClass:NSNumber.class])return d; double n=[v doubleValue]; return isfinite(n)?fmax(lo,fmin(hi,n)):d; }
static NSString *WS(id s,NSString *fallback) { return [s isKindOfClass:NSString.class]?s:fallback; }
static BOOL SafeName(id s) { if(![s isKindOfClass:NSString.class]||![s length]||[s length]>120)return NO; return [s rangeOfCharacterFromSet:[[NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_."] invertedSet]].location==NSNotFound && ![s hasPrefix:@"."]; }
static NSDictionary *Layer(NSString *type,NSString *text,double x,double y) { return @{ @"id":NSUUID.UUID.UUIDString,@"type":type,@"text":text,@"x":@(x),@"y":@(y),@"width":@.7,@"fontSize":@.04,@"scale":@1,@"rotation":@0,@"color":@"#FFFFFF",@"opacity":@1,@"background":@NO,@"shadow":@YES,@"locked":@NO,@"font":@"system",@"bold":@YES }; }
static BOOL ValidLayers(id layers) {
 if(![layers isKindOfClass:NSArray.class]||[layers count]>80)return NO;
 for(id l in layers){ if(![l isKindOfClass:NSDictionary.class])return NO;
 if(![@[@"text",@"date",@"image"] containsObject:l[@"type"]])return NO;
 for(NSString *k in @[@"id",@"text",@"color",@"font",@"asset"])if(l[k]&&![l[k] isKindOfClass:NSString.class])return NO;
 if([l[@"text"] length]>2000 || [l[@"id"] length]>100 || [l[@"color"] length]>20 || [l[@"font"] length]>40 || (l[@"asset"]&&!SafeName(l[@"asset"])))return NO;
 for(NSString *k in @[@"x",@"y",@"width",@"fontSize",@"scale",@"rotation",@"opacity",@"background",@"shadow",@"locked",@"bold"])if(l[k]&&(![l[k] isKindOfClass:NSNumber.class]||!isfinite([l[k] doubleValue])))return NO;
 } return YES;
}
static NSData *JSONData(id object, NSJSONWritingOptions options, NSError **error) {
 if(!object||![NSJSONSerialization isValidJSONObject:object]){if(error)*error=WMError(@"设置包含非 JSON 数据");return nil;}
 return [NSJSONSerialization dataWithJSONObject:object options:options error:error];
}
static BOOL ValidSettings(id s) {
 if(![s isKindOfClass:NSDictionary.class]||!ValidLayers(s[@"layers"]))return NO;
 if(s[@"schemaVersion"]&&(![s[@"schemaVersion"] isKindOfClass:NSNumber.class]||[s[@"schemaVersion"] doubleValue]!=1))return NO;
 id tone=s[@"tone"]; if(tone&&![tone isKindOfClass:NSDictionary.class])return NO;
 for(NSString *k in @[@"brightness",@"contrast",@"saturation",@"warmth"])if(tone[k]&&(![tone[k] isKindOfClass:NSNumber.class]||!isfinite([tone[k] doubleValue])))return NO;
 for(NSString *k in @[@"watermarkEnabled",@"keepOriginal",@"gridEnabled",@"mirrorFront",@"flashMode",@"timerSeconds",@"livePhotoEnabled",@"exposureBias",@"smoothPreview",@"fastCapture"])if(s[k]&&(![s[k] isKindOfClass:NSNumber.class]||!isfinite([s[k]doubleValue])))return NO;
 id ts=s[@"userTemplates"]; if(ts){if(![ts isKindOfClass:NSArray.class]||[ts count]>60)return NO;for(id t in ts)if(![t isKindOfClass:NSDictionary.class]||![t[@"name"] isKindOfClass:NSString.class]||[t[@"name"] length]>100||!ValidLayers(t[@"layers"]))return NO;}return YES;
}
static UIImage *Decode(NSData *data) {
 if(!data||data.length>12*1024*1024)return nil;
 CGImageSourceRef src=CGImageSourceCreateWithData((__bridge CFDataRef)data,NULL);if(!src)return nil;
 NSDictionary *p=CFBridgingRelease(CGImageSourceCopyPropertiesAtIndex(src,0,NULL));double w=[p[(__bridge NSString *)kCGImagePropertyPixelWidth] doubleValue],h=[p[(__bridge NSString *)kCGImagePropertyPixelHeight] doubleValue];
 UIImage *im=nil;if(w>0&&h>0&&w<=8192&&h<=8192&&w*h<=20000000){CGImageRef cg=CGImageSourceCreateThumbnailAtIndex(src,0,(__bridge CFDictionaryRef)@{(__bridge NSString *)kCGImageSourceCreateThumbnailFromImageAlways:@YES,(__bridge NSString *)kCGImageSourceCreateThumbnailWithTransform:@YES,(__bridge NSString *)kCGImageSourceThumbnailMaxPixelSize:@2048});if(cg){im=[UIImage imageWithCGImage:cg];CGImageRelease(cg);}}CFRelease(src);return im;
}
@interface WMEngine ()
@property(nonatomic,strong) CIContext *context;
@end
@implementation WMEngine
+ (BOOL)isValidSettingsSnapshot:(id)settings { return ValidSettings(settings); }
+ (instancetype)shared { static WMEngine *e;static dispatch_once_t once;dispatch_once(&once,^{e=[WMEngine new];});return e; }
- (NSURL *)documentsURL { NSURL *u=[NSFileManager.defaultManager URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject;[NSFileManager.defaultManager createDirectoryAtURL:u withIntermediateDirectories:YES attributes:nil error:nil];return u; }
- (NSMutableDictionary *)defaults {return [@{@"schemaVersion":@1,@"watermarkEnabled":@YES,@"layers":[self presets][0][@"layers"],@"tone":@{@"brightness":@0,@"contrast":@1,@"saturation":@1,@"warmth":@0},@"keepOriginal":@NO,@"gridEnabled":@YES,@"mirrorFront":@YES,@"flashMode":@0,@"timerSeconds":@0,@"livePhotoEnabled":@NO,@"exposureBias":@0,@"smoothPreview":@NO,@"fastCapture":@YES,@"userTemplates":@[]} mutableCopy];}
- (instancetype)init {
 if((self=[super init])){
 _context=[CIContext contextWithOptions:@{kCIContextCacheIntermediates:@NO}];_settings=[self defaults];
 NSURL *u=[[self documentsURL] URLByAppendingPathComponent:@"settings.json"];NSNumber *length=nil;[u getResourceValue:&length forKey:NSURLFileSizeKey error:nil];
 if(length&&length.unsignedLongLongValue<=32*1024*1024){NSData *d=[NSData dataWithContentsOfURL:u options:NSDataReadingMappedIfSafe error:nil];id s=d?[NSJSONSerialization JSONObjectWithData:d options:NSJSONReadingMutableContainers error:nil]:nil;if(ValidSettings(s))[_settings addEntriesFromDictionary:s];}
 NSData *copy=JSONData(_settings,0,nil);_settings=[NSJSONSerialization JSONObjectWithData:copy options:NSJSONReadingMutableContainers error:nil];
 }return self;
}
// UI owns mutations; background capture queues consume snapshots, never settings.
- (NSDictionary *)snapshot {
 @synchronized(self){NSMutableDictionary *merged=[self defaults];if([self.settings isKindOfClass:NSDictionary.class])[merged addEntriesFromDictionary:self.settings];
 NSData *d=ValidSettings(merged)?JSONData(merged,0,nil):nil;if(!d)d=JSONData([self defaults],0,nil);
 return [NSJSONSerialization JSONObjectWithData:d options:0 error:nil];}
}
- (void)clearCaches { [self.context clearCaches]; }
- (void)save {
 @synchronized(self){NSMutableDictionary *s=[self defaults];if([self.settings isKindOfClass:NSDictionary.class])[s addEntriesFromDictionary:self.settings];if(!ValidSettings(s))return;
 NSData *d=JSONData(s,0,nil);if(d.length>32*1024*1024)return;
 [d writeToURL:[[self documentsURL] URLByAppendingPathComponent:@"settings.json"] options:NSDataWritingAtomic error:nil];}
}
- (NSArray<NSDictionary *> *)presets {
 NSMutableDictionary *date=[Layer(@"date",@"{date}  {time}",.5,.9) mutableCopy];date[@"font"]=@"mono";date[@"color"]=@"#FFD38A";
 NSMutableDictionary *brand=[Layer(@"image",@"",.5,.8) mutableCopy];brand[@"asset"]=@"stamp-aperture.png";brand[@"width"]=@.18;
 NSMutableDictionary *card=[Layer(@"text",@"印记相机\n把这一刻留在照片里\n{date}",.5,.8) mutableCopy];card[@"background"]=@YES;
 NSMutableDictionary *work=[Layer(@"text",@"工作记录\n{date} {time}\n事项：今日现场",.5,.8) mutableCopy];work[@"background"]=@YES;work[@"font"]=@"mono";
 NSMutableArray *tiles=[NSMutableArray array];for(int y=0;y<4;y++)for(int x=0;x<3;x++){NSMutableDictionary *l=[Layer(@"text",@"印记 · {date}",.16+x*.34,.13+y*.25) mutableCopy];l[@"width"]=@.42;l[@"fontSize"]=@.025;l[@"rotation"]=@(-.4);l[@"opacity"]=@.3;[tiles addObject:l];}
 return @[@{@"name":@"极简签名",@"layers":@[Layer(@"text",@"记录生活 · 印记",.5,.9)]},@{@"name":@"日期胶片",@"layers":@[date]},@{@"name":@"品牌标识",@"layers":@[brand,Layer(@"text",@"MY MOMENT",.5,.92)]},@{@"name":@"信息卡片",@"layers":@[card]},@{@"name":@"工作记录",@"layers":@[work]},@{@"name":@"全图平铺",@"layers":tiles}];
}
- (UIImage *)imageForLayer:(NSDictionary *)layer {
 NSString *name=layer[@"asset"];if(!SafeName(name))return nil;
 NSURL *base=[[self documentsURL] URLByAppendingPathComponent:@"assets" isDirectory:YES];NSURL *u=[base URLByAppendingPathComponent:name];NSString *root=base.URLByResolvingSymlinksInPath.path;
 if([root isEqual:[[self documentsURL].URLByResolvingSymlinksInPath.path stringByAppendingPathComponent:@"assets"]]&&[u.URLByResolvingSymlinksInPath.path hasPrefix:[root stringByAppendingString:@"/"]]){NSNumber *size=nil;[u getResourceValue:&size forKey:NSURLFileSizeKey error:nil];if(size&&size.unsignedLongLongValue<=12*1024*1024){UIImage *im=Decode([NSData dataWithContentsOfURL:u options:NSDataReadingMappedIfSafe error:nil]);if(im)return im;}}
 NSString *p=[NSBundle.mainBundle pathForResource:name ofType:nil];return p?Decode([NSData dataWithContentsOfFile:p options:NSDataReadingMappedIfSafe error:nil]):nil;
}
static UIColor *Color(id value) {NSString *s=WS(value,@"#FFFFFF");if([s hasPrefix:@"#"])s=[s substringFromIndex:1];if(s.length!=6)return UIColor.whiteColor;unsigned int rgb=0;if(![[NSScanner scannerWithString:s] scanHexInt:&rgb])return UIColor.whiteColor;return [UIColor colorWithRed:((rgb>>16)&255)/255. green:((rgb>>8)&255)/255. blue:(rgb&255)/255. alpha:1];}
- (UIImage *)overlayForSize:(CGSize)size settings:(NSDictionary *)settings date:(NSDate *)date {
 if(!isfinite(size.width)||!isfinite(size.height)||size.width<1||size.height<1||size.width>16384||size.height>16384||size.width*size.height>64000000)size=CGSizeMake(1,1);
 UIGraphicsImageRendererFormat *format=[UIGraphicsImageRendererFormat defaultFormat];format.scale=1;format.opaque=NO;format.preferredRange=UIGraphicsImageRendererFormatRangeStandard;
 UIGraphicsImageRenderer *renderer=[[UIGraphicsImageRenderer alloc] initWithSize:size format:format];
 return [renderer imageWithActions:^(UIGraphicsImageRendererContext *rc){
 if(settings[@"watermarkEnabled"]&&WN(settings[@"watermarkEnabled"],1,0,1)==0)return;
 NSArray *layers=settings[@"layers"];if(!ValidLayers(layers))return;
 NSDateFormatter *df=[NSDateFormatter new];df.locale=[NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];df.calendar=[[NSCalendar alloc] initWithCalendarIdentifier:NSCalendarIdentifierGregorian];df.dateFormat=@"yyyy.MM.dd";NSString *ds=[df stringFromDate:date];df.dateFormat=@"HH:mm:ss";NSString *ts=[df stringFromDate:date];
 CGFloat shortSide=MIN(size.width,size.height);CGContextRef c=rc.CGContext;
 for(NSDictionary *l in layers){@autoreleasepool{
 CGFloat scale=WN(l[@"scale"],1,.1,5),w=shortSide*WN(l[@"width"],.7,.02,2)*scale;CGFloat fs=shortSide*WN(l[@"fontSize"],.04,.005,.3)*scale;
 UIImage *asset=nil;NSDictionary *attrs=nil;NSString *text=nil;CGFloat inset=fs*.25,h=0;
 if([l[@"type"] isEqual:@"image"]){asset=[self imageForLayer:l];if(!asset||asset.size.width<=0)continue;h=w*asset.size.height/asset.size.width;if(h>shortSide*8){w*=shortSide*8/h;h=shortSide*8;}}
 else {text=WS(l[@"text"],@"");text=[[text stringByReplacingOccurrencesOfString:@"{date}" withString:ds] stringByReplacingOccurrencesOfString:@"{time}" withString:ts];BOOL bold=l[@"bold"]?[l[@"bold"] boolValue]:YES;UIFont *font=[UIFont systemFontOfSize:fs weight:bold?UIFontWeightBold:UIFontWeightRegular];NSString *fn=WS(l[@"font"],@"system");if([fn isEqual:@"mono"])font=[UIFont monospacedSystemFontOfSize:fs weight:bold?UIFontWeightBold:UIFontWeightRegular];else if([fn isEqual:@"serif"])font=[UIFont fontWithName:bold?@"Georgia-Bold":@"Georgia" size:fs]?:font;
 NSMutableParagraphStyle *p=[NSMutableParagraphStyle new];p.alignment=NSTextAlignmentCenter;p.lineBreakMode=NSLineBreakByWordWrapping;
 attrs=@{NSFontAttributeName:font,NSForegroundColorAttributeName:Color(l[@"color"]),NSParagraphStyleAttributeName:p};w=MAX(w,2*inset+1);CGRect bound=[text boundingRectWithSize:CGSizeMake(w-2*inset,shortSide*6) options:NSStringDrawingUsesLineFragmentOrigin|NSStringDrawingUsesFontLeading attributes:attrs context:nil];h=ceil(bound.size.height)+2*inset;}
 CGContextSaveGState(c);CGContextTranslateCTM(c,WN(l[@"x"],.5,0,1)*size.width,WN(l[@"y"],.85,0,1)*size.height);CGContextRotateCTM(c,WN(l[@"rotation"],0,-100,100));CGContextSetAlpha(c,WN(l[@"opacity"],1,0,1));CGContextBeginTransparencyLayer(c,NULL);
 CGRect rect=CGRectMake(-w/2,-h/2,w,h);
 if(!l[@"shadow"]||[l[@"shadow"] boolValue])CGContextSetShadowWithColor(c,CGSizeMake(0,fs*.05),MAX(1,fs*.1),[UIColor colorWithWhite:0 alpha:.7].CGColor);
 if([l[@"background"] boolValue]){[[UIColor colorWithWhite:0 alpha:.55] setFill];[[UIBezierPath bezierPathWithRoundedRect:rect cornerRadius:fs*.2] fill];}
 if(asset)[asset drawInRect:rect];else [text drawWithRect:CGRectInset(rect,inset,inset) options:NSStringDrawingUsesLineFragmentOrigin|NSStringDrawingUsesFontLeading attributes:attrs context:nil];
 CGContextEndTransparencyLayer(c);CGContextRestoreGState(c);
 }} }];
}
- (CIImage *)applyTone:(CIImage *)image settings:(NSDictionary *)settings {
 NSDictionary *t=[settings[@"tone"] isKindOfClass:NSDictionary.class]?settings[@"tone"]:@{};
 CIFilter *f=[CIFilter filterWithName:@"CIColorControls"];[f setValue:image forKey:kCIInputImageKey];[f setValue:@(WN(t[@"brightness"],0,-.3,.3)) forKey:kCIInputBrightnessKey];[f setValue:@(WN(t[@"contrast"],1,.5,1.5)) forKey:kCIInputContrastKey];[f setValue:@(WN(t[@"saturation"],1,0,2)) forKey:kCIInputSaturationKey];CIImage *out=f.outputImage?:image;
 double warmth=WN(t[@"warmth"],0,-1,1);if(fabs(warmth)>.001){CIFilter *temp=[CIFilter filterWithName:@"CITemperatureAndTint"];[temp setValue:out forKey:kCIInputImageKey];[temp setValue:[CIVector vectorWithX:6500+warmth*2000 Y:0] forKey:@"inputNeutral"];[temp setValue:[CIVector vectorWithX:6500 Y:0] forKey:@"inputTargetNeutral"];out=temp.outputImage?:out;}return out;
}
- (UIImage *)processPhoto:(UIImage *)image settings:(NSDictionary *)settings date:(NSDate *)date {
 @autoreleasepool {CIImage *ci=image.CIImage;if(!ci&&image.CGImage)ci=[CIImage imageWithCGImage:image.CGImage];if(!ci)return nil;
 int exif=1;switch(image.imageOrientation){case UIImageOrientationDown:exif=3;break;case UIImageOrientationLeft:exif=8;break;case UIImageOrientationRight:exif=6;break;case UIImageOrientationUpMirrored:exif=2;break;case UIImageOrientationDownMirrored:exif=4;break;case UIImageOrientationLeftMirrored:exif=5;break;case UIImageOrientationRightMirrored:exif=7;break;default:break;}
 ci=[ci imageByApplyingOrientation:exif];CGRect extent=ci.extent;if(CGRectIsInfinite(extent)||CGRectIsEmpty(extent))return nil;ci=[ci imageByApplyingTransform:CGAffineTransformMakeTranslation(-extent.origin.x,-extent.origin.y)];CGRect bounds=CGRectMake(0,0,extent.size.width,extent.size.height);
 UIImage *overlay=[self overlayForSize:bounds.size settings:settings date:date];CIImage *out=[[CIImage imageWithCGImage:overlay.CGImage] imageByCompositingOverImage:[self applyTone:ci settings:settings]];CGImageRef cg=[self.context createCGImage:out fromRect:bounds];if(!cg)return nil;UIImage *result=[UIImage imageWithCGImage:cg scale:1 orientation:UIImageOrientationUp];CGImageRelease(cg);return result;}
}
- (AVAssetExportSession *)exportVideo:(NSURL *)source destination:(NSURL *)dest settings:(NSDictionary *)settings date:(NSDate *)date completion:(void (^)(NSError *))completion {
 void (^fail)(NSString *)=^(NSString *message){dispatch_async(dispatch_get_main_queue(),^{completion(WMError(message));});};
 if(!source.isFileURL||!dest.isFileURL||[source.URLByResolvingSymlinksInPath.path isEqual:dest.URLByResolvingSymlinksInPath.path]){fail(@"输出必须是与原片不同的本地文件");return nil;}
 if([NSFileManager.defaultManager fileExistsAtPath:dest.path]){fail(@"输出文件已存在，请使用新文件名");return nil;}
 AVURLAsset *asset=[AVURLAsset URLAssetWithURL:source options:@{AVURLAssetPreferPreciseDurationAndTimingKey:@YES}];AVAssetTrack *track=[asset tracksWithMediaType:AVMediaTypeVideo].firstObject;if(!track){fail(@"原片没有可读取的视频轨道");return nil;}
 NSData *sd=JSONData(settings,0,nil);NSDictionary *frozen=sd?[NSJSONSerialization JSONObjectWithData:sd options:0 error:nil]:nil;if(!ValidSettings(frozen)){fail(@"视频水印设置无效");return nil;}
 CGRect oriented=CGRectApplyAffineTransform((CGRect){CGPointZero,track.naturalSize},track.preferredTransform);CGSize upright=CGSizeMake(fabs(oriented.size.width),fabs(oriented.size.height));if(!isfinite(upright.width)||!isfinite(upright.height)||upright.width<1||upright.height<1||upright.width>16384||upright.height>16384){fail(@"视频尺寸无效");return nil;}
 CGFloat factor=MIN(1.,MIN(1920./MAX(upright.width,upright.height),1080./MIN(upright.width,upright.height)));CGSize target=CGSizeMake(MAX(2,floor(upright.width*factor/2)*2),MAX(2,floor(upright.height*factor/2)*2));
 UIImage *overlayImage=[self overlayForSize:target settings:frozen date:date];CIImage *overlay=[CIImage imageWithCGImage:overlayImage.CGImage];CIContext *context=self.context;
 AVVideoComposition *composition=[AVVideoComposition videoCompositionWithAsset:asset applyingCIFiltersWithHandler:^(AVAsynchronousCIImageFilteringRequest *request){@autoreleasepool{
 // AVFoundation applies the track preferredTransform before this callback.
 // Normalize the actual upright source extent; never apply that transform twice.
 CIImage *frame=request.sourceImage;CGRect e=frame.extent;CGSize render=request.renderSize;
 if(CGRectIsInfinite(e)||CGRectIsEmpty(e)||render.width<1||render.height<1){[request finishWithError:WMError(@"视频帧尺寸无效")];return;}
 frame=[frame imageByApplyingTransform:CGAffineTransformMakeTranslation(-e.origin.x,-e.origin.y)];frame=[frame imageByApplyingTransform:CGAffineTransformMakeScale(render.width/e.size.width,render.height/e.size.height)];frame=[self applyTone:frame settings:frozen];
 CIImage *mark=overlay;if(render.width!=target.width||render.height!=target.height)mark=[mark imageByApplyingTransform:CGAffineTransformMakeScale(render.width/target.width,render.height/target.height)];
 CIImage *result=[[mark imageByCompositingOverImage:frame] imageByCroppingToRect:(CGRect){CGPointZero,render}];[request finishWithImage:result context:context];
 }}];
 // Never mutate the private CI composition. The export preset caps output at 1080p.
 AVAssetExportSession *session=[[AVAssetExportSession alloc] initWithAsset:asset presetName:AVAssetExportPreset1920x1080];if(!session){fail(@"此视频不支持导出");return nil;}
 AVFileType type=nil;if([dest.pathExtension.lowercaseString isEqual:@"mov"]&&[session.supportedFileTypes containsObject:AVFileTypeQuickTimeMovie])type=AVFileTypeQuickTimeMovie;else if([session.supportedFileTypes containsObject:AVFileTypeMPEG4])type=AVFileTypeMPEG4;if(!type){fail(@"没有兼容的视频输出格式");return nil;}
 NSError *dirError=nil;if(![NSFileManager.defaultManager createDirectoryAtURL:dest.URLByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:&dirError]){dispatch_async(dispatch_get_main_queue(),^{completion(dirError);});return nil;}
 session.outputURL=dest;session.outputFileType=type;session.videoComposition=composition;session.shouldOptimizeForNetworkUse=YES;
 // Export the full asset, not a video-only mutable composition: retain audio.
 [session exportAsynchronouslyWithCompletionHandler:^{NSError *error=session.status==AVAssetExportSessionStatusCompleted?nil:(session.error?:WMError(session.status==AVAssetExportSessionStatusCancelled?@"导出已取消，原片已保留":@"视频导出失败，原片已保留"));dispatch_async(dispatch_get_main_queue(),^{completion(error);});}];return session;
}
- (BOOL)importTemplateURL:(NSURL *)url error:(NSError **)error {
 BOOL scoped=[url startAccessingSecurityScopedResource];BOOL ok=NO;NSMutableArray<NSURL *> *written=[NSMutableArray array];NSError *failure=nil;
 do {
 NSDictionary *info=[url resourceValuesForKeys:@[NSURLFileSizeKey,NSURLIsRegularFileKey,NSURLIsSymbolicLinkKey] error:&failure];NSNumber *size=info[NSURLFileSizeKey];if(!url.isFileURL||![info[NSURLIsRegularFileKey] boolValue]||[info[NSURLIsSymbolicLinkKey] boolValue]||!size||size.unsignedLongLongValue>32*1024*1024){failure=WMError(@"模板须为不超过32MB的本地 JSON 文件");break;}
 NSData *data=[NSData dataWithContentsOfURL:url options:NSDataReadingMappedIfSafe error:&failure];if(!data||data.length>32*1024*1024)break;
 id json=[NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingMutableContainers error:&failure];if(![json isKindOfClass:NSDictionary.class]){failure=WMError(@"模板 JSON 根节点无效");break;}
 // Backups use {schemaVersion:1,settings:{...},assets:{filename:base64PNG}}.
 if(json[@"schemaVersion"]&&(![json[@"schemaVersion"] isKindOfClass:NSNumber.class]||[json[@"schemaVersion"] doubleValue]!=1)){failure=WMError(@"不支持此备份版本");break;}
 id raw=json[@"settings"]?:json;if(!ValidSettings(raw)){failure=WMError(@"模板版本、图层或参数无效");break;}
 id assets=json[@"assets"]?:@{};if(![assets isKindOfClass:NSDictionary.class]||[assets count]>80){failure=WMError(@"图片资源表无效");break;}
 NSMutableDictionary *images=[NSMutableDictionary dictionary];NSUInteger total=0;double decodedPixels=0;
 for(id name in assets){id encoded=assets[name];if(!SafeName(name)||![encoded isKindOfClass:NSString.class]||[encoded length]>16*1024*1024){failure=WMError(@"不安全的图片名称或图片过大");break;}NSData *bytes=[[NSData alloc] initWithBase64EncodedString:encoded options:0];total+=bytes.length;UIImage *im=Decode(bytes);decodedPixels+=im.size.width*im.size.height;if(!im||total>24*1024*1024||decodedPixels>24000000){failure=WMError(@"图片无效、像素超限或资源总量超过24MB");break;}images[name]=im;}
 if(failure)break;
 NSURL *base=[[self documentsURL] URLByAppendingPathComponent:@"assets" isDirectory:YES];NSString *expected=[[self documentsURL].URLByResolvingSymlinksInPath.path stringByAppendingPathComponent:@"assets"];if(![base.URLByResolvingSymlinksInPath.path isEqual:expected]){failure=WMError(@"资源目录不能是外部符号链接");break;}
 if(![NSFileManager.defaultManager createDirectoryAtURL:base withIntermediateDirectories:YES attributes:nil error:&failure])break;
 NSMutableDictionary *map=[NSMutableDictionary dictionary];for(NSString *old in images){NSString *name=[NSString stringWithFormat:@"import-%@.png",NSUUID.UUID.UUIDString];NSURL *u=[base URLByAppendingPathComponent:name];NSData *png=UIImagePNGRepresentation(images[old]);if(!png||![png writeToURL:u options:NSDataWritingAtomic error:&failure]){failure=failure?:WMError(@"无法写入图片资源");break;}map[old]=name;[written addObject:u];}if(failure)break;
 NSMutableDictionary *next=[self defaults];[next addEntriesFromDictionary:raw];NSMutableArray *all=[NSMutableArray arrayWithArray:next[@"layers"]];for(NSDictionary *t in next[@"userTemplates"])[all addObjectsFromArray:t[@"layers"]];for(NSMutableDictionary *l in all){NSString *old=l[@"asset"];if(old&&map[old])l[@"asset"]=map[old];else if(old&&![self imageForLayer:l]){failure=WMError(@"模板引用了未包含且不存在的图片");break;}}if(failure)break;
 NSData *out=[NSJSONSerialization dataWithJSONObject:next options:0 error:&failure];if(!out||![out writeToURL:[[self documentsURL] URLByAppendingPathComponent:@"settings.json"] options:NSDataWritingAtomic error:&failure])break;
 @synchronized(self){self.settings=[NSJSONSerialization JSONObjectWithData:out options:NSJSONReadingMutableContainers error:nil];}ok=YES;
 }while(NO);
 if(!ok){for(NSURL *u in written)[NSFileManager.defaultManager removeItemAtURL:u error:nil];if(error)*error=failure?:WMError(@"模板读取失败");}if(scoped)[url stopAccessingSecurityScopedResource];return ok;
}
- (NSURL *)exportTemplate:(NSError **)error {
 NSDictionary *s=[self snapshot];if(!ValidSettings(s)){if(error)*error=WMError(@"当前模板数据无效");return nil;}
 NSMutableDictionary *assets=[NSMutableDictionary dictionary];NSMutableArray *layers=[NSMutableArray arrayWithArray:s[@"layers"]];for(NSDictionary *t in s[@"userTemplates"])[layers addObjectsFromArray:t[@"layers"]];NSUInteger total=0;
 for(NSDictionary *l in layers){NSString *name=l[@"asset"];if(!name||assets[name])continue;UIImage *im=[self imageForLayer:l];if(!im){if(error)*error=WMError(@"图片缺失，不能生成完整备份");return nil;}NSData *png=UIImagePNGRepresentation(im);total+=png.length;if(!png||png.length>12*1024*1024||total>24*1024*1024){if(error)*error=WMError(@"备份图片总量超过限制");return nil;}assets[name]=[png base64EncodedStringWithOptions:0];}
 NSData *data=[NSJSONSerialization dataWithJSONObject:@{@"schemaVersion":@1,@"settings":s,@"assets":assets} options:NSJSONWritingPrettyPrinted error:error];if(!data)return nil;if(data.length>32*1024*1024){if(error)*error=WMError(@"备份文件超过32MB");return nil;}
 NSURL *dir=[[self documentsURL] URLByAppendingPathComponent:@"Exports" isDirectory:YES];if(![NSFileManager.defaultManager createDirectoryAtURL:dir withIntermediateDirectories:YES attributes:nil error:error])return nil;NSURL *url=[dir URLByAppendingPathComponent:[NSString stringWithFormat:@"MarkCam-%@.json",NSUUID.UUID.UUIDString]];return [data writeToURL:url options:NSDataWritingAtomic error:error]?url:nil;
}
@end
