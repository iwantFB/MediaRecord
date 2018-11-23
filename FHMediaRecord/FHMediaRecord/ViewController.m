//
//  ViewController.m
//  FHMediaRecord
//
//  Created by 胡斐 on 2018/11/20.
//  Copyright © 2018年 jackson. All rights reserved.
//

#import "ViewController.h"
#import <AVFoundation/AVFoundation.h>
#import <MediaPlayer/MediaPlayer.h>

#define VIDEO_FILEPATH @"video"
#define ScreenWidth [UIScreen mainScreen].bounds.size.width
#define ScreenHeight [UIScreen mainScreen].bounds.size.height
#define iSiPhoneX ([UIScreen instancesRespondToSelector:@selector(currentMode)] ? CGSizeEqualToSize(CGSizeMake(1125, 2436), [[UIScreen mainScreen] currentMode].size) : NO)

///用来修改某个输入设备
typedef void(^PropertyChangeBlock)(AVCaptureDevice *captureDevice);

@interface ViewController ()<AVCaptureAudioDataOutputSampleBufferDelegate,AVCaptureVideoDataOutputSampleBufferDelegate>

@property (strong, nonatomic) AVCaptureDeviceInput       *backCameraInput;//后置摄像头输入
@property (strong, nonatomic) AVCaptureDeviceInput       *frontCameraInput;//前置摄像头输入
@property (strong, nonatomic) AVCaptureDeviceInput       *videoInput;//记录摄像头输入
@property (strong, nonatomic) AVCaptureDeviceInput       *audioMicInput;//麦克风输入

@property (copy  , nonatomic) dispatch_queue_t           videoQueue;//录制的队列
@property (strong, nonatomic) AVCaptureConnection        *audioConnection;//音频录制连接
@property (strong, nonatomic) AVCaptureConnection        *videoConnection;//视频录制连接

@property (strong, nonatomic) AVCaptureStillImageOutput *captureStillImageOutput;        //照片输出流

@property (nonatomic, assign) UIDeviceOrientation shootingOrientation;

@property (nonatomic, strong) AVAssetWriter *assetWriter;
@property (nonatomic, strong) AVAssetWriterInput *assetWriterVideoInput;
@property (nonatomic, strong) AVAssetWriterInput *assetWriterAudioInput;
@property (nonatomic, strong) NSDictionary *videoCompressionSettings;
@property (nonatomic, strong) NSDictionary *audioCompressionSettings;

@end

@implementation ViewController
{
    AVCaptureVideoPreviewLayer *_previewLayer;
    AVCaptureSession *_captureSession;
    
    AVCaptureAudioDataOutput *_audioDataOutput;
    AVCaptureVideoDataOutput *_videoDataOutput;
    
    NSURL *_fileURL;
    
    CMTime _startTimestamp;
    CMTime _timeOffset;
    CMTime _maximumCaptureDuration;
    CMTime _lastVideo;
    CMTime _lastAudio;
    
    BOOL _isRotating;
    BOOL _isPaused;
    BOOL _isVideoRecord;
    BOOL _interrupted;
}
- (void)viewDidLoad {
    [super viewDidLoad];
    
    [self _configurationData];
    [self _configUI];
}

#pragma mark- action
- (IBAction)startRecord:(UIButton *)sender {
    _isVideoRecord = YES;
    _isPaused = NO;
}

- (IBAction)pauseRecord:(id)sender {
    
    _interrupted = YES;
    _isPaused = YES;
}

- (IBAction)resumeRecoed:(id)sender {
    _isPaused = NO;
    
}

- (IBAction)changeFlash:(id)sender {
    
    __weak AVAssetWriter *weakWriter = _assetWriter;
    __weak ViewController *weakSelf = self;
    [_assetWriter finishWritingWithCompletionHandler:^{
        if(weakWriter.error){
            NSLog(@"看看%@",weakWriter.error.localizedDescription);
        }else{
            [self exportAsset];
        }
    }];
}

