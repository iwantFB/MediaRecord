//
//  ViewController.m
//  FHMediaRecord
//
//  Created by 胡斐 on 2018/11/20.
//  Copyright © 2018年 jackson. All rights reserved.
//

#import "ViewController.h"
#import <AVFoundation/AVFoundation.h>

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


@property (nonatomic, strong) AVAssetWriter *assetWriter;
@property (nonatomic, strong) AVAssetWriterInput *assetWriterVideoInput;
@property (nonatomic, strong) AVAssetWriterInput *assetWriterAudioInput;
@property (nonatomic, strong) NSDictionary *videoCompressionSettings;
@property (nonatomic, strong) NSDictionary *audioCompressionSettings;

@property (strong, nonatomic) NSURL *videoURL;

@end

@implementation ViewController
{
    AVCaptureVideoPreviewLayer *_previewLayer;
    AVCaptureSession *_captureSession;
    
    AVCaptureAudioDataOutput *_audioDataOutput;
    AVCaptureVideoDataOutput *_videoDataOutput;
    
    CMTime _startTimestamp;
    CMTime _timeOffset;
    CMTime _maximumCaptureDuration;
    
    BOOL _isRotating;
    BOOL _isPaused;
    BOOL _isVideoRecord;
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
    
    
}

- (IBAction)resumeRecoed:(id)sender {
    
    
}

- (IBAction)changeFlash:(id)sender {
    
    
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
     
        if(connection == [_videoDataOutput connectionWithMediaType:AVMediaTypeVideo]){
            
        }
        
        
        [self _automaticallyEndCaptureIfMaximumDurationReachedWithSampleBuffer:sampleBuffer];
        
    }
}

#pragma mark- private method
- (void)_configurationData
{
    _startTimestamp = CMClockGetTime(CMClockGetHostTimeClock());
    _timeOffset = kCMTimeInvalid;
    _maximumCaptureDuration = kCMTimeInvalid;
    
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
