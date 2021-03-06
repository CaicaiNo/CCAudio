//
//  GSAudioCapture.m
//  LFLiveKit
//
//  Created by LaiFeng on 16/5/20.
//  Copyright © 2016年 LaiFeng All rights reserved.
//

#import "GSAudioCapture.h"
#import <AudioToolbox/AudioToolbox.h>
#import <AVFoundation/AVFoundation.h>

#define kOutputBus 0
#define kInputBus 1

static BOOL checkError(OSStatus error, const char *operation);

NSString *const GSAudioComponentFailedToCreateNotification = @"GSAudioComponentFailedToCreateNotification";

@interface GSAudioCapture ()

@property (nonatomic, assign) AudioComponentInstance componetInstance;
@property (nonatomic, assign) AudioComponent component;
@property (nonatomic, strong) dispatch_queue_t taskQueue;
@property (nonatomic, assign) BOOL isRunning;
@property (nonatomic, strong,nullable) GSLiveAudioConfiguration *configuration;

@end

@implementation GSAudioCapture

#pragma mark -- LiftCycle
- (instancetype)initWithAudioConfiguration:(GSLiveAudioConfiguration *)configuration{
    if(self = [super init]){
        _configuration = configuration;
        self.isRunning = NO;
        self.taskQueue = dispatch_queue_create("com.gensee.audioCaptureQueue", NULL);
        
        AVAudioSession *session = [AVAudioSession sharedInstance];
        
        //这里没有处理相关通知所以注释了
//        [[NSNotificationCenter defaultCenter] addObserver: self
//                                                 selector: @selector(handleRouteChange:)
//                                                     name: AVAudioSessionRouteChangeNotification
//                                                   object: session];
        [[NSNotificationCenter defaultCenter] addObserver: self
                                                 selector: @selector(handleInterruption:)
                                                     name: AVAudioSessionInterruptionNotification
                                                   object: session];
        
        AudioComponentDescription acd;
        acd.componentType = kAudioUnitType_Output;
        acd.componentSubType = kAudioUnitSubType_VoiceProcessingIO; //Voice ProcessingIO 提供了回音消除
//        acd.componentSubType = kAudioUnitSubType_RemoteIO; //一般录制使用RemoteIO可以满足
        acd.componentManufacturer = kAudioUnitManufacturer_Apple;
        acd.componentFlags = 0;
        acd.componentFlagsMask = 0;
        
        self.component = AudioComponentFindNext(NULL, &acd);
        
        OSStatus status = noErr;
        status = AudioComponentInstanceNew(self.component, &_componetInstance);
        
        if (noErr != status) {
            [self handleAudioComponentCreationFailure];
        }
        
        UInt32 flagIn = 1;  // YES
        UInt32 flagOut = 0; // NO
        // Enable IO for recording - 打开录制IO
        AudioUnitSetProperty(self.componetInstance, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, kInputBus, &flagIn, sizeof(flagIn));
        // Enable IO for playback - 关闭播放IO
        AudioUnitSetProperty(self.componetInstance, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, kOutputBus, &flagOut, sizeof(flagOut));
        
        
        AudioStreamBasicDescription desc = {0};
        desc.mSampleRate = _configuration.audioSampleRate; //采样率 48000 16000 8000
        desc.mFormatID = kAudioFormatLinearPCM; //数据类型
        desc.mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagsNativeEndian | kAudioFormatFlagIsPacked;
        desc.mChannelsPerFrame = (UInt32)_configuration.numberOfChannels; //通道数
        desc.mFramesPerPacket = 1;
        desc.mBitsPerChannel = 16;
        desc.mBytesPerFrame = (desc.mBitsPerChannel / 8) * desc.mChannelsPerFrame;
        desc.mBytesPerPacket = desc.mBytesPerFrame * desc.mFramesPerPacket;
        
        [self printASBD:desc]; //打印 AudioStreamBasicDescription
        
        
        AURenderCallbackStruct cb;
        //bridge指针，用于回调callback时取得self实例
        cb.inputProcRefCon = (__bridge void *)(self);
        //回调函数
        cb.inputProc = handleInputBuffer;
        //设置Element 1即Input Bus的输出为desc设置的参数，就保证我们获取的数据符合我们的要求
        AudioUnitSetProperty(self.componetInstance, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, kInputBus, &desc, sizeof(desc));
        //设置Output的回调，即数据输出的回调，这里kAudioUnitScope_Global表示上下文全局，也可以改为kAudioUnitScope_Output
        AudioUnitSetProperty(self.componetInstance, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, kInputBus, &cb, sizeof(cb));
        
        //这里由于设置了 kAudioUnitSubType_VoiceProcessingIO 回音消除，所以需要设置 kAUVoiceIOProperty_BypassVoiceProcessing
        //kAudioUnitSubType_RemoteIO 可以忽略
        UInt32 echoCancellation;
        UInt32 size = sizeof(echoCancellation);
        AudioUnitGetProperty(self.componetInstance,
                             kAUVoiceIOProperty_BypassVoiceProcessing,
                             kAudioUnitScope_Global,
                             0,
                             &echoCancellation,
                             &size);

        status = AudioUnitInitialize(self.componetInstance);
        
        if (noErr != status) {
            [self handleAudioComponentCreationFailure];
        }
        
        [session setPreferredSampleRate:_configuration.audioSampleRate error:nil];
        //音频session设置AVAudioSessionCategoryOptions 默认为 AVAudioSessionCategoryOptionDefaultToSpeaker|AVAudioSessionCategoryOptionAllowBluetooth|AVAudioSessionCategoryOptionMixWithOthers
        [session setCategory:AVAudioSessionCategoryPlayAndRecord
                 withOptions:_configuration.sessionCategoryOption
                       error:nil];
        [session setActive:YES error:nil];
    }
    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];

    dispatch_sync(self.taskQueue, ^{
        if (self.componetInstance) {
            self.isRunning = NO;
            AudioOutputUnitStop(self.componetInstance);
            AudioComponentInstanceDispose(self.componetInstance);
            self.componetInstance = nil;
            self.component = nil;
        }
    });
}