- (IBAction)changeCamera:(id)sender {
    
    AVCaptureDeviceInput *targetDeviceInput = _videoInput == self.frontCameraInput ?
    _backCameraInput : _frontCameraInput;
    [self changePositionCameraForDeviceInput:targetDeviceInput];
    
}
- (IBAction)takePic:(id)sender {
    
    if(_isVideoRecord)return;
    //根据设备输出获得连接
    AVCaptureConnection *captureConnection = [self.captureStillImageOutput connectionWithMediaType:AVMediaTypeVideo];
    
    //根据连接取得设备输出的数据
    [self.captureStillImageOutput captureStillImageAsynchronouslyFromConnection:captureConnection completionHandler:^(CMSampleBufferRef imageDataSampleBuffer, NSError *error) {
        if (imageDataSampleBuffer)
        {
            NSData *imageData = [AVCaptureStillImageOutput jpegStillImageNSDataRepresentation:imageDataSampleBuffer];
            UIImage *image = [UIImage imageWithData:imageData];
            
            UIImageWriteToSavedPhotosAlbum(image, nil, nil, nil);
        }
    }];
    [self changeDeviceProperty:^(AVCaptureDevice *captureDevice) {
        
    }];
}

#pragma mark- AVCaptureAudioDataOutputSampleBufferDelegate,AVCaptureVideoDataOutputSampleBufferDelegate
- (void)captureOutput:(AVCaptureOutput *)output didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer fromConnection:(AVCaptureConnection *)connection
{
    if(_isRotating || _isPaused)return;
    
    if (!CMSampleBufferDataIsReady(sampleBuffer))return;
    
    if(!_assetWriter)return;
    
    @autoreleasepool {
        
        CMTime currentTimestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer);
        BOOL isVideo = (output == _videoDataOutput);
        ///暂停过，计算时间偏差
        if(_interrupted){
            if (isVideo) {
                
                return;
            }
            
            // calculate the appropriate time offset
            if (CMTIME_IS_VALID(currentTimestamp) && CMTIME_IS_VALID(_lastAudio)) {
                if (CMTIME_IS_VALID(_timeOffset)) {
                    currentTimestamp = CMTimeSubtract(currentTimestamp, _timeOffset);
                }
                
                CMTime offset = CMTimeSubtract(currentTimestamp, _lastAudio);
                _timeOffset = CMTIME_IS_INVALID(_timeOffset) ? offset : CMTimeAdd(_timeOffset, offset);
            }
            _interrupted = NO;
        }
        
        
        if (_timeOffset.value > 0) {
            
            //根据得到的timeOffset调整
            sampleBuffer = [self adjustTime:sampleBuffer by:_timeOffset];
        }
        
        CMTime pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer);
        CMTime dur = CMSampleBufferGetDuration(sampleBuffer);
        if (dur.value > 0) {
            pts = CMTimeAdd(pts, dur);
        }
        if (isVideo) {
            _lastVideo = pts;
        }else {
            _lastAudio = pts;
        }
    }
    
    
    if(connection == [_videoDataOutput connectionWithMediaType:AVMediaTypeVideo]){
        [self encodeFrame:sampleBuffer isVideo:YES];
    }
    
    
    [self _automaticallyEndCaptureIfMaximumDurationReachedWithSampleBuffer:sampleBuffer];
    
}

#pragma mark- private method
- (void)_configurationData
{
    _startTimestamp = CMClockGetTime(CMClockGetHostTimeClock());
    _timeOffset = kCMTimeZero;
    Float64 duration = 60;
    _maximumCaptureDuration = CMTimeMakeWithSeconds(duration, 600);
    
    _fileURL = [self createAssetFileURL];
    _assetWriter = [AVAssetWriter assetWriterWithURL:_fileURL fileType:AVFileTypeMPEG4 error:nil];
    
    [self _configWriteVideoInput];
    
    [self changePositionCameraForDeviceInput:self.backCameraInput];
    
    _videoDataOutput = [[AVCaptureVideoDataOutput alloc] init];
    _videoDataOutput.alwaysDiscardsLateVideoFrames = YES;
    [_videoDataOutput setSampleBufferDelegate:self queue:self.videoQueue];
    if([_captureSession canAddOutput:_videoDataOutput]){
        [_captureSession addOutput:_videoDataOutput];
    }
    
    _audioDataOutput = [[AVCaptureAudioDataOutput alloc] init];
    [_audioDataOutput setSampleBufferDelegate:self queue:self.videoQueue];
    
    
    if ([self.captureSession canAddOutput:self.captureStillImageOutput])
    {
        [self.captureSession addOutput:_captureStillImageOutput];
    }
}

- (void)_configUI
{
    _previewLayer = [AVCaptureVideoPreviewLayer layerWithSession:self.captureSession];
    _previewLayer.backgroundColor = [UIColor redColor].CGColor;
    [self.view.layer insertSublayer:_previewLayer atIndex:0];
    _previewLayer.videoGravity = AVLayerVideoGravityResizeAspect;
    _previewLayer.frame = [UIScreen mainScreen].bounds;
    
    [_captureSession startRunning];
}

