#import "MCPhotoRenderer.h"
#import "WMEngine.h"
#import <CoreImage/CoreImage.h>
#import <ImageIO/ImageIO.h>
#import <os/proc.h>
static NSError *PRError(NSString *s){return [NSError errorWithDomain:@"MarkCam.Render" code:1 userInfo:@{NSLocalizedDescriptionKey:s}];}
@implementation MCPhotoRenderer
+ (BOOL)renderSource:(NSURL *)source destination:(NSURL *)destination settings:(NSDictionary *)settings date:(NSDate *)date error:(NSError **)error {
 @autoreleasepool {
  if(!source.isFileURL||!destination.isFileURL||[source.URLByResolvingSymlinksInPath.path isEqual:destination.URLByResolvingSymlinksInPath.path]){if(error)*error=PRError(@"照片输出路径无效");return NO;}
  NSURL *partial=[destination URLByAppendingPathExtension:@"partial.jpg"];
  [NSFileManager.defaultManager removeItemAtURL:partial error:nil];
  CIContext *context=nil;BOOL ok=NO;
  @try {
   CGImageSourceRef src=CGImageSourceCreateWithURL((__bridge CFURLRef)source,(__bridge CFDictionaryRef)@{(__bridge NSString *)kCGImageSourceShouldCache:@NO});
   NSDictionary *props=src?CFBridgingRelease(CGImageSourceCopyPropertiesAtIndex(src,0,NULL)):nil;if(src)CFRelease(src);
   double width=[props[(__bridge NSString *)kCGImagePropertyPixelWidth]doubleValue],height=[props[(__bridge NSString *)kCGImagePropertyPixelHeight]doubleValue];
   if(width<1||height<1||!isfinite(width*height)||width*height>64000000){if(error)*error=PRError(@"原片尺寸无效");return NO;}
   uint64_t free=os_proc_available_memory();uint64_t estimate=(uint64_t)(width*height*16)+80ULL*1024*1024;
   if(free&&free<estimate){if(error)*error=PRError(@"可用内存不足，原片保留，稍后在待保存重试");return NO;}
   CIImage *input=[CIImage imageWithContentsOfURL:source options:@{kCIImageApplyOrientationProperty:@YES}];
   if(!input||CGRectIsEmpty(input.extent)||CGRectIsInfinite(input.extent)){if(error)*error=PRError(@"无法读取原片");return NO;}
   CGRect extent=input.extent;input=[input imageByApplyingTransform:CGAffineTransformMakeTranslation(-extent.origin.x,-extent.origin.y)];CGSize size=extent.size;
   CIImage *output=[[WMEngine shared]applyTone:input settings:settings];
   if([settings[@"watermarkEnabled"]boolValue]){
    // Cap only the overlay canvas, not the captured photo. This reduces full-size
    // transparent raster memory, at a documented fine-text sharpness trade-off.
    CGFloat scale=MIN(1,2048./MAX(size.width,size.height));CGSize small=CGSizeMake(MAX(1,round(size.width*scale)),MAX(1,round(size.height*scale)));
    UIImage *stamp=[[WMEngine shared]overlayForSize:small settings:settings date:date];
    if(!stamp.CGImage){if(error)*error=PRError(@"水印合成失败");return NO;}
    CIImage *overlay=[[CIImage imageWithCGImage:stamp.CGImage]imageByApplyingTransform:CGAffineTransformMakeScale(size.width/small.width,size.height/small.height)];output=[overlay imageByCompositingOverImage:output];
   }
   NSMutableDictionary *metadata=[NSMutableDictionary dictionaryWithObject:@1 forKey:(__bridge NSString *)kCGImagePropertyOrientation];
   id maker=props[(__bridge NSString *)kCGImagePropertyMakerAppleDictionary];id pair=[maker isKindOfClass:NSDictionary.class]?maker[@"17"]:nil;
   if([pair isKindOfClass:NSString.class])metadata[(__bridge NSString *)kCGImagePropertyMakerAppleDictionary]=@{@"17":pair};
   output=[[output imageByCroppingToRect:(CGRect){CGPointZero,size}]imageBySettingProperties:metadata];
   context=[CIContext contextWithOptions:@{kCIContextCacheIntermediates:@NO,kCIContextWorkingFormat:@(kCIFormatRGBA8),kCIContextPriorityRequestLow:@YES,kCIContextName:@"MarkCam queued photo"}];
   CGColorSpaceRef color=CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
   if(pair){
    // ImageIO writes Apple MakerNote pairing explicitly. A deferred CGImage avoids
    // storing a UIImage plus full JPEG NSData alongside both source and output.
    CGImageRef deferred=[context createCGImage:output fromRect:output.extent format:kCIFormatRGBA8 colorSpace:color deferred:YES];
    CGImageDestinationRef writer=deferred?CGImageDestinationCreateWithURL((__bridge CFURLRef)partial,CFSTR("public.jpeg"),1,NULL):NULL;
    if(writer){NSMutableDictionary *properties=[metadata mutableCopy];properties[(__bridge NSString *)kCGImageDestinationLossyCompressionQuality]=@.94;CGImageDestinationAddImage(writer,deferred,(__bridge CFDictionaryRef)properties);ok=CGImageDestinationFinalize(writer);CFRelease(writer);}
    if(deferred)CGImageRelease(deferred);if(!ok&&error)*error=PRError(@"实况主照片文件编码失败");
   }else ok=[context writeJPEGRepresentationOfImage:output toURL:partial colorSpace:color options:@{(__bridge NSString *)kCGImageDestinationLossyCompressionQuality:@.94} error:error];
   CGColorSpaceRelease(color);
   if(ok){ // Verify metadata and dimensions from disk before making ready visible.
    CGImageSourceRef check=CGImageSourceCreateWithURL((__bridge CFURLRef)partial,NULL);NSDictionary *p=check?CFBridgingRelease(CGImageSourceCopyPropertiesAtIndex(check,0,NULL)):nil;if(check)CFRelease(check);
    ok=p&&[p[(__bridge NSString *)kCGImagePropertyPixelWidth]integerValue]==(NSInteger)size.width&&[p[(__bridge NSString *)kCGImagePropertyPixelHeight]integerValue]==(NSInteger)size.height;
    if(pair){id m=p[(__bridge NSString *)kCGImagePropertyMakerAppleDictionary];ok=ok&&[m isKindOfClass:NSDictionary.class]&&[m[@"17"]isEqual:pair];}
    if(!ok&&error)*error=PRError(@"照片编码/实况配对校验失败，原片保留");
   }
   if(ok)ok=[NSFileManager.defaultManager moveItemAtURL:partial toURL:destination error:error];
  }@catch(NSException *e){if(error)*error=PRError(e.reason?:@"照片处理异常");ok=NO;}
  @finally{[context clearCaches];if(!ok)[NSFileManager.defaultManager removeItemAtURL:partial error:nil];}
  return ok;
 }
}
@end
