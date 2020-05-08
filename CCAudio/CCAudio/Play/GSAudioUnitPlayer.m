//
//  GSAudioUnitPlayer.m
//  RtSDK
//
//  Created by gensee on 2020/5/7.
//  Copyright © 2020 Geensee. All rights reserved.
//

#import "GSAudioUnitPlayer.h"
#import <AudioToolbox/AudioToolbox.h>
#import <AVFoundation/AVFoundation.h>
//#import "GSPCMWriter.h"

#define kOutputBus 0
#define kInputBus 1

#define WRITE_PCM 0

static BOOL checkError(OSStatus error, const char *operation);


@interface GSAudioUnitPlayer ()

@property (nonatomic, assign) AudioComponentInstance componetInstance;
@property (nonatomic, assign) AudioComponent component;
@property (nonatomic, strong) dispatch_queue_t taskQueue;
@property (nonatomic, assign) BOOL isRunning;
@property (nonatomic, strong,nullable) GSLiveAudioConfiguration *configuration;

@end
@implementation GSAudioUnitPlayer {
    double preferredSampleRate;
#if WRITE_PCM
    GSPCMWriter *pcmWriter;
#endif
}
#pragma mark -- LiftCycle
- (instancetype)initWithAudioConfiguration:(GSLiveAudioConfiguration *)configuration{
    if(self = [super init]){
#if WRITE_PCM
        pcmWriter = [[GSPCMWriter alloc] init];
#endif
        _configuration = configuration;
        self.isRunning = NO;
        self.taskQueue = dispatch_queue_create("com.gensee.audioUnitQueue", NULL);
        
        AVAudioSession *session = [AVAudioSession sharedInstance];
        preferredSampleRate = session.sampleRate;
        
        [[NSNotificationCenter defaultCenter] addObserver: self
                                                 selector: @selector(handleRouteChange:)
                                                     name: AVAudioSessionRouteChangeNotification
                                                   object: session];
        [[NSNotificationCenter defaultCenter] addObserver: self
                                                 selector: @selector(handleInterruption:)
                                                     name: AVAudioSessionInterruptionNotification
                                                   object: session];
        
        [self resetAudioUnit];
        
        
        [session setCategory:AVAudioSessionCategoryPlayAndRecord
                 withOptions:_configuration.sessionCategoryOption
                       error:nil];
        [session setActive:YES error:nil];
    }
    return self;
}

- (void)resetAudioUnit {
    AudioComponentDescription acd;
    acd.componentType = kAudioUnitType_Output;
    //        acd.componentSubType = kAudioUnitSubType_VoiceProcessingIO;
    acd.componentSubType = kAudioUnitSubType_RemoteIO;
    acd.componentManufacturer = kAudioUnitManufacturer_Apple;
    acd.componentFlags = 0;
    acd.componentFlagsMask = 0;
    
    self.component = AudioComponentFindNext(NULL, &acd);
    
    OSStatus status = noErr;
    status = AudioComponentInstanceNew(self.component, &_componetInstance);
    
    if (noErr != status) {
        [self handleAudioComponentCreationFailure];
    }
    
    //        UInt32 flagIn = 0;  // YES
    UInt32 flagOut = 1; // NO
    // Enable IO for recording - 打开录制IO
    //        AudioUnitSetProperty(self.componetInstance, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, kInputBus, &flagIn, sizeof(flagIn));
    // Enable IO for playback - 打开播放IO
    AudioUnitSetProperty(self.componetInstance, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, kOutputBus, &flagOut, sizeof(flagOut));
    
    AVAudioSession *session = [AVAudioSession sharedInstance];
    AudioStreamBasicDescription desc = {0};
    desc.mSampleRate = session.sampleRate;
    desc.mFormatID = kAudioFormatLinearPCM;
    desc.mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagsNativeEndian | kAudioFormatFlagIsPacked;
    desc.mChannelsPerFrame = (UInt32)_configuration.numberOfChannels;
    desc.mFramesPerPacket = 1;
    desc.mBitsPerChannel = 16;
    desc.mBytesPerFrame = (desc.mBitsPerChannel / 8) * desc.mChannelsPerFrame;
    desc.mBytesPerPacket = desc.mBytesPerFrame * desc.mFramesPerPacket;
    
    [self printASBD:desc];
    
    
    AURenderCallbackStruct cb;
    cb.inputProcRefCon = (__bridge void *)(self);
    cb.inputProc = playbackCallback;
    AudioUnitSetProperty(self.componetInstance, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, kOutputBus, &desc, sizeof(desc));
    //        AudioUnitSetProperty(self.componetInstance, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, kInputBus, &desc, sizeof(desc));
    AudioUnitSetProperty(self.componetInstance, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, kOutputBus, &cb, sizeof(cb));
    
    
    status = AudioUnitInitialize(self.componetInstance);
    
    if (noErr != status) {
        [self handleAudioComponentCreationFailure];
    }
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
            
            NSLog(@"GSAudioUnitPlayer: startRunning");
            AVAudioSession *session = [AVAudioSession sharedInstance];
            if (self.delegate && [self.delegate respondsToSelector:@selector(audioUnitOnSetChannel:sampleRate:duration:)]) {
                [self.delegate audioUnitOnSetChannel:(int)self.configuration.numberOfChannels sampleRate:(int)session.sampleRate duration:0];
            }
            if (session.category != AVAudioSessionCategoryPlayAndRecord) {
                [session setCategory:AVAudioSessionCategoryPlayAndRecord
                         withOptions:self.configuration.sessionCategoryOption
                               error:nil];
            }
            AudioOutputUnitStart(self.componetInstance);
            self.isRunning = YES;
        });
    } else {
        dispatch_sync(self.taskQueue, ^{
            self.isRunning = NO;
            NSLog(@"GSAudioUnitPlayer: stopRunning");
            AudioOutputUnitStop(self.componetInstance);
        });
    }
}

#pragma mark -- CustomMethod
- (void)handleAudioComponentCreationFailure {
}

#pragma mark -- NSNotification
- (void)handleRouteChange:(NSNotification *)notification {
    AVAudioSession *session = [AVAudioSession sharedInstance];
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
    if (preferredSampleRate != session.sampleRate) {
        self.running = NO;
        preferredSampleRate = session.sampleRate;
        [self resetAudioUnit];
        self.running = YES;
    }
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


static OSStatus playbackCallback(void *inRefCon,
                                  AudioUnitRenderActionFlags *ioActionFlags,
                                  const AudioTimeStamp *inTimeStamp,
                                  UInt32 inBusNumber,
                                  UInt32 inNumberFrames,
                                  AudioBufferList *ioData) {
    // Notes: ioData contains buffers (may be more than one!)
    // Fill them up as much as you can. Remember to set the size value in each buffer to match how
    // much data is in the buffer.
    @autoreleasepool {
        
        GSAudioUnitPlayer * player = (__bridge GSAudioUnitPlayer*)inRefCon;
        if (!player) return -1;
        if (player.running) {
            if (player.delegate && [player.delegate respondsToSelector:@selector(audioUnitOnGetData:numberFrames:audioData:)]) {
                [player.delegate audioUnitOnGetData:ioActionFlags numberFrames:inNumberFrames audioData:ioData];
            }
#if WRITE_PCM
            if (player->pcmWriter) {
                AudioBuffer buffer = ioData->mBuffers[0];
                [player->pcmWriter writePCM:(void*)buffer.mData length:buffer.mDataByteSize];
            }
#endif
        }else {
            return -1;
        }
    }
    return noErr;
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