#pragma mark -- Setter
- (void)setRunning:(BOOL)running {
    if (_running == running) return;
    _running = running;
    if (_running) {
        dispatch_async(self.taskQueue, ^{
            self.isRunning = YES;
            NSLog(@"MicrophoneSource: startRunning");
            [[AVAudioSession sharedInstance] setCategory:AVAudioSessionCategoryPlayAndRecord
                                             withOptions:self.configuration.sessionCategoryOption
                                                   error:nil];
            AudioOutputUnitStart(self.componetInstance);
        });
    } else {
        dispatch_sync(self.taskQueue, ^{
            self.isRunning = NO;
            NSLog(@"MicrophoneSource: stopRunning");
            AudioOutputUnitStop(self.componetInstance);
        });
    }
}

#pragma mark -- CustomMethod
- (void)handleAudioComponentCreationFailure {
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:GSAudioComponentFailedToCreateNotification object:nil];
    });
}

#pragma mark -- NSNotification
- (void)handleRouteChange:(NSNotification *)notification {
    AVAudioSession *session = [ AVAudioSession sharedInstance ];
    NSString *seccReason = @"";
    NSInteger reason = [[[notification userInfo] objectForKey:AVAudioSessionRouteChangeReasonKey] integerValue];
    //  AVAudioSessionRouteDescription* prevRoute = [[notification userInfo] objectForKey:AVAudioSessionRouteChangePreviousRouteKey];
    switch (reason) {
    case AVAudioSessionRouteChangeReasonNoSuitableRouteForCategory:
        seccReason = @"The route changed because no suitable route is now available for the specified category.";
        break;
    case AVAudioSessionRouteChangeReasonWakeFromSleep:
        seccReason = @"The route changed when the device woke up from sleep.";
        break;
    case AVAudioSessionRouteChangeReasonOverride:
        seccReason = @"The output route was overridden by the app.";
        break;
    case AVAudioSessionRouteChangeReasonCategoryChange:
        seccReason = @"The category of the session object changed.";
        break;
    case AVAudioSessionRouteChangeReasonOldDeviceUnavailable:
        seccReason = @"The previous audio output path is no longer available.";
        break;
    case AVAudioSessionRouteChangeReasonNewDeviceAvailable:
        seccReason = @"A preferred new audio output path is now available.";
        break;
    case AVAudioSessionRouteChangeReasonUnknown:
    default:
        seccReason = @"The reason for the change is unknown.";
        break;
    }
    NSLog(@"handleRouteChange reason is %@", seccReason);
    if (session.currentRoute) {
        if (session.currentRoute.inputs) {
            NSArray<AVAudioSessionPortDescription *>*inputs = session.currentRoute.inputs;
            if (inputs.count > 0) {
                AVAudioSessionPortDescription *input = [inputs firstObject];
                NSLog(@"inport port type is %@", input.portType);
            }
            
            //            if (input.portType == AVAudioSessionPortHeadsetMic) {
            //
            //            }
        }
    }
}