- (void)_configWriteVideoInput{
    //写入视频大小
    NSInteger numPixels = ScreenWidth * ScreenHeight;
    
    //每像素比特
    CGFloat bitsPerPixel = 12.0;
    NSInteger bitsPerSecond = numPixels * bitsPerPixel;
    
    // 码率和帧率设置
    NSDictionary *compressionProperties = @{ AVVideoAverageBitRateKey : @(bitsPerSecond),
                                             AVVideoExpectedSourceFrameRateKey : @(15),
                                             AVVideoMaxKeyFrameIntervalKey : @(15),
                                             AVVideoProfileLevelKey : AVVideoProfileLevelH264BaselineAutoLevel };
    CGFloat width = ScreenHeight;
    CGFloat height = ScreenWidth;
    if (iSiPhoneX)
    {
        width = ScreenHeight - 146;
        height = ScreenWidth;
    }
    //视频属性
    self.videoCompressionSettings = @{ AVVideoCodecKey : AVVideoCodecH264,
                                       AVVideoWidthKey : @(width * 2),
                                       AVVideoHeightKey : @(height * 2),
                                       AVVideoScalingModeKey : AVVideoScalingModeResizeAspectFill,
                                       AVVideoCompressionPropertiesKey : compressionProperties };
    
    _assetWriterVideoInput = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeVideo outputSettings:self.videoCompressionSettings];
    //expectsMediaDataInRealTime 必须设为yes，需要从capture session 实时获取数据
    _assetWriterVideoInput.expectsMediaDataInRealTime = YES;
    
    if (self.shootingOrientation == UIDeviceOrientationLandscapeRight)
    {
        _assetWriterVideoInput.transform = CGAffineTransformMakeRotation(M_PI);
    }
    else if (self.shootingOrientation == UIDeviceOrientationLandscapeLeft)
    {
        _assetWriterVideoInput.transform = CGAffineTransformMakeRotation(0);
    }
    else if (self.shootingOrientation == UIDeviceOrientationPortraitUpsideDown)
    {
        _assetWriterVideoInput.transform = CGAffineTransformMakeRotation(M_PI + (M_PI / 2.0));
    }
    else
    {
        _assetWriterVideoInput.transform = CGAffineTransformMakeRotation(M_PI / 2.0);
    }
    
}

- (void)changeDeviceProperty:(PropertyChangeBlock)propertyChange
{

}

- (void)changePositionCameraForDeviceInput:(AVCaptureDeviceInput *)targetDeviceInput
{
    _isRotating = YES;
    [_captureSession beginConfiguration];
    [_captureSession removeInput:_videoInput];
    if([self.captureSession canAddInput:targetDeviceInput]){
        [self.captureSession addInput:targetDeviceInput];
        _videoInput = targetDeviceInput;
    }
    [_captureSession commitConfiguration];
    _isRotating = NO;
}

- (void)_automaticallyEndCaptureIfMaximumDurationReachedWithSampleBuffer:(CMSampleBufferRef)sampleBuffer
{
    CMTime currentTimestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer);
    
    if (_isVideoRecord && CMTIME_IS_VALID(currentTimestamp) && CMTIME_IS_VALID(_startTimestamp) && CMTIME_IS_VALID(_maximumCaptureDuration)) {
        if (CMTIME_IS_VALID(_timeOffset)) {
            // Current time stamp is actually timstamp with data from globalClock
            // In case, if we had interruption, then _timeOffset
            // will have information about the time diff between globalClock and assetWriterClock
            // So in case if we had interruption we need to remove that offset from "currentTimestamp"
            currentTimestamp = CMTimeSubtract(currentTimestamp, _timeOffset);
        }
        CMTime currentCaptureDuration = CMTimeSubtract(currentTimestamp, _startTimestamp);
        if (CMTIME_IS_VALID(currentCaptureDuration)) {
            if (CMTIME_COMPARE_INLINE(currentCaptureDuration, >=, _maximumCaptureDuration)) {
                NSLog(@"times up");
            }
        }
    }
}

