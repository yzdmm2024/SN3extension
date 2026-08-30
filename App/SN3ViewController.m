//
//  SN3ViewController.m — 套壳 App 极简主页
//
#import "SN3ViewController.h"
#import "SN3AppDelegate.h"

@implementation SN3ViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor colorWithRed:0.0/255.0 green:122.0/255.0 blue:255.0/255.0 alpha:1.0];

    UILabel *title = [[UILabel alloc] init];
    title.text = @"超级截图";
    title.font = [UIFont boldSystemFontOfSize:34];
    title.textColor = [UIColor whiteColor];
    title.textAlignment = NSTextAlignmentCenter;
    title.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:title];

    UILabel *sub = [[UILabel alloc] init];
    sub.text = @"点下方按钮唤起超级截图";
    sub.font = [UIFont systemFontOfSize:15];
    sub.textColor = [UIColor colorWithWhite:1.0 alpha:0.85];
    sub.textAlignment = NSTextAlignmentCenter;
    sub.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:sub];

    UIButton *capture = [UIButton buttonWithType:UIButtonTypeSystem];
    [capture setTitle:@"开始截图" forState:UIControlStateNormal];
    [capture setTitleColor:[UIColor colorWithRed:0.0 green:0.478 blue:1.0 alpha:1.0] forState:UIControlStateNormal];
    capture.backgroundColor = [UIColor whiteColor];
    capture.layer.cornerRadius = 14;
    capture.titleLabel.font = [UIFont boldSystemFontOfSize:22];
    capture.translatesAutoresizingMaskIntoConstraints = NO;
    [capture addTarget:self action:@selector(onCapture) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:capture];

    UIButton *settings = [UIButton buttonWithType:UIButtonTypeSystem];
    [settings setTitle:@"打开设置" forState:UIControlStateNormal];
    [settings setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    settings.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.18];
    settings.layer.cornerRadius = 14;
    settings.titleLabel.font = [UIFont systemFontOfSize:17];
    settings.translatesAutoresizingMaskIntoConstraints = NO;
    [settings addTarget:self action:@selector(onSettings) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:settings];

    [NSLayoutConstraint activateConstraints:@[
        [title.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [title.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor constant:-90],
        [sub.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [sub.topAnchor constraintEqualToAnchor:title.bottomAnchor constant:8],
        [capture.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [capture.topAnchor constraintEqualToAnchor:sub.bottomAnchor constant:40],
        [capture.widthAnchor constraintEqualToConstant:220],
        [capture.heightAnchor constraintEqualToConstant:56],
        [settings.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [settings.topAnchor constraintEqualToAnchor:capture.bottomAnchor constant:16],
        [settings.widthAnchor constraintEqualToConstant:220],
        [settings.heightAnchor constraintEqualToConstant:46],
    ]];
}

- (void)onCapture {
    [self.delegate triggerCapture];
}

- (void)onSettings {
    [self.delegate openSettings];
}

@end
