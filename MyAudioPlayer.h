//
//  MyAudioPlayer.h
//  UUSmartHome
//
//  Created by vsKing on 2017/7/12.
//  Copyright © 2017年 Fuego. All rights reserved.
//

#import <Foundation/Foundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import <AVFoundation/AVFoundation.h>


@interface MyAudioPlayer : NSObject


+(MyAudioPlayer *)sharedInstance;

- (void)addPacket:(NSData *)data;

- (void)play;

- (void)stop;


@end