//调整媒体数据的时间
- (CMSampleBufferRef)adjustTime:(CMSampleBufferRef)sample by:(CMTime)offset {
    CMItemCount count;
    CMSampleBufferGetSampleTimingInfoArray(sample, 0, nil, &count);
    CMSampleTimingInfo* pInfo = malloc(sizeof(CMSampleTimingInfo) * count);
    CMSampleBufferGetSampleTimingInfoArray(sample, count, pInfo, &count);
    for (CMItemCount i = 0; i < count; i++) {
        pInfo[i].decodeTimeStamp = CMTimeSubtract(pInfo[i].decodeTimeStamp, offset);
        pInfo[i].presentationTimeStamp = CMTimeSubtract(pInfo[i].presentationTimeStamp, offset);
    }
    CMSampleBufferRef sout;
    CMSampleBufferCreateCopyWithNewTiming(nil, sample, count, pInfo, &sout);
    free(pInfo);
    return sout;
}

- (BOOL)encodeFrame:(CMSampleBufferRef) sampleBuffer isVideo:(BOOL)isVideo {
    //数据是否准备写入
    if (CMSampleBufferDataIsReady(sampleBuffer)) {
        //写入状态为未知,保证视频先写入
        if (_assetWriter.status == AVAssetWriterStatusUnknown && isVideo) {
            //获取开始写入的CMTime
            CMTime startTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer);
            //开始写入
            [_assetWriter startWriting];
            [_assetWriter startSessionAtSourceTime:startTime];
        }
        //写入失败
        if (_assetWriter.status == AVAssetWriterStatusFailed) {
            NSLog(@"writer error %@", _assetWriter.error.localizedDescription);
            return NO;
        }
        //判断是否是视频
        if (isVideo) {
            //视频输入是否准备接受更多的媒体数据
            if (_assetWriterVideoInput.readyForMoreMediaData == YES) {
                //拼接数据
                [_assetWriterVideoInput appendSampleBuffer:sampleBuffer];
                return YES;
            }
        }else {
            //音频输入是否准备接受更多的媒体数据
            if (_assetWriterAudioInput.readyForMoreMediaData) {
                //拼接数据
                [_assetWriterAudioInput appendSampleBuffer:sampleBuffer];
                return YES;
            }
        }
    }
    return NO;
}

- (NSURL *)createAssetFileURL
{
    // 创建视频文件的存储路径
    NSString *filePath = [self createVideoFolderPath];
    if (filePath == nil)
    {
        return nil;
    }
    
    NSString *videoType = @".mp4";
    NSString *videoDestDateString = [self createFileNamePrefix];
    NSString *videoFileName = [videoDestDateString stringByAppendingString:videoType];
    
    NSUInteger idx = 1;
    /*We only allow 10000 same file name*/
    NSString *finalPath = [NSString stringWithFormat:@"%@/%@", filePath, videoFileName];
    
    while (idx % 10000 && [[NSFileManager defaultManager] fileExistsAtPath:finalPath])
    {
        finalPath = [NSString stringWithFormat:@"%@/%@_(%lu)%@", filePath, videoDestDateString, (unsigned long)idx++, videoType];
    }
    
    
    return [NSURL fileURLWithPath:finalPath];
}

- (NSString *)createVideoFolderPath
{
    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSString *homePath = NSHomeDirectory();
    
    NSString *tmpFilePath;
    
    if (homePath.length > 0)
    {
        NSString *documentPath = [homePath stringByAppendingString:@"/Documents"];
        if ([fileManager fileExistsAtPath:documentPath isDirectory:NULL] == YES)
        {
            BOOL success = NO;
            
            NSArray *paths = [fileManager contentsOfDirectoryAtPath:documentPath error:nil];
            
            //offline file folder
            tmpFilePath = [documentPath stringByAppendingString:[NSString stringWithFormat:@"/%@", VIDEO_FILEPATH]];
            if ([paths containsObject:VIDEO_FILEPATH] == NO)
            {
                success = [fileManager createDirectoryAtPath:tmpFilePath withIntermediateDirectories:YES attributes:nil error:nil];
                if (!success)
                {
                    tmpFilePath = nil;
                }
            }
            return tmpFilePath;
        }
    }
    
    return false;
}

/**
 *  创建文件名
 */
- (NSString *)createFileNamePrefix
{
    NSDateFormatter *dateFormatter = [[NSDateFormatter alloc] init];
    [dateFormatter setDateFormat:@"yyyy-MM-dd HH:mm:ss zzz"];
    
    NSString *destDateString = [dateFormatter stringFromDate:[NSDate date]];
    destDateString = [destDateString stringByReplacingOccurrencesOfString:@" " withString:@"-"];
    destDateString = [destDateString stringByReplacingOccurrencesOfString:@"+" withString:@"-"];
    destDateString = [destDateString stringByReplacingOccurrencesOfString:@":" withString:@"-"];
    
    return destDateString;
}

