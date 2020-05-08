//
//  CCAudioViewController.m
//  CCAudio
//
//  Created by gensee on 2020/5/8.
//  Copyright © 2020 CaicaiNo. All rights reserved.
//

#import "CCAudioViewController.h"
#

@interface CCAudioViewController ()
@property (weak, nonatomic) IBOutlet UIButton *recordBtn;
@property (weak, nonatomic) IBOutlet UIButton *playBtn;
@end

@implementation CCAudioViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    // Do any additional setup after loading the view from its nib.
    self.recordBtn.layer.cornerRadius = 8.f;
    self.playBtn.layer.cornerRadius = 8.f;
}

- (IBAction)recordAction:(id)sender {
    
}

- (IBAction)playAction:(id)sender {
    
}

/*
#pragma mark - Navigation

// In a storyboard-based application, you will often want to do a little preparation before navigation
- (void)prepareForSegue:(UIStoryboardSegue *)segue sender:(id)sender {
    // Get the new view controller using [segue destinationViewController].
    // Pass the selected object to the new view controller.
}
*/

@end