- (void)handleInterruption:(NSNotification *)notification {
    NSInteger reason = 0;
    NSString *reasonStr = @"";
    if ([notification.name isEqualToString:AVAudioSessionInterruptionNotification]) {
        //Posted when an audio interruption occurs.
        reason = [[[notification userInfo] objectForKey:AVAudioSessionInterruptionTypeKey] integerValue];
        if (reason == AVAudioSessionInterruptionTypeBegan) {
            if (self.isRunning) {
                dispatch_sync(self.taskQueue, ^{
                    NSLog(@"MicrophoneSource: stopRunning");
                    AudioOutputUnitStop(self.componetInstance);
                });
            }
        }

        if (reason == AVAudioSessionInterruptionTypeEnded) {
            reasonStr = @"AVAudioSessionInterruptionTypeEnded";
            NSNumber *seccondReason = [[notification userInfo] objectForKey:AVAudioSessionInterruptionOptionKey];
            switch ([seccondReason integerValue]) {
            case AVAudioSessionInterruptionOptionShouldResume:
                if (self.isRunning) {
                    dispatch_async(self.taskQueue, ^{
                        NSLog(@"MicrophoneSource: startRunning");
                        AudioOutputUnitStart(self.componetInstance);
                    });
                }
                // Indicates that the audio session is active and immediately ready to be used. Your app can resume the audio operation that was interrupted.
                break;
            default:
                break;
            }
        }

    }
    ;
    NSLog(@"handleInterruption: %@ reason %@", [notification name], reasonStr);
}

#pragma mark -- CallBack
static OSStatus handleInputBuffer(void *inRefCon,
                                  AudioUnitRenderActionFlags *ioActionFlags,
                                  const AudioTimeStamp *inTimeStamp,
                                  UInt32 inBusNumber,
                                  UInt32 inNumberFrames,
                                  AudioBufferList *ioData) {
    @autoreleasepool {
        GSAudioCapture *source = (__bridge GSAudioCapture *)inRefCon;
        if (!source) return -1;

        AudioBuffer buffer;
        buffer.mData = NULL;
        buffer.mDataByteSize = 0;
        buffer.mNumberChannels = 1;

        AudioBufferList buffers;
        buffers.mNumberBuffers = 1;
        buffers.mBuffers[0] = buffer;

        OSStatus status = AudioUnitRender(source.componetInstance,
                                          ioActionFlags,
                                          inTimeStamp,
                                          inBusNumber,
                                          inNumberFrames,
                                          &buffers);

        if (source.muted) {
            for (int i = 0; i < buffers.mNumberBuffers; i++) {
                AudioBuffer ab = buffers.mBuffers[i];
                memset(ab.mData, 0, ab.mDataByteSize);
            }
        }

        if (!status) {
            if (source.delegate && [source.delegate respondsToSelector:@selector(captureOutput:audioData:)]) {
                [source.delegate captureOutput:source audioData:[NSData dataWithBytes:buffers.mBuffers[0].mData length:buffers.mBuffers[0].mDataByteSize]];
            }
        }
        return status;
    }
}


#pragma mark - extern

- (void)printASBD: (AudioStreamBasicDescription) asbd {
    
    char formatIDString[5];
    UInt32 formatID = CFSwapInt32HostToBig (asbd.mFormatID);
    bcopy (&formatID, formatIDString, 4);
    formatIDString[4] = '\0';
    
    NSLog (@"[Audio Unit]  Sample Rate:         %10.0f",  asbd.mSampleRate);
    NSLog (@"[Audio Unit]  Format ID:           %10s",    formatIDString);
    NSLog (@"[Audio Unit]  Format Flags:        %10X",    asbd.mFormatFlags);
    NSLog (@"[Audio Unit]  Bytes per Packet:    %10d",    asbd.mBytesPerPacket);
    NSLog (@"[Audio Unit]  Frames per Packet:   %10d",    asbd.mFramesPerPacket);
    NSLog (@"[Audio Unit]  Bytes per Frame:     %10d",    asbd.mBytesPerFrame);
    NSLog (@"[Audio Unit]  Channels per Frame:  %10d",    asbd.mChannelsPerFrame);
    NSLog (@"[Audio Unit]  Bits per Channel:    %10d",    asbd.mBitsPerChannel);
}

static BOOL checkError(OSStatus error, const char *operation)
{
    if (error == noErr)
        return NO;
    
    char str[20] = {0};
    // see if it appears to be a 4-char-code
    *(UInt32 *)(str + 1) = CFSwapInt32HostToBig(error);
    if (isprint(str[1]) && isprint(str[2]) && isprint(str[3]) && isprint(str[4])) {
        str[0] = str[5] = '\'';
        str[6] = '\0';
    } else
        // no, format it as an integer
        sprintf(str, "%d", (int)error);
    
    NSLog(@"Error: %s (%s)\n", operation, str);
    
    //exit(1);
    
    return YES;
}

@end
