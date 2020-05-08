//
//  AppDelegate.m
//  CCAudio
//
//  Created by gensee on 2020/5/8.
//  Copyright © 2020 CaicaiNo. All rights reserved.
//

#import "AppDelegate.h"
#import "CCAudioViewController.h"
@interface AppDelegate ()

@end

@implementation AppDelegate


- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    // Override point for customization after application launch.
    self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    CCAudioViewController *mainVC = [[CCAudioViewController alloc]initWithNibName:@"CCAudioViewController" bundle:[NSBundle mainBundle]];
    self.window.rootViewController = mainVC;
    [self.window makeKeyAndVisible];
    return YES;
}


@end
