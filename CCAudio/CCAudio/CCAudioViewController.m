//
//  CCAudioViewController.m
//  CCAudio
//
//  Created by gensee on 2020/5/8.
//  Copyright © 2020 CaicaiNo. All rights reserved.
//

#import "CCAudioViewController.h"
#import "GSAudioCapture.h"
#import "GSLiveAudioConfiguration.h"
#import "GSAudioUnitPlayer.h"


@interface CCAudioViewController () <GSAudioCaptureDelegate,GSAudioUnitPlayerDelegate>
@property (weak, nonatomic) IBOutlet UIButton *recordBtn;
@property (weak, nonatomic) IBOutlet UIButton *playBtn;

@property (nonatomic, strong) GSAudioCapture *audioCapture;
@property (nonatomic, strong) NSTimer *timer;
@property (nonatomic, assign) unsigned long timeCount;

@property (nonatomic, strong) NSFileHandle *fileHandle;
@property (nonatomic, strong) NSString *filepath;
@property (nonatomic, strong) NSInputStream *inputStream;
@property (nonatomic, strong) GSAudioUnitPlayer *unitPlayer;

@end

@implementation CCAudioViewController {
    
}

- (void)viewDidLoad {
    [super viewDidLoad];
    // Do any additional setup after loading the view from its nib.
    self.recordBtn.layer.cornerRadius = 8.f;
    self.recordBtn.titleLabel.textAlignment = NSTextAlignmentCenter;
    self.playBtn.layer.cornerRadius = 8.f;
    _timeCount = 0;
}

- (void)updateTimeCount {
    self.timeCount ++;
    self.recordBtn.titleLabel.text = [NSString stringWithFormat:@"%02lu:%02lu",self.timeCount/60,self.timeCount%60];
}

- (IBAction)recordAction:(id)sender {
    
    if (!_audioCapture) {
        GSLiveAudioConfiguration *config = [GSLiveAudioConfiguration new];
        config.audioSampleRate = GSLiveAudioSampleRate_16000Hz;
        config.numberOfChannels = 1;
        _audioCapture = [[GSAudioCapture alloc] initWithAudioConfiguration:config];
        _audioCapture.delegate = self;
    }
    if (!_audioCapture.running) {
        self.timeCount = 0;
        _audioCapture.running = YES;
        __weak typeof(self) wself = self;
        _timer = [NSTimer timerWithTimeInterval:1 target:wself selector:@selector(updateTimeCount) userInfo:nil repeats:YES];
        [[NSRunLoop currentRunLoop] addTimer:_timer forMode:NSRunLoopCommonModes];
        [_timer fire];
        
        //create pcm file
        NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
        [formatter setDateFormat:@"YYmmdd_hhmmss"];
        NSString *data_str = [formatter stringFromDate:[NSDate date]];
        _filepath = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"%@.pcm",data_str]];
        [[NSData new] writeToFile:_filepath atomically:YES];
        _fileHandle = [NSFileHandle fileHandleForWritingAtPath:_filepath];
        [_fileHandle seekToEndOfFile];
    }else {
        _audioCapture.running = NO;
        [_timer invalidate];
        _timer = nil;
        self.recordBtn.titleLabel.text = @"录制 Record";
    }
    
    if (_unitPlayer) {
        _unitPlayer.running = NO;
        _unitPlayer = nil;
    }
}

- (IBAction)playAction:(id)sender {
    if (!_inputStream) {
        [_inputStream close];
        [_inputStream removeFromRunLoop:[NSRunLoop currentRunLoop] forMode:NSRunLoopCommonModes];
        _inputStream = nil;
    }
    _inputStream = [[NSInputStream alloc]initWithFileAtPath:_filepath];
    [_inputStream scheduleInRunLoop:[NSRunLoop currentRunLoop] forMode:NSRunLoopCommonModes];
    [_inputStream open];
    
    //输出需要和录制的参数一致，特别是采样率
    GSLiveAudioConfiguration *config = [GSLiveAudioConfiguration new];
    config.audioSampleRate = GSLiveAudioSampleRate_16000Hz;
    config.numberOfChannels = 1;
    
    if (!_unitPlayer) {
        _unitPlayer = [[GSAudioUnitPlayer alloc] initWithAudioConfiguration:config];
        _unitPlayer.delegate = self;
        _unitPlayer.running = YES;
    }
}

//录制数据输出回调
- (void)captureOutput:(nullable GSAudioCapture *)capture audioData:(nullable NSData*)audioData {
    if (_fileHandle) [_fileHandle writeData:audioData];
}


//unit 输出的callback回调，会主动回调，我们需要在此回调中给音频数据赋值
- (void)audioUnitOnGetData:(AudioUnitRenderActionFlags *)flag numberFrames:(UInt32)inNumberFrames audioData:(AudioBufferList *)ioData {
    NSInteger length = [_inputStream read:ioData->mBuffers[0].mData maxLength:ioData->mBuffers[0].mDataByteSize];
    ioData->mBuffers[0].mDataByteSize = (UInt32)length;
}


@end