- (void)exportAsset
{
    AVURLAsset *asset =[[AVURLAsset alloc] initWithURL:_fileURL options:nil];
    
    //获取视频总时长
    Float64 duration = CMTimeGetSeconds(asset.duration);
    
    NSURL *outputFileUrl = [self createAssetFileURL];
    
    NSArray *compatiblePresets = [AVAssetExportSession exportPresetsCompatibleWithAsset:asset];
    if ([compatiblePresets containsObject:AVAssetExportPresetMediumQuality])
    {
        
        AVAssetExportSession *exportSession = [[AVAssetExportSession alloc]
                                               initWithAsset:asset presetName:AVAssetExportPresetPassthrough];
        
        NSURL *outputURL = outputFileUrl;
        
        exportSession.outputURL = outputURL;
        exportSession.outputFileType = AVFileTypeMPEG4;
        exportSession.shouldOptimizeForNetworkUse = YES;
        
        CMTime start = CMTimeMakeWithSeconds(0, asset.duration.timescale);
        CMTime duration = CMTimeMakeWithSeconds(0,asset.duration.timescale);
        CMTimeRange range = CMTimeRangeMake(start, duration);
        exportSession.timeRange = range;
        
        [exportSession exportAsynchronouslyWithCompletionHandler:^{
            switch ([exportSession status]) {
                case AVAssetExportSessionStatusFailed:
                {
                    NSLog(@"合成失败：%@", [[exportSession error] description]);
                    
                }
                    break;
                case AVAssetExportSessionStatusCancelled:
                {
                    
                }
                    break;
                case AVAssetExportSessionStatusCompleted:
                {
                    NSLog(@"OK");
                }
                    break;
                default:
                {
                    
                } break;
            }
        }];
    }

}


#pragma mark- setter/getter
- (dispatch_queue_t)videoQueue
{
    if (!_videoQueue)
    {
        _videoQueue = dispatch_queue_create("com.jackson.mediaRecord", DISPATCH_QUEUE_SERIAL); // dispatch_get_main_queue();
    }
    
    return _videoQueue;
}

- (AVCaptureSession *)captureSession
{
    if (_captureSession == nil)
    {
        _captureSession = [[AVCaptureSession alloc] init];
        
        if ([_captureSession canSetSessionPreset:AVCaptureSessionPresetHigh])
        {
            _captureSession.sessionPreset = AVCaptureSessionPresetHigh;
        }
    }
    
    return _captureSession;
}

- (AVCaptureDeviceInput *)backCameraInput
{
    if(!_backCameraInput){
        AVCaptureDevice *backDevice = [self getCameraDeviceWithPosition:AVCaptureDevicePositionBack];
        NSError *error ;
        _backCameraInput = [AVCaptureDeviceInput deviceInputWithDevice:backDevice error:&error];
        if(error){
            NSLog(@"get back CameraDevice error is %@",error.localizedDescription);
            _backCameraInput = nil;
        }
    }
    return _backCameraInput;
}

- (AVCaptureDeviceInput *)frontCameraInput
{
    if(!_frontCameraInput){
        AVCaptureDevice *frontDevice = [self getCameraDeviceWithPosition:AVCaptureDevicePositionFront];
        NSError *error ;
        _frontCameraInput = [AVCaptureDeviceInput deviceInputWithDevice:frontDevice error:&error];
        if(error){
            NSLog(@"get front CameraDevice error is %@",error.localizedDescription);
            _frontCameraInput = nil;
        }
    }
    return _frontCameraInput;
}

-(AVCaptureStillImageOutput *)captureStillImageOutput
{
    if(!_captureStillImageOutput){
        self.captureStillImageOutput = [[AVCaptureStillImageOutput alloc] init];
        NSDictionary *outputSettings = @{
                                         AVVideoCodecKey:AVVideoCodecJPEG
                                         };
        [_captureStillImageOutput setOutputSettings:outputSettings];
    }
    return _captureStillImageOutput;
}

- (AVCaptureDevice *)getCameraDeviceWithPosition:(AVCaptureDevicePosition )position
{
    NSArray *cameras = [AVCaptureDevice devicesWithMediaType:AVMediaTypeVideo];
    for (AVCaptureDevice *camera in cameras)
    {
        if ([camera position] == position)
        {
            return camera;
        }
    }
    return nil;
}


@end
