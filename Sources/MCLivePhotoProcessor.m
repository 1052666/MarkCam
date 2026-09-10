#import "MCLivePhotoProcessor.h"
#import "WMEngine.h"
#import <AVFoundation/AVFoundation.h>
#import <Photos/Photos.h>
#import <ImageIO/ImageIO.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

static NSError *LPErr(NSString *message) {return [NSError errorWithDomain:@"MarkCam.LivePhoto" code:1 userInfo:@{NSLocalizedDescriptionKey:message}];}
static NSString *LPIdentifier(NSDictionary *props) {id maker=props[(__bridge NSString *)kCGImagePropertyMakerAppleDictionary];if(![maker isKindOfClass:NSDictionary.class])return nil;id value=maker[@"17"];return [value isKindOfClass:NSString.class]?value:nil;}
@interface MCLivePhotoProcessor ()
@property(atomic,readwrite) float progress;
@property(atomic) BOOL cancelled;
@property(nonatomic,strong) dispatch_queue_t queue;
@property(nonatomic,strong) dispatch_source_t deadline;
@property(nonatomic,strong) AVAssetReader *reader;
@property(nonatomic,strong) AVAssetWriter *writer;
@property(nonatomic,copy) void (^completion)(NSError *);
@property(nonatomic,strong) NSURL *outputPhoto;
@property(nonatomic,strong) NSURL *outputMovie;
@property(nonatomic) BOOL finished;
@property(nonatomic) NSInteger streamsRemaining;
@property(nonatomic) double duration;
@property(nonatomic) PHLivePhotoRequestID liveRequest;
@end
@implementation MCLivePhotoProcessor
- (instancetype)init {if((self=[super init])){_queue=dispatch_queue_create("markcam.live.process",DISPATCH_QUEUE_SERIAL);_liveRequest=PHLivePhotoRequestIDInvalid;}return self;}
- (void)cancel {self.cancelled=YES;dispatch_async(self.queue,^{[self finish:LPErr(@"实况合成已取消，原始照片和动态片段均已保留。")];});}
- (void)finish:(NSError *)error {
 if(self.finished)return;self.finished=YES;
 if(self.deadline){dispatch_source_cancel(self.deadline);self.deadline=nil;}
 if(error){[self.reader cancelReading];[self.writer cancelWriting];}
 PHLivePhotoRequestID request=self.liveRequest;self.liveRequest=PHLivePhotoRequestIDInvalid;
 if(request!=PHLivePhotoRequestIDInvalid)dispatch_async(dispatch_get_main_queue(),^{[PHLivePhoto cancelLivePhotoRequestWithRequestID:request];});
 void (^done)(NSError *)=self.completion;self.completion=nil;self.reader=nil;self.writer=nil;
 if(!error)self.progress=1;
 if(done)dispatch_async(dispatch_get_main_queue(),^{done(error);});
}
- (void)processPhoto:(NSURL *)photo movie:(NSURL *)movie outputPhoto:(NSURL *)outputPhoto outputMovie:(NSURL *)outputMovie settings:(NSDictionary *)settings date:(NSDate *)date completion:(void (^)(NSError *))completion {
 self.completion=completion;self.outputPhoto=outputPhoto;self.outputMovie=outputMovie;
 dispatch_async(self.queue,^{@autoreleasepool {
  if(self.cancelled){[self finish:LPErr(@"实况处理已取消")];return;}
  self.deadline=dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER,0,0,self.queue);dispatch_source_set_timer(self.deadline,dispatch_time(DISPATCH_TIME_NOW,120*NSEC_PER_SEC),DISPATCH_TIME_FOREVER,NSEC_PER_SEC);
  __weak typeof(self) weak=self;dispatch_source_set_event_handler(self.deadline,^{[weak finish:LPErr(@"实况合成超时，原片保留，可稍后重试。")];});dispatch_resume(self.deadline);
  @try {[self preparePhoto:photo movie:movie settings:settings date:date];}
  @catch(NSException *exception){[self finish:LPErr([NSString stringWithFormat:@"实况处理异常：%@",exception.reason?:exception.name])];}
 }});
}
- (void)preparePhoto:(NSURL *)photo movie:(NSURL *)movie settings:(NSDictionary *)settings date:(NSDate *)date {
 for(NSURL *u in @[photo,movie,self.outputPhoto,self.outputMovie])if(!u.isFileURL){[self finish:LPErr(@"实况资源必须是本地文件")];return;}
 if([photo.path isEqual:self.outputPhoto.path]||[movie.path isEqual:self.outputMovie.path]){[self finish:LPErr(@"实况输出不能覆盖原片")];return;}
 if([NSFileManager.defaultManager fileExistsAtPath:self.outputPhoto.path]||[NSFileManager.defaultManager fileExistsAtPath:self.outputMovie.path]){[self finish:LPErr(@"实况输出已存在，请清理未完成的输出后重试")];return;}
 CGImageSourceRef src=CGImageSourceCreateWithURL((__bridge CFURLRef)photo,NULL);if(!src){[self finish:LPErr(@"实况照片不可读取")];return;}
 NSDictionary *props=CFBridgingRelease(CGImageSourceCopyPropertiesAtIndex(src,0,NULL));CFRelease(src);
 NSString *identifier=LPIdentifier(props);
 if(![identifier isKindOfClass:NSString.class]||identifier.length<1||identifier.length>128){[self finish:LPErr(@"原始照片缺少 Live Photo 配对标识，未降级保存为普通照片。")];return;}
 AVURLAsset *asset=[AVURLAsset URLAssetWithURL:movie options:@{AVURLAssetPreferPreciseDurationAndTimingKey:@YES}];
 NSString *movieID=nil;for(AVMetadataItem *m in asset.metadata)if([m.identifier isEqual:AVMetadataIdentifierQuickTimeMetadataContentIdentifier]){movieID=m.stringValue;break;}
 if(![movieID isEqual:identifier]){[self finish:LPErr(@"原始照片与动态片段的配对标识不一致")];return;}
 self.duration=CMTimeGetSeconds(asset.duration);if(!isfinite(self.duration)||self.duration<=0||self.duration>10){[self finish:LPErr(@"实况动态片段时长无效")];return;}
 AVAssetTrack *video=[asset tracksWithMediaType:AVMediaTypeVideo].firstObject;if(!video){[self finish:LPErr(@"实况资源没有视频轨道")];return;}
 BOOL hasStillTime=NO;for(AVAssetTrack *t in [asset tracksWithMediaType:AVMediaTypeMetadata])for(id fmt in t.formatDescriptions){NSArray *ids=(__bridge NSArray *)CMMetadataFormatDescriptionGetIdentifiers((__bridge CMFormatDescriptionRef)fmt);for(NSString *key in ids)if([key containsString:@"com.apple.quicktime.still-image-time"])hasStillTime=YES;}
 if(!hasStillTime){[self finish:LPErr(@"实况动态片段缺少主照片时间轨道")];return;}
 CGFloat width=[props[(__bridge NSString *)kCGImagePropertyPixelWidth]doubleValue],height=[props[(__bridge NSString *)kCGImagePropertyPixelHeight]doubleValue];
 if(!isfinite(width)||!isfinite(height)||width<1||height<1||width*height>64000000){[self finish:LPErr(@"实况主照片像素尺寸无效或过大")];return;}
 if(self.cancelled){[self finish:LPErr(@"实况处理已取消")];return;}
 UIImage *image=nil,*result=nil;@autoreleasepool {
 image=[UIImage imageWithContentsOfFile:photo.path];result=image?[[WMEngine shared]processPhoto:image settings:settings date:date]:nil;
 }
 if(!result.CGImage){[self finish:LPErr(@"实况主照片调色或水印合成失败")];return;}
 // Preserve the native Apple pairing ID, but do not carry stale thumbnail/orientation.
 NSMutableData *jpeg=[NSMutableData data];CGImageDestinationRef dest=CGImageDestinationCreateWithData((__bridge CFMutableDataRef)jpeg,(__bridge CFStringRef)UTTypeJPEG.identifier,1,NULL);
 if(!dest){[self finish:LPErr(@"无法编码实况主照片")];return;}
 NSDictionary *metadata=@{(__bridge NSString *)kCGImagePropertyMakerAppleDictionary:@{@"17":identifier},(__bridge NSString *)kCGImagePropertyOrientation:@1,(__bridge NSString *)kCGImageDestinationLossyCompressionQuality:@.96};
 CGImageDestinationAddImage(dest,result.CGImage,(__bridge CFDictionaryRef)metadata);BOOL ok=CGImageDestinationFinalize(dest);CFRelease(dest);
 NSError *error=nil;if(!ok||![jpeg writeToURL:self.outputPhoto options:NSDataWritingAtomic error:&error]){[self finish:error?:LPErr(@"实况主照片写入失败")];return;}
 // Re-read pairing identity; do not rely only on intended writer settings.
 src=CGImageSourceCreateWithURL((__bridge CFURLRef)self.outputPhoto,NULL);NSDictionary *check=src?CFBridgingRelease(CGImageSourceCopyPropertiesAtIndex(src,0,NULL)):nil;if(src)CFRelease(src);
 if(![LPIdentifier(check) isEqual:identifier]){[self finish:LPErr(@"实况照片配对信息编码校验失败")];return;}
 self.progress=.15;if(self.cancelled){[self finish:LPErr(@"实况处理已取消")];return;}[self prepareMovie:asset video:video settings:settings date:date];
}
- (void)prepareMovie:(AVURLAsset *)asset video:(AVAssetTrack *)video settings:(NSDictionary *)settings date:(NSDate *)date {
 NSError *error=nil;self.reader=[[AVAssetReader alloc]initWithAsset:asset error:&error];self.writer=[[AVAssetWriter alloc]initWithURL:self.outputMovie fileType:AVFileTypeQuickTimeMovie error:&error];if(!self.reader||!self.writer){[self finish:error?:LPErr(@"无法创建实况视频处理器")];return;}
 CGRect transformed=CGRectApplyAffineTransform((CGRect){CGPointZero,video.naturalSize},video.preferredTransform);CGSize size=CGSizeMake(fabs(transformed.size.width),fabs(transformed.size.height));
 if(!isfinite(size.width)||!isfinite(size.height)||size.width<2||size.height<2||size.width>4096||size.height>4096){[self finish:LPErr(@"实况视频尺寸超出处理范围")];return;}
 size.width=floor(size.width/2)*2;size.height=floor(size.height/2)*2;
 UIImage *overlayImage=[[WMEngine shared]overlayForSize:size settings:settings date:date];CIImage *overlay=[CIImage imageWithCGImage:overlayImage.CGImage];CIContext *context=[CIContext contextWithOptions:@{kCIContextCacheIntermediates:@NO}];
 AVVideoComposition *composition=[AVVideoComposition videoCompositionWithAsset:asset applyingCIFiltersWithHandler:^(AVAsynchronousCIImageFilteringRequest *request){@autoreleasepool{
  CIImage *frame=request.sourceImage;CGRect extent=frame.extent;CGSize render=request.renderSize;
  if(CGRectIsInfinite(extent)||CGRectIsEmpty(extent)||render.width<1||render.height<1){[request finishWithError:LPErr(@"实况画面尺寸无效")];return;}
  // AVFoundation applies preferredTransform; never rotate/mirror this a second time.
  frame=[frame imageByApplyingTransform:CGAffineTransformMakeTranslation(-extent.origin.x,-extent.origin.y)];frame=[frame imageByApplyingTransform:CGAffineTransformMakeScale(render.width/extent.size.width,render.height/extent.size.height)];
  CIImage *mark=[overlay imageByApplyingTransform:CGAffineTransformMakeScale(render.width/size.width,render.height/size.height)];
  CIImage *out=[[mark imageByCompositingOverImage:[[WMEngine shared]applyTone:frame settings:settings]]imageByCroppingToRect:(CGRect){CGPointZero,render}];[request finishWithImage:out context:context];
 }}];
 AVAssetReaderVideoCompositionOutput *frames=[[AVAssetReaderVideoCompositionOutput alloc]initWithVideoTracks:@[video] videoSettings:@{(NSString *)kCVPixelBufferPixelFormatTypeKey:@(kCVPixelFormatType_32BGRA)}];frames.videoComposition=composition;frames.alwaysCopiesSampleData=NO;
 NSDictionary *compression=@{AVVideoAverageBitRateKey:@10000000,AVVideoExpectedSourceFrameRateKey:@(MAX(1,video.nominalFrameRate))};
 AVAssetWriterInput *v=[AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeVideo outputSettings:@{AVVideoCodecKey:AVVideoCodecTypeH264,AVVideoWidthKey:@(size.width),AVVideoHeightKey:@(size.height),AVVideoCompressionPropertiesKey:compression}];v.expectsMediaDataInRealTime=NO;v.transform=CGAffineTransformIdentity;
 if(![self.reader canAddOutput:frames]||![self.writer canAddInput:v]){[self finish:LPErr(@"设备无法合成实况画面")];return;}
 [self.reader addOutput:frames];[self.writer addInput:v];NSMutableArray *pairs=[NSMutableArray arrayWithObject:@{ @"output":frames,@"input":v,@"video":@YES }];NSMutableDictionary<NSNumber *,AVAssetWriterInput *> *inputs=[NSMutableDictionary dictionaryWithObject:v forKey:@(video.trackID)];
 // Preserve native QuickTime content identifier and every timed metadata track.
 // In particular, do NOT use ordinary AVAssetExportSession which may discard
 // com.apple.quicktime.still-image-time and silently produce a plain movie.
 self.writer.metadata=asset.metadata;
 for(AVAssetTrack *track in asset.tracks){
  if(![track.mediaType isEqual:AVMediaTypeAudio]&&![track.mediaType isEqual:AVMediaTypeMetadata])continue;
  if(track.formatDescriptions.count==0){[self finish:LPErr(@"实况音频或元数据轨道格式缺失")];return;}
  CMFormatDescriptionRef format=(__bridge CMFormatDescriptionRef)track.formatDescriptions.firstObject;
  AVAssetReaderTrackOutput *o=[AVAssetReaderTrackOutput assetReaderTrackOutputWithTrack:track outputSettings:nil];o.alwaysCopiesSampleData=NO;
  AVAssetWriterInput *i=[AVAssetWriterInput assetWriterInputWithMediaType:track.mediaType outputSettings:nil sourceFormatHint:format];i.expectsMediaDataInRealTime=NO;i.metadata=track.metadata;
  if(![self.reader canAddOutput:o]||![self.writer canAddInput:i]){[self finish:LPErr(@"无法保留实况音频或配对时间轨道")];return;}
  [self.reader addOutput:o];[self.writer addInput:i];inputs[@(track.trackID)]=i;[pairs addObject:@{@"output":o,@"input":i,@"video":@NO}];
 }
 for(AVAssetTrack *track in asset.tracks){AVAssetWriterInput *from=inputs[@(track.trackID)];if(!from)continue;for(NSString *type in track.availableTrackAssociationTypes)for(AVAssetTrack *associated in [track associatedTracksOfType:type]){AVAssetWriterInput *to=inputs[@(associated.trackID)];if(!to)continue;if(![from canAddTrackAssociationWithTrackOfInput:to type:type]){[self finish:LPErr(@"无法保留实况元数据轨道关联")];return;}[from addTrackAssociationWithTrackOfInput:to type:type];}}
 if(![self.writer startWriting]||![self.reader startReading]){[self finish:self.writer.error?:self.reader.error?:LPErr(@"实况视频处理无法开始")];return;}
 [self.writer startSessionAtSourceTime:kCMTimeZero];self.streamsRemaining=pairs.count;
 for(NSDictionary *pair in pairs)[self pump:pair[@"output"] input:pair[@"input"] isVideo:[pair[@"video"]boolValue]];
}
- (void)pump:(AVAssetReaderOutput *)output input:(AVAssetWriterInput *)input isVideo:(BOOL)video {
 __weak typeof(self) weak=self;__weak AVAssetWriterInput *weakInput=input;__block BOOL ended=NO;
 [input requestMediaDataWhenReadyOnQueue:self.queue usingBlock:^{@autoreleasepool{
  MCLivePhotoProcessor *strong=weak;AVAssetWriterInput *writerInput=weakInput;if(!strong||!writerInput||ended||strong.finished)return;
  @try {
   while(writerInput.isReadyForMoreMediaData&&!strong.finished){
    if(strong.cancelled){[strong finish:LPErr(@"实况处理已取消，原片已保留")];return;}
    CMSampleBufferRef sample=[output copyNextSampleBuffer];
    if(!sample){ended=YES;[writerInput markAsFinished];if(strong.reader.status==AVAssetReaderStatusFailed){[strong finish:strong.reader.error?:LPErr(@"读取实况轨道失败")];return;}[strong streamFinished];return;}
    CMTime time=CMSampleBufferGetPresentationTimeStamp(sample);BOOL ok=[writerInput appendSampleBuffer:sample];CFRelease(sample);
    if(!ok){[strong finish:strong.writer.error?:LPErr(@"写入实况轨道失败")];return;}
    if(video){double sec=CMTimeGetSeconds(time);if(isfinite(sec))strong.progress=MIN(.9,.15+.75*MAX(0,sec)/strong.duration);}
   }
  }@catch(NSException *e){[strong finish:LPErr([NSString stringWithFormat:@"实况轨道处理异常：%@",e.reason?:e.name])];}
 }}];
}
- (void)streamFinished {
 if(--self.streamsRemaining!=0||self.finished)return;
 [self.writer endSessionAtSourceTime:CMTimeMakeWithSeconds(self.duration,60000)];
 [self.writer finishWritingWithCompletionHandler:^{dispatch_async(self.queue,^{if(self.finished)return;if(self.writer.status!=AVAssetWriterStatusCompleted){[self finish:self.writer.error?:LPErr(@"实况文件未完成")];return;}[self validatePair];});}];
}
- (void)validatePair {
 self.progress=.95;
 dispatch_async(dispatch_get_main_queue(),^{
  if(self.cancelled){dispatch_async(self.queue,^{[self finish:LPErr(@"实况处理已取消")];});return;}
  PHLivePhotoRequestID request=[PHLivePhoto requestLivePhotoWithResourceFileURLs:@[self.outputPhoto,self.outputMovie] placeholderImage:nil targetSize:CGSizeMake(240,240) contentMode:PHImageContentModeAspectFit resultHandler:^(PHLivePhoto *live,NSDictionary *info){
   if([info[PHLivePhotoInfoIsDegradedKey]boolValue])return;
   NSError *error=info[PHLivePhotoInfoErrorKey];if(!live&&!error)error=LPErr(@"系统未识别合成结果为 Live Photo，原片保留。不会当普通照片保存。");
   dispatch_async(self.queue,^{self.liveRequest=PHLivePhotoRequestIDInvalid;[self finish:error];});
  }];
  dispatch_async(self.queue,^{if(self.finished){dispatch_async(dispatch_get_main_queue(),^{[PHLivePhoto cancelLivePhotoRequestWithRequestID:request];});}else self.liveRequest=request;});
 });
}
@end
